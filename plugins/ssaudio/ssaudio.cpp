// ssaudio -- play an audio file from a DFHack script.
//
// WHY A PLUGIN AT ALL. DFHack's Lua sandbox has no audio call, and no way out to a shell
// either: os.execute and io.popen are both nil. DF's own music engine (df.global.musicsound)
// only plays tracks it loaded from data/sound/tracks at startup, and it owns the scheduling --
// it fades and replaces what you force on it. So playing an arbitrary file on demand needs
// native code, and this is the smallest thing that does it.
//
// HOW. minimp3 (vendored, CC0) decodes the file to PCM, SDL2 plays it on a device of our own.
// SDL2 is already in the process -- DF is built on it -- and DFHack builds against its headers,
// so nothing new has to be installed. Decoding happens on a worker thread because a full-length
// track takes long enough to decode that doing it inline would hitch the frame; the decode
// finishes, opens the device, queues the whole buffer and returns. SDL_QueueAudio means no
// callback and no realtime constraint on our side.
//
// Lua:
//   local ssaudio = require('plugins.ssaudio')
//   ssaudio.play('/path/to/track.mp3')   -- optional second arg: volume 0.0 .. 1.0
//   ssaudio.stop()
//   ssaudio.is_playing()

#include "Console.h"
#include "Debug.h"
#include "Export.h"
#include "LuaTools.h"
#include "PluginLua.h"
#include "PluginManager.h"

#include <SDL.h>
#include <dlfcn.h>

#include "df/musicsoundst.h"
#include "df/global_objects.h"

#include <atomic>
#include <cmath>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#define MINIMP3_IMPLEMENTATION
#include "minimp3.h"
#include "minimp3_ex.h"

using namespace DFHack;

DFHACK_PLUGIN("ssaudio");

namespace DFHack {
    DBG_DECLARE(ssaudio, log, DebugCategory::LINFO);
}

namespace {

std::mutex g_mutex;                 // guards g_dev
SDL_AudioDeviceID g_dev = 0;
std::thread g_worker;
std::atomic<bool> g_cancel{false};
std::atomic<bool> g_decoding{false};

void close_device() {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_dev) {
        SDL_CloseAudioDevice(g_dev);
        g_dev = 0;
    }
}

// Stop whatever is playing and make sure the worker is finished before returning, so a second
// play() can never race the first one's device handoff.
void halt() {
    g_cancel.store(true);
    if (g_worker.joinable())
        g_worker.join();
    close_device();
    g_cancel.store(false);
}

} // namespace

static void play(color_ostream &out, std::string path, float volume = 1.0f) {
    halt();

    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;

    g_decoding.store(true);
    g_worker = std::thread([path, volume]() {
        mp3dec_ex_t dec;
        if (mp3dec_ex_open(&dec, path.c_str(), MP3D_SEEK_TO_SAMPLE) != 0) {
            g_decoding.store(false);
            return;
        }

        std::vector<mp3d_sample_t> pcm(static_cast<size_t>(dec.samples));
        size_t got = pcm.empty() ? 0 : mp3dec_ex_read(&dec, pcm.data(), pcm.size());
        const int channels = dec.info.channels;
        const int rate = dec.info.hz;
        mp3dec_ex_close(&dec);
        g_decoding.store(false);

        if (!got || channels <= 0 || rate <= 0 || g_cancel.load())
            return;

        if (volume < 1.0f) {
            for (size_t i = 0; i < got; ++i)
                pcm[i] = static_cast<mp3d_sample_t>(std::lround(pcm[i] * volume));
        }

        SDL_AudioSpec want{}, have{};
        want.freq = rate;
        want.format = AUDIO_S16SYS;         // what minimp3 hands back
        want.channels = static_cast<Uint8>(channels);
        want.samples = 4096;

        SDL_AudioDeviceID dev = SDL_OpenAudioDevice(nullptr, 0, &want, &have, 0);
        if (!dev)
            return;

        {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (g_cancel.load()) {          // stopped while we were decoding
                SDL_CloseAudioDevice(dev);
                return;
            }
            g_dev = dev;
        }

        SDL_QueueAudio(dev, pcm.data(), static_cast<Uint32>(got * sizeof(mp3d_sample_t)));
        SDL_PauseAudioDevice(dev, 0);
    });
}

