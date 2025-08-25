cmake_minimum_required(VERSION 3.16)
project(intperint_helper LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(intperint_helper
    src/udssrv.cpp
)

target_include_directories(intperint_helper PRIVATE include)

if(APPLE)
    target_compile_options(intperint_helper PRIVATE -Wall -Wextra -Wpedantic)
endif()
