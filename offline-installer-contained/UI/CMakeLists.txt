# ##############################################################################
# Copyright (c) 2024-2025 Advanced Micro Devices, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# ##############################################################################

message(STATUS "+++++++++++++++++++++++++++++++++++++++++++")
message(STATUS "Creating for ROCm Runfile Installer UI")
message(STATUS "+++++++++++++++++++++++++++++++++++++++++++")

message(STATUS "UI: CMAKE_SOURCE_DIR               = " ${CMAKE_SOURCE_DIR})
message(STATUS "UI: CMAKE_BINARY_DIR               = " ${CMAKE_BINARY_DIR})
message(STATUS "UI: CMAKE_CURRENT_SOURCE_DIR       = " ${CMAKE_CURRENT_SOURCE_DIR})
message(STATUS "UI: CMAKE_CURRENT_BINARY_DIR       = " ${CMAKE_CURRENT_BINARY_DIR})
message(STATUS "UI: CMAKE_CURRENT_LIST_DIR         = " ${CMAKE_CURRENT_LIST_DIR})
message(STATUS "VERSION_STRING                     = " ${VERSION_STRING})
message(STATUS "DISTRO_BUILD_STRING                = " ${DISTRO_BUILD_STRING})
message(STATUS "AMDGPU_DKMS                        = " ${AMDGPU_DKMS})

message(STATUS "Installer_directory = " ${INSTALLER_DIRECTORY})
message(STATUS "UI binary location  = " ${CMAKE_BINARY_DIR})

# Find ncurses related items
find_package(Curses REQUIRED)
find_library(MENU_LIBRARY menu)

include_directories(${CURSES_INCLUDE_DIR} ${CURSES_INCLUDE_DIR}/ncurses)

file(GLOB SOURCEFILES "src/*.c")

add_executable(rocm_ui ${SOURCEFILES})

# Set the UI version
add_compile_definitions(INSTALLER_VERSION="${VERSION_STRING}")
add_compile_definitions(ROCM_VERSION="${ROCM_VERSION_STRING}")
add_compile_definitions(DISTRO_BUILD="${DISTRO_BUILD_STRING}")
add_compile_definitions(AMDGPU_DKMS_BUILD="${AMDGPU_DKMS}")

# UI target settings
target_compile_options(rocm_ui PRIVATE -Wall -Wextra -Werror)
target_link_libraries(rocm_ui ${CURSES_LIBRARIES} ${MENU_LIBRARY})

add_dependencies(rocm_installer rocm_ui)

add_custom_command(TARGET rocm_ui
                  COMMAND echo "Copying UI to installer directory"
                  COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_CURRENT_BINARY_DIR}/rocm_ui ${INSTALLER_DIRECTORY}/)