static void stop(color_ostream &out) {
    halt();
}

static bool is_playing(color_ostream &out) {
    if (g_decoding.load())
        return true;
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_dev != 0 && SDL_GetQueuedAudioSize(g_dev) > 0;
}

// ---------------------------------------------------------------------------
// PLAYING THROUGH DF'S OWN ENGINE
// ---------------------------------------------------------------------------
//
// Everything above is our own SDL device, which works but is deaf to the game: DF's music
// slider does not touch it, and it plays over whatever DF is playing. DF's engine can do the
// job properly -- it is FMOD, it owns the mixer, and it applies the media volumes itself.
//
// It is reachable, and it took reading the game to find out. `dwarfort` is stripped, but its
// sound engine is not IN dwarfort: it lives in libg_src_lib.so and is linked dynamically, so
// the whole `musicsoundst` API is there as exported (mangled) symbols --
//
//     musicsoundst::set_song(std::string&, int slot, bool loops)
//     musicsoundst::startbackgroundmusic(int slot)
//     musicsoundst::stop_song()
//
// -- and DF ships g_src/music_and_sound.cpp, which shows exactly how it uses them itself:
// `set_custom_song` takes an id from `next_song_id++`, calls `set_song(file, id, loops)` to
// hand the file to FMOD, and from then on the track is an ordinary song that
// `startbackgroundmusic(id)` plays. That is the path this follows, with the same id
// allocation, so a track added here is the same kind of thing as a track added by a mod.
//
// df-structures does not declare these methods, so there is no DFHack binding for them; they
// are plain non-virtual member functions, so dlsym plus a call with `this` in front is the
// whole of the trick.

using set_song_fn = bool (*)(void *, std::string &, int, bool);
using start_bg_fn = void (*)(void *, int);
using stop_song_fn = void (*)(void *);
using is_playing_fn = bool (*)(void *);
using song_vol_fn = void (*)(void *, float);
using stop_card_fn = void (*)(void *);
using card_playing_fn = bool (*)(void *);

static set_song_fn g_set_song = nullptr;
static start_bg_fn g_start_bg = nullptr;
static stop_song_fn g_stop_song = nullptr;
static is_playing_fn g_song_playing = nullptr;
static song_vol_fn g_song_volume = nullptr;
static stop_card_fn g_stop_card = nullptr;
static card_playing_fn g_card_playing = nullptr;
static bool g_native_resolved = false;

static void resolve_native() {
    if (g_native_resolved)
        return;
    g_native_resolved = true;
    // RTLD_DEFAULT: libg_src_lib.so is already loaded -- DF is running out of it -- so this is
    // a lookup in the process, not a dlopen. Nothing new is mapped and nothing can go missing
    // halfway through a game.
    g_set_song = (set_song_fn) dlsym(RTLD_DEFAULT,
        "_ZN12musicsoundst8set_songERNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEEib");
    g_start_bg = (start_bg_fn) dlsym(RTLD_DEFAULT, "_ZN12musicsoundst20startbackgroundmusicEi");
    g_stop_song = (stop_song_fn) dlsym(RTLD_DEFAULT, "_ZN12musicsoundst9stop_songEv");
    // For answering "is it actually coming out?" -- the struct's own `song` field says what
    // was ASKED for, which is not the same question.
    g_song_playing = (is_playing_fn) dlsym(RTLD_DEFAULT, "_ZN12musicsoundst14song_is_playingEv");
    g_song_volume = (song_vol_fn) dlsym(RTLD_DEFAULT, "_ZN12musicsoundst15set_song_volumeEf");
    // CARDS are the short pieces DF's fortress music is actually made of; a song does not
    // play while one is going, so a request that ignores them is a request that does nothing.
    g_stop_card = (stop_card_fn) dlsym(RTLD_DEFAULT, "_ZN12musicsoundst9stop_cardEv");
    g_card_playing = (card_playing_fn) dlsym(RTLD_DEFAULT, "_ZN12musicsoundst15card_is_playingEv");
}

