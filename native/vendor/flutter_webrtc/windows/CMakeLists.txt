cmake_minimum_required(VERSION 3.15)
set(PROJECT_NAME "flutter_webrtc")
project(${PROJECT_NAME} LANGUAGES CXX)

if (CMAKE_VERSION VERSION_GREATER_EQUAL "3.24.0")
  cmake_policy(SET CMP0135 NEW)
endif()

# Add the libwebrtc dependency
include("${CMAKE_CURRENT_SOURCE_DIR}/../third_party/CMakeLists.txt")

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "flutter_webrtc_plugin")

add_definitions(-DLIB_WEBRTC_API_DLL)
add_definitions(-DRTC_DESKTOP_DEVICE)

add_library(${PLUGIN_NAME} SHARED
  "../common/cpp/src/flutter_common.cc"
  "../common/cpp/src/flutter_data_channel.cc"
  "../common/cpp/src/flutter_data_packet_cryptor.cc"
  "../common/cpp/src/flutter_frame_cryptor.cc"
  "../common/cpp/src/flutter_media_stream.cc"
  "../common/cpp/src/flutter_utf8_sanitize.cc"
  "../common/cpp/src/flutter_peerconnection.cc"
  "../common/cpp/src/flutter_frame_capturer.cc"
  "../common/cpp/src/flutter_video_renderer.cc"
  "../common/cpp/src/flutter_screen_capture.cc"
  "../common/cpp/src/flutter_webrtc.cc"
  "../common/cpp/src/flutter_webrtc_base.cc"
  "application_loopback_capturer.cc"
  "fast_screen_capture.cc"
  "loopback_capturer_factory.cc"
  "flutter_webrtc_plugin.cc"
  "task_runner_windows.cc"
)

include_directories(
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/svpng"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/include"
)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libyuv" "${CMAKE_CURRENT_BINARY_DIR}/pirate_yuv")
apply_standard_settings(${PLUGIN_NAME})
# C++/WinRT uses standard exception propagation. Flutter's default helper sets
# _HAS_EXCEPTIONS=0; replace it rather than passing conflicting /D definitions.
get_target_property(PIRATE_PLUGIN_DEFINITIONS ${PLUGIN_NAME} COMPILE_DEFINITIONS)
list(REMOVE_ITEM PIRATE_PLUGIN_DEFINITIONS "_HAS_EXCEPTIONS=0")
set_property(TARGET ${PLUGIN_NAME} PROPERTY COMPILE_DEFINITIONS "${PIRATE_PLUGIN_DEFINITIONS};_HAS_EXCEPTIONS=1")
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/include"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE 
  flutter
  flutter_wrapper_plugin
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/lib/libwebrtc.dll.lib"
  avrt.lib
  ksuser.lib
  mmdevapi.lib
  ole32.lib
  runtimeobject.lib
  windowsapp.lib
  uuid.lib
  winmm.lib
  d3d11.lib
  dxgi.lib
  gdi32.lib
  pirate_yuv
)

# List of absolute paths to libraries that should be bundled with the plugin
set(flutter_webrtc_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/lib/libwebrtc.dll"
  PARENT_SCOPE
)

# Explicit diagnostic target, kept out of the portable app's Release directory.
add_executable(pirate_capture_probe EXCLUDE_FROM_ALL
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../tool/windows_capture_probe.cpp"
  "fast_screen_capture.cc")
target_compile_features(pirate_capture_probe PRIVATE cxx_std_17)
target_compile_options(pirate_capture_probe PRIVATE /EHsc)
target_compile_definitions(pirate_capture_probe PRIVATE LIB_WEBRTC_API_DLL RTC_DESKTOP_DEVICE _HAS_EXCEPTIONS=1)
target_include_directories(pirate_capture_probe PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/include")
target_link_libraries(pirate_capture_probe PRIVATE pirate_yuv
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/lib/libwebrtc.dll.lib"
  d3d11.lib dxgi.lib gdi32.lib runtimeobject.lib windowsapp.lib winmm.lib)
set_target_properties(pirate_capture_probe PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/diagnostics")
add_custom_command(TARGET pirate_capture_probe POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/lib/libwebrtc.dll" "$<TARGET_FILE_DIR:pirate_capture_probe>")
