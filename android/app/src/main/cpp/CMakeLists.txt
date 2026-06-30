cmake_minimum_required(VERSION 3.22.1)

project(
    tracker
    VERSION 1.0.0
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(
    tracker
    SHARED
    tracker.cpp
)

find_library(log-lib     log)
find_library(android-lib android)

target_link_libraries(
    tracker
    PRIVATE
    ${log-lib}
    ${android-lib}
)

target_compile_options(tracker PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Wno-unused-parameter
    -O2
    # std::mutex is used for thread safety — exceptions/RTTI must be enabled
)