static bool native_available(color_ostream &out) {
    resolve_native();
    return g_set_song && g_start_bg && g_stop_song && df::global::musicsound;
}

// Hand a file to DF's engine and play it as a song. Returns the song id, or -1.
//
// The id comes from `next_song_id`, incremented, which is what DF's own set_custom_song does:
// ids below SONGNUM are the game's own tracks and must not be trodden on.
static int32_t play_native(color_ostream &out, std::string path, bool loops = false) {
    if (!native_available(out)) {
        out.printerr("ssaudio: DF's sound engine is not reachable in this process\n");
        return -1;
    }
    auto *ms = df::global::musicsound;
    int32_t id = ms->next_song_id++;
    if (!g_set_song(ms, path, id, loops)) {
        // fmt, not printf: color_ostream::print/printerr take a CONSTEVAL format string with
        // {} placeholders. "%s" compiles and prints itself, which is how this reported
        // "ssaudio: DF's engine would not load %s" for a while.
        out.printerr("ssaudio: DF's engine would not load {}\n", path);
        ms->next_song_id--;                 // give the id back; nothing was registered
        return -1;
    }
    // STOP FIRST. DF's own startbackgroundmusic only plays immediately when nothing is
    // playing -- read it in g_src/music_and_sound.cpp:
    //
    //     bool is_playing = internal->is_song_playing();
    //     if (new_song != song || !is_playing) {
    //         if (!is_playing) { ... start_song(new_song); }
    //         else { queued_song = new_song; }        // just queued
    //     }
    //
    // so asking for a track while the game is mid-song does not interrupt it: the request
    // goes into queued_song and the scheduler gets to it whenever it likes, or drops it. That
    // is exactly what "joke/dwarfify plays no sound" was -- the call worked and the music did
    // not change. Stopping first leaves nothing playing, and then the start is immediate.
    if (g_stop_card) g_stop_card(ms);
    g_stop_song(ms);
    g_start_bg(ms, id);
    return id;
}

// Play a song id that is already loaded -- one this returned earlier, or one of DF's own.
static void play_native_id(color_ostream &out, int32_t id) {
    if (!native_available(out))
        return;
    if (g_stop_card) g_stop_card(df::global::musicsound);
    g_stop_song(df::global::musicsound);       // see play_native: otherwise it only queues
    g_start_bg(df::global::musicsound, id);
}

// Is DF's engine actually playing a song right now?
static bool native_playing(color_ostream &out) {
    resolve_native();
    if (!g_song_playing || !df::global::musicsound)
        return false;
    return g_song_playing(df::global::musicsound);
}

// The engine's own song volume, 0..1, on top of the media sliders.
static void native_volume(color_ostream &out, float vol) {
    resolve_native();
    if (g_song_volume && df::global::musicsound)
        g_song_volume(df::global::musicsound, vol);
}

static void stop_native(color_ostream &out) {
    if (!native_available(out))
        return;
    g_stop_song(df::global::musicsound);
}

