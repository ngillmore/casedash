cmake_minimum_required(VERSION 3.20)
project(casedash LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 REQUIRED COMPONENTS Gui Qml Quick QuickControls2)
find_package(LayerShellQt QUIET)

add_executable(casedash host.cpp)

target_link_libraries(casedash PRIVATE
    Qt6::Gui Qt6::Qml Qt6::Quick Qt6::QuickControls2)

if (LayerShellQt_FOUND)
    target_link_libraries(casedash PRIVATE LayerShellQt::Interface)
    target_compile_definitions(casedash PRIVATE HAVE_LAYERSHELLQT=1)
    message(STATUS "casedash: LayerShellQt found - output pinning enabled")
else()
    message(WARNING "casedash: LayerShellQt NOT found - output pinning disabled")
endif()
