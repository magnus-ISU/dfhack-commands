# ssaudio -- built as a DFHack external plugin (see `make build-ssaudio` in the repo root).
#
# SDL2 is linked, not just included: this actually calls SDL_OpenAudioDevice and friends,
# unlike plugins that only read DF's SDL-adjacent globals. The library is already loaded in
# the process (DF is built on SDL2), so the link resolves against that copy at runtime.
# On Windows there is no system SDL2 to link; use the import lib from the SDL2 devel zip that
# DFHack's top-level CMakeLists downloads into depends/ (it sets SDL_VERSION when it does). The
# DLL itself resolves at load time to the SDL2.dll already living in DF's process.
if(WIN32)
    if(NOT SDL_VERSION)
        set(SDL_VERSION 2.26.2)
    endif()
    set(SSAUDIO_SDL2 ${dfhack_SOURCE_DIR}/depends/SDL2/SDL2-${SDL_VERSION}/lib/x64/SDL2.lib)
else()
    set(SSAUDIO_SDL2 SDL2)
endif()
dfhack_plugin(ssaudio ssaudio.cpp LINK_LIBRARIES lua ${SSAUDIO_SDL2})
target_include_directories(ssaudio PRIVATE ${SDL2_INCLUDE_DIRS} ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(ssaudio PRIVATE cxx_std_17)
