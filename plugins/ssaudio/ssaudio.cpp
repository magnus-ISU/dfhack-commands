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
    SDL_QuitSubSystem(SDL_INIT_AUDIO);
    return CR_OK;
}

DFHACK_PLUGIN_LUA_FUNCTIONS {
    DFHACK_LUA_FUNCTION(play),
    DFHACK_LUA_FUNCTION(stop),
    DFHACK_LUA_FUNCTION(is_playing),
    DFHACK_LUA_END
};
