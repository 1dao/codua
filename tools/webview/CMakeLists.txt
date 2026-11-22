cmake_minimum_required(VERSION 3.16)
project(codua_webview LANGUAGES C CXX)

set(WEBVIEW_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../webview" CACHE PATH "Path to webview/webview")
if(NOT EXISTS "${WEBVIEW_SOURCE_DIR}/core/include/webview/webview.h")
    message(FATAL_ERROR "Set WEBVIEW_SOURCE_DIR to a webview/webview checkout")
endif()

set(WEBVIEW_USE_COMPAT_MINGW ON)
set(WEBVIEW_BUILD_SHARED_LIBRARY OFF)
set(WEBVIEW_BUILD_STATIC_LIBRARY OFF)
add_subdirectory("${WEBVIEW_SOURCE_DIR}" webview)

add_executable(codua-webview main.cpp)
target_link_libraries(codua-webview PRIVATE webview::core)
set_target_properties(codua-webview PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/$<0:>")
if(MINGW)
    target_link_options(codua-webview PRIVATE -static "$<$<CONFIG:Release>:-s>")
endif()
