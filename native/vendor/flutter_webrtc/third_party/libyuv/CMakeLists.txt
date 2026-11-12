# Pinned libyuv 209763ad77fed3df2d57503d3ef40761e9473649.
# Windows x64 SIMD conversions; no JPEG or command-line tools needed.
file(GLOB PIRATE_YUV_SOURCES CONFIGURE_DEPENDS source/*.cc)
add_library(pirate_yuv STATIC ${PIRATE_YUV_SOURCES})
target_include_directories(pirate_yuv PUBLIC include)
target_compile_definitions(pirate_yuv PRIVATE LIBYUV_DISABLE_JPEG)