// A command as well as the Lua functions, so playback can be exercised straight from the
// console -- `dfhack-run ssaudio play <file>` -- without a script in the way. Worth having:
// a hot-loaded plugin does not get its Lua module registered in the running Lua state, so
// until DF is restarted the command is the ONLY way in.
static command_result do_command(color_ostream &out, std::vector<std::string> &params) {
    if (params.empty() || params[0] == "status") {
        out.print("ssaudio: %s\n", is_playing(out) ? "playing" : "idle");
        return CR_OK;
    }
    if (params[0] == "stop") {
        stop(out);
        out.print("ssaudio: stopped\n");
        return CR_OK;
    }
    if (params[0] == "native" && params.size() >= 2) {
        int32_t id = play_native(out, params[1], params.size() >= 3 && params[2] == "loop");
        if (id >= 0) {
            std::string msg = "ssaudio: playing " + params[1]
                + " through DF's engine as song " + std::to_string(id) + "\n";
            out.print("{}", msg);
        }
        return CR_OK;
    }
    if (params[0] == "native-id" && params.size() >= 2) {
        // the other half of the Lua API as a command, so a hot-loaded plugin -- whose Lua
        // module is not registered in the running state until DF restarts -- is still fully
        // usable from a script through run_command
        play_native_id(out, std::stoi(params[1]));
        return CR_OK;
    }
    if (params[0] == "native-status") {
        // BUILT AS A STRING, not passed as printf arguments. color_ostream::print does not
        // expand a format here -- the client gets the literal "%s" -- which is why the first
        // version of this reported "engine %s, song_is_playing=%s".
        std::string msg = std::string("ssaudio: engine ")
            + (native_available(out) ? "reachable" : "unreachable")
            + ", song_is_playing=" + (native_playing(out) ? "yes" : "no")
            + ", card_is_playing="
            + ((g_card_playing && df::global::musicsound
                && g_card_playing(df::global::musicsound)) ? "yes" : "no")
            + ", song=" + std::to_string(df::global::musicsound
                                         ? df::global::musicsound->song : -1)
            + "\n";
        out.print("{}", msg);
        return CR_OK;
    }
    if (params[0] == "native-volume" && params.size() >= 2) {
        native_volume(out, std::stof(params[1]));
        return CR_OK;
    }
    if (params[0] == "native-stop") {
        stop_native(out);
        out.print("ssaudio: told DF's engine to stop\n");
        return CR_OK;
    }
    if (params[0] == "play" && params.size() >= 2) {
        float volume = params.size() >= 3 ? std::stof(params[2]) : 1.0f;
        play(out, params[1], volume);
        out.print("ssaudio: playing %s\n", params[1].c_str());
        return CR_OK;
    }
    return CR_WRONG_USAGE;
}

DFhackCExport command_result plugin_init(color_ostream &out, std::vector<PluginCommand> &commands) {
    // The audio subsystem is brought up here, on the main thread, rather than in the worker.
    // DF has already initialised SDL itself; this is refcounted and safe to add to.
    if (SDL_InitSubSystem(SDL_INIT_AUDIO) != 0)
        out.printerr("ssaudio: SDL audio unavailable: %s\n", SDL_GetError());

    commands.push_back(PluginCommand(
        plugin_name,
        "Play an audio file.",
        do_command));

    return CR_OK;
}

DFhackCExport command_result plugin_shutdown(color_ostream &out) {
    halt();
    // AND NOTHING ELSE. This used to SDL_QuitSubSystem(SDL_INIT_AUDIO), which is the tidy
    // thing to do with a subsystem you brought up and the wrong thing to do inside somebody
    // else's process: the refcount is shared with DF, and unloading this plugin took the
    // game's audio down with it. After a few reload cycles during development the game's own
    // music stopped -- its scheduler went on starting songs, total_plays climbed, and the
    // engine reported song_is_playing=no for every one of them. Our own device is closed by
    // halt(); the subsystem stays up, which costs nothing.
    return CR_OK;
}

DFHACK_PLUGIN_LUA_FUNCTIONS {
    DFHACK_LUA_FUNCTION(play),
    DFHACK_LUA_FUNCTION(stop),
    DFHACK_LUA_FUNCTION(is_playing),
    DFHACK_LUA_FUNCTION(play_native),
    DFHACK_LUA_FUNCTION(play_native_id),
    DFHACK_LUA_FUNCTION(stop_native),
    DFHACK_LUA_FUNCTION(native_available),
    DFHACK_LUA_FUNCTION(native_playing),
    DFHACK_LUA_FUNCTION(native_volume),
    DFHACK_LUA_END
};
