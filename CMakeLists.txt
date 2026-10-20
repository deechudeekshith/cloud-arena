cmake_minimum_required(VERSION 3.16)
project(CloudArena VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Prefer release for performance on integrated graphics
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_package(raylib QUIET)

if(NOT raylib_FOUND)
  # Fallback: try pkg-config
  find_package(PkgConfig QUIET)
  if(PKG_CONFIG_FOUND)
    pkg_check_modules(RAYLIB raylib)
  endif()
endif()

add_executable(cloud_arena
  src/main.cpp
  src/Game.cpp
  src/Player.cpp
  src/Bot.cpp
  src/Projectile.cpp
  src/Arena.cpp
  src/UI.cpp
)

target_include_directories(cloud_arena PRIVATE src)

if(raylib_FOUND)
  target_link_libraries(cloud_arena PRIVATE raylib)
elseif(RAYLIB_FOUND)
  target_include_directories(cloud_arena PRIVATE ${RAYLIB_INCLUDE_DIRS})
  target_link_libraries(cloud_arena PRIVATE ${RAYLIB_LIBRARIES})
  target_compile_options(cloud_arena PRIVATE ${RAYLIB_CFLAGS_OTHER})
else()
  # Last resort: assume headers/libs are in default paths
  target_link_libraries(cloud_arena PRIVATE raylib m pthread dl rt GL X11)
endif()

# Warnings but don't fail build on them
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
  target_compile_options(cloud_arena PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()