cmake_minimum_required(VERSION 3.24)
project(Portal2VisionAudio LANGUAGES C CXX)
if(NOT EXISTS "${P2_OPENAL_SOURCE}/CMakeLists.txt")
    message(FATAL_ERROR "Pass P2_OPENAL_SOURCE pointing to OpenAL Soft 1.25.2")
endif()
set(LIBTYPE STATIC CACHE STRING "" FORCE)
set(ALSOFT_UTILS OFF CACHE BOOL "" FORCE)
set(ALSOFT_EXAMPLES OFF CACHE BOOL "" FORCE)
set(ALSOFT_TESTS OFF CACHE BOOL "" FORCE)
set(ALSOFT_ENABLE_MODULES OFF CACHE BOOL "" FORCE)
set(ALSOFT_REQUIRE_COREAUDIO ON CACHE BOOL "" FORCE)
set(ALSOFT_UPDATE_BUILD_VERSION OFF CACHE BOOL "" FORCE)
set(HAVE_LIBATOMIC OFF CACHE BOOL "" FORCE)
foreach(backend PIPEWIRE PULSEAUDIO ALSA OSS SOLARIS SNDIO WASAPI DSOUND WINMM JACK OBOE OPENSL PORTAUDIO SDL3 SDL2 WAVE)
    set(ALSOFT_BACKEND_${backend} OFF CACHE BOOL "" FORCE)
endforeach()
add_subdirectory("${P2_OPENAL_SOURCE}" openal)
# SDK 27 adds a nonblocking contract to AURenderCallback. Keep this diagnostic
# as a warning for the existing upstream callbacks; realtime audio behavior
# still needs execution testing. Source properties appear after -Werror flags.
set_source_files_properties("${P2_OPENAL_SOURCE}/alc/backends/coreaudio.cpp"
    DIRECTORY "${P2_OPENAL_SOURCE}"
    PROPERTIES COMPILE_OPTIONS "-Wno-deprecated-anon-enum-enum-conversion;-Wno-error=function-effects")
