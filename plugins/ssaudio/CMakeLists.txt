# ssaudio -- built as a DFHack external plugin (see `make build-ssaudio` in the repo root).
#
# SDL2 is linked, not just included: this actually calls SDL_OpenAudioDevice and friends,
# unlike plugins that only read DF's SDL-adjacent globals. The library is already loaded in
# the process (DF is built on SDL2), so the link resolves against that copy at runtime.
dfhack_plugin(ssaudio ssaudio.cpp LINK_LIBRARIES lua SDL2)
target_include_directories(ssaudio PRIVATE ${SDL2_INCLUDE_DIRS} ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(ssaudio PRIVATE cxx_std_17)
