cmake_minimum_required(VERSION 3.15)
project(abordage_crypto_plugin LANGUAGES C)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/crypto")
set(abordage_crypto_bundled_libraries $<TARGET_FILE:abordage_crypto> PARENT_SCOPE)
