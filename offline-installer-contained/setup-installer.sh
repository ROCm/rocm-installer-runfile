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

# Package Puller Input Config
PULLER_CONFIG="${PULLER_CONFIG:-config/deb/22.04/rocm-6.4.1-22.04.config}"
PULLER_CONFIG_EL="${PULLER_CONFIG_EL:-config/el/9/rocm-6.4.1-el9.config}"
PULLER_CONFIG_SLE="${PULLER_CONFIG_SLE:-config/sle/15.6/rocm-6.4.1-sle-15.6.config}"

# Package Puller Output directory
PULLER_OUTPUT="../package-extractor/packages-rocm"
PULLER_OUTPUT_AMDGPU="../package-extractor/packages-amdgpu"

# Packages list
PULLER_PACKAGES="${PULLER_PACKAGES:-rocm rocdecode rocdecode-test rocdecode-dev rocm-validation-suite rocm-llvm-dev rocm-language-runtime rocm-opencl-runtime rocprofiler-systems rocprofiler-compute rdc rocjpeg rocjpeg-dev rocjpeg-test}"
PULLER_PACKAGES_EL="${PULLER_PACKAGES_EL:-rocm rocdecode rocdecode-test rocdecode-devel rocm-validation-suite rocm-llvm-devel rocprofiler-systems rocprofiler-compute rdc rocjpeg rocjpeg-devel rocjpeg-test}"
PULLER_PACKAGES_SLE="${PULLER_PACKAGES_SLE:-rocm rocdecode rocdecode-test rocdecode-devel rocm-validation-suite rocm-llvm-devel rocprofiler-systems rocprofiler-compute rdc rocjpeg rocjpeg-devel rocjpeg-test}"
PULLER_PACKAGES_AMDGPU="amdgpu-dkms"


###### Functions ###############################################################

os_release() {
    if [[ -r  /etc/os-release ]]; then
        . /etc/os-release

        DISTRO_NAME=$ID
        DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')

        case "$ID" in
        ubuntu)
	    echo "Setup running on Ubuntu $DISTRO_VER."
	    PULL_DISTRO_TYPE=deb
	    ;;
	rhel)
	    echo "Setup running on RHEL $DISTRO_VER."
	    PULL_DISTRO_TYPE=el
            ;;
        sles)
	    echo "Setup running on SLES $DISTRO_VER."
	    PULL_DISTRO_TYPE=sle
            ;;
        *)
            echo "$ID is not a Unsupported OS"
            exit 1
            ;;
        esac
    else
        echo "Unsupported OS"
        exit 1
    fi
}


####### Main script ###############################################################

echo ============================
echo ROCM RUNFILE INSTALLER SETUP
echo ============================

SUDO=$([[ $(id -u) -ne 0 ]] && echo "sudo" ||:)
echo SUDO: $SUDO

os_release

echo Running Package Puller...

# Pull ROCm packages for the currently running OS (debian or rpm)
pushd package-puller
    echo -------------------------------------------------------------
    echo "Setting up for ROCm components..."

    if [ $PULL_DISTRO_TYPE == "deb" ]; then
        
        echo "Setting up for DEB."
        ./package-puller-deb.sh amd config="$PULLER_CONFIG" pkg="$PULLER_PACKAGES"
        
    elif [ $PULL_DISTRO_TYPE == "el" ]; then
    
    	echo "Setting up for EL RPM."
        ./package-puller-el.sh amd config="$PULLER_CONFIG_EL" pkg="$PULLER_PACKAGES_EL"
        
    elif [ $PULL_DISTRO_TYPE == "sle" ]; then
    
        echo "Setting up for SLES RPM."
        ./package-puller-sle.sh amd config="$PULLER_CONFIG_SLE" pkg="$PULLER_PACKAGES_SLE"
        
    else
        echo Invalid Distro Type: $PULL_DISTRO_TYPE
        exit 1
    fi
    
    # check if package pull was successful
    if [[ $? -ne 0 ]]; then
        echo -e "\e[31mFailed pull of ROCm packages.\e[0m"
        exit 1
    fi
    
    if [ -d $PULLER_OUTPUT ]; then
        echo -e "\e[93mExtraction directory exists. Removing: $PULLER_OUTPUT\e[0m"
        $SUDO rm -rf $PULLER_OUTPUT
    fi
    mv packages/packages-amd $PULLER_OUTPUT
    
    echo "Setting up for ROCm components...Complete."
popd

# Pull AMDGPU packages for the currently running OS (debian or rpm)
pushd package-puller
    echo -------------------------------------------------------------
    echo "Setting up for AMDGPU components..."

    if [ $PULL_DISTRO_TYPE == "deb" ]; then
    
        echo "Setting up for DEB."
        ./package-puller-deb.sh amd config="$PULLER_CONFIG" pkg="$PULLER_PACKAGES_AMDGPU"
        
    elif [ $PULL_DISTRO_TYPE == "el" ]; then
    
         echo "Setting up for RPM AMDGPU builds."
        ./package-puller-el.sh amd config="$PULLER_CONFIG_EL" pkg="$PULLER_PACKAGES_AMDGPU"
        
    elif [ $PULL_DISTRO_TYPE == "sle" ]; then
    
         echo "Setting up for RPM AMDGPU builds."
        ./package-puller-sle.sh amd config="$PULLER_CONFIG_SLE" pkg="$PULLER_PACKAGES_AMDGPU"
        
    else
        echo Invalid Distro Type: $PULL_DISTRO_TYPE
        exit 1
    fi
    
    # check if package pull was successful
    if [[ $? -ne 0 ]]; then
        echo -e "\e[31mFailed pull of AMDGPU packages.\e[0m"
        exit 1
    fi

    if [ -d $PULLER_OUTPUT_AMDGPU ]; then
        echo -e "\e[93mExtraction directory exists. Removing: $PULLER_OUTPUT_AMDGPU\e[0m"
        $SUDO rm -rf $PULLER_OUTPUT_AMDGPU
    fi
    mv packages/packages-amd $PULLER_OUTPUT_AMDGPU
    
    echo "Setting up for AMDGPU components...Complete."
popd

echo Running Package Puller...Complete

