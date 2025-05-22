#!/bin/bash

# #############################################################################
# Copyright (C) 2024-2025 Advanced Micro Devices, Inc. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
# #############################################################################


###### Functions ###############################################################

usage() {
cat <<END_USAGE
Usage: $PROG [options]

[options}:
    help = Display this help information.
    
    rel=<release number> 
        Set the ROCm release sourced for the rocm-examples test ie.rel=6.3.1
END_USAGE
}

os_release() {
    if [[ -r  /etc/os-release ]]; then
        . /etc/os-release

        DISTRO_NAME=$ID
        DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')

        case "$ID" in
        ubuntu|debian)
	    DISTRO_PACKAGE_MGR="apt"
	    PACKAGE_TYPE="deb"
	    ;;
	rhel|ol)
	    DISTRO_PACKAGE_MGR="dnf"
	    PACKAGE_TYPE="rpm"
            ;;
        sles)
	    DISTRO_PACKAGE_MGR="zypper"
	    PACKAGE_TYPE="rpm"
            ;;
        *)
            echo "$ID is not a supported OS"
            exit 1
            ;;
        esac
    else
        echo "Unsupported OS"
        exit 1
    fi
    
    echo "Running test on $DISTRO_NAME $DISTRO_VER."
}

install_glslang() {
    echo ------------------------------------------------------
    echo Install glslang...
    
    if [ -d glslang ]; then
        $SUDO rm -r glslang
    fi
    
    # glslang is not available from repos, build from source
    git clone https://github.com/KhronosGroup/glslang.git
    cd glslang
    python3 ./update_glslang_sources.py
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$(pwd)/install"
    cd build
    make -j$(nproc) install
    
    echo Install glslang...Complete.
}

install_deps() {
    echo ------------------------------------------------------
    echo Install dependencies...

    # install any dependencies for rocm-examples
    if [ $DISTRO_PACKAGE_MGR == "apt" ]; then
        $SUDO apt-get install -y git cmake libglfw3-dev libsuitesparse-dev libtbb-dev
        
    elif [ $DISTRO_PACKAGE_MGR == "dnf" ]; then
    
        if [[ $DISTRO_VER == 8* ]]; then
            echo Installing deps for RHEL8...
            $SUDO dnf install -y gcc-c++ git cmake glfw-devel vulkan-headers vulkan-loader vulkan-validation-layers mesa-libGL-devel
            $SUDO dnf install -y gcc-toolset-11
            install_glslang
            
        elif [[ $DISTRO_VER == 9* ]]; then
	    echo Installing deps for RHEL9...
            $SUDO dnf install -y gcc-c++ git cmake glfw-devel glslang-devel vulkan-loader-devel libshaderc-devel
        else
            echo "Unsupported version for EL."
            exit 1
        fi
        
    elif [ $DISTRO_PACKAGE_MGR == "zypper" ]; then
        $SUDO zypper install -y git libglfw-devel gcc-c++
        
        if [[ $DISTRO_VER == 15.5 ]]; then
            $SUDO pip install cmake
        else
            $SUDO zypper install -y cmake
        fi
        
    else
        echo Unsupported Distro.
        exit 1
    fi

    echo Install dependencies...Complete.
}

setup_rocm() {
    echo ------------------------------------------------------
    echo Setting up ROCm paths...
    
    # Look for the rocm directory
    ROCM_VER_DIR=$(find / -type f -path '*/rocm-*/.info/version' ! -path '*/rocm-installer/component-rocm/*' -print -quit 2>/dev/null)

    if [ -n "$ROCM_VER_DIR" ]; then
        echo "ROCm Install Directory found at: $ROCM_VER_DIR"
        
        ROCM_DIR=${ROCM_VER_DIR%%.info*}
        echo ROCM_DIR = $ROCM_DIR
    else
        echo "ROCm Install Directory not found"
        exit 1
    fi

    # Set the ROCm paths
    export ROCM_PATH="$ROCM_DIR"
    
    # Set compiler paths
    export CXX=$ROCM_PATH/llvm/bin/amdclang++
    export CC=$ROCM_PATH/llvm/bin/amdclang
    
    echo Setting up ROCm paths...Complete.
}

get_rocm_examples() {
    echo ------------------------------------------------------
    echo Downloading rocm-examples : $ROCM_REL ...
    
    if [ -d rocm-examples ]; then
        $SUDO rm -r rocm-examples
    fi

    # Download the rocm-example source (use release if present)
    if [[ -n $ROCM_REL ]]; then
        git clone https://github.com/ROCm/rocm-examples.git -b "rocm-$ROCM_REL"
    else
        git clone https://github.com/ROCm/rocm-examples.git --depth=1
    fi

    echo Downloading rocm-examples : $ROCM_REL ...Complete
}

build_rocm_examples() {
    echo ------------------------------------------------------
    echo Building rocm-examples...
    
    cd rocm-examples
    
    # Build rocm-examples
    mkdir build && cd build

    cmake .. -DROCM_ROOT=$ROCM_PATH
    cmake --build . -- -j$(nproc)
    
    echo Building rocm-examples...Complete.
}

test_rocm_examples() {
    echo ------------------------------------------------------
    echo Testing rocm-examples...
    
    ctest --output-on-failure
    
    echo Testing rocm-examples...Complete.
}

####### Main script ##############################################################

echo ===============================
echo ROCM-EXAMPLES TESTER
echo ===============================

PROG=${0##*/}
SUDO=$([[ $(id -u) -ne 0 ]] && echo "sudo" ||:)
echo SUDO: $SUDO

os_release

# parse args
while (($#))
do
    case "$1" in
    help)
        usage
        exit 0
        ;;
    rel=*)
        ROCM_REL="${1#*=}"
        echo "Using ROCm release : $ROCM_REL"
        shift
        ;;
    *)
        shift
        ;;
    esac
done

# Look for the rocm directory
ROCM_VER_DIR=$(find / -type f -path '*/rocm-*/.info/version' ! -path '*/rocm-installer/component-rocm/*' -print -quit 2>/dev/null)

if [ -n "$ROCM_VER_DIR" ]; then
    echo ------------------------------------------------------
    echo "ROCm Install Directory found at: $ROCM_VER_DIR"
    
    ROCM_DIR=${ROCM_VER_DIR%%.info*}
    echo ROCM_DIR = $ROCM_DIR
else
    echo "ROCm Install Directory not found"
    exit 1
fi

setup_rocm

install_deps

get_rocm_examples

build_rocm_examples

test_rocm_examples

