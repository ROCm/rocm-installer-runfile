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

# Package Puller Output directory
PULLER_OUTPUT="../package-extractor/packages-rocm"
PULLER_OUTPUT_AMDGPU="../package-extractor/packages-amdgpu"

# Packages list
PULLER_PACKAGES="${PULLER_PACKAGES:-rocm rocdecode rocdecode-test rocdecode-dev rocm-validation-suite rocm-llvm-dev rocm-language-runtime rocm-opencl-runtime rocprofiler-systems rocprofiler-compute rdc rocjpeg rocjpeg-dev rocjpeg-test}"
PULLER_PACKAGES_EL="${PULLER_PACKAGES_EL:-rocm rocdecode rocdecode-test rocdecode-devel rocm-validation-suite rocm-llvm-devel rocm-opencl-runtime rocprofiler-systems rocprofiler-compute rdc rocjpeg rocjpeg-devel rocjpeg-test}"
PULLER_PACKAGES_SLE="${PULLER_PACKAGES_SLE:-rocm rocdecode rocdecode-test rocdecode-devel rocm-validation-suite rocm-llvm-devel rocm-opencl-runtime rocprofiler-systems rocprofiler-compute rdc rocjpeg rocjpeg-devel rocjpeg-test}"
PULLER_PACKAGES_AMZN="${PULLER_PACKAGES_AMZN:-rocm rocdecode rocdecode-test rocdecode-devel rocm-validation-suite rocm-llvm-devel rocm-opencl-runtime rocprofiler-systems rocprofiler-compute rdc rocjpeg rocjpeg-devel rocjpeg-test}"
PULLER_PACKAGES_AMDGPU="amdgpu-dkms"


###### Functions ###############################################################

os_release() {
    if [[ -r  /etc/os-release ]]; then
        . /etc/os-release

        DISTRO_NAME=$ID
        DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
        DISTRO_MAJOR_VER=${DISTRO_VER%.*}
        
        case "$ID" in
        ubuntu|debian)
            PULL_DISTRO_TYPE=deb
            ;;
        rhel|ol|rocky)
            PULL_DISTRO_TYPE=el
            ;;
        sles)
            PULL_DISTRO_TYPE=sle
            ;;
        amzn)
            PULL_DISTRO_TYPE=amzn
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
    
    echo "Setup running on $DISTRO_NAME $DISTRO_VER."
}

configure_setup() {
    echo ++++++++++++++++++++++++++++++++
    
    if [ $PULL_DISTRO_TYPE == "deb" ]; then
        echo Configuring for DEB $DISTRO_VER.
        
        if [[ $DISTRO_VER == 24.04 ]] || [[ $DISTRO_VER == 13 ]]; then
            # Ubuntu 24.04 / Debian 13 configuration
            PULLER_CONFIG="${PULLER_CONFIG:-config/deb/24.04/rocm-7.2-24.04.config}"
            if [[ -n $PULLER_CONFIG_24_04 ]]; then
                PULLER_CONFIG=$PULLER_CONFIG_24_04
            fi
            
        elif [[ $DISTRO_VER == 22.04 ]] || [[ $DISTRO_VER == 12 ]]; then
            # Ubuntu 22.04 / Debian 12 configuration
            PULLER_CONFIG="${PULLER_CONFIG:-config/deb/22.04/rocm-7.2-22.04.config}"
            if [[ -n $PULLER_CONFIG_22_04 ]]; then
                PULLER_CONFIG=$PULLER_CONFIG_22_04
            fi
            
        else
            echo "Unsupported DEB config for OS"
            exit 1
        fi
        
    elif [ $PULL_DISTRO_TYPE == "el" ]; then
        echo Configuring for EL $DISTRO_MAJOR_VER.
        
        if [[ $DISTRO_MAJOR_VER == 10 ]]; then
            # RHEL 10 / OL 10 configuration
            PULLER_CONFIG_EL="${PULLER_CONFIG_EL:-config/el/10/rocm-7.2-el10.config}"
            if [[ -n $PULLER_CONFIG_EL_10 ]]; then
                PULLER_CONFIG_EL=$PULLER_CONFIG_EL_10
            fi
            
        elif [[ $DISTRO_MAJOR_VER == 9 ]]; then
            # RHEL 9 / OL 9 / Rocky 9 configuration
            PULLER_CONFIG_EL="${PULLER_CONFIG_EL:-config/el/9/rocm-7.2-el9.config}"
            if [[ -n $PULLER_CONFIG_EL_9 ]]; then
                PULLER_CONFIG_EL=$PULLER_CONFIG_EL_9
            fi
            
        elif [[ $DISTRO_MAJOR_VER == 8 ]]; then
            # RHEL 8 / OL 8 configuration
            PULLER_CONFIG_EL="${PULLER_CONFIG_EL:-config/el/8/rocm-7.2-el8.config}"
            if [[ -n $PULLER_CONFIG_EL_8 ]]; then
                PULLER_CONFIG_EL=$PULLER_CONFIG_EL_8
            fi
            
        else
            echo "Unsupported EL config for OS"
            exit 1
        fi
    
    elif [ $PULL_DISTRO_TYPE == "sle" ]; then
        echo Configuring for SLE $DISTRO_VER.
        
        # SLES 15 configuration
        PULLER_CONFIG_SLE="${PULLER_CONFIG_SLE:-config/sle/15.6/rocm-7.2-sle-15.6.config}"
        if [[ -n $PULLER_CONFIG_SLE_15 ]]; then 
            PULLER_CONFIG_SLE=$PULLER_CONFIG_SLE_15 
        fi
        
    elif [ $PULL_DISTRO_TYPE == "amzn" ]; then
        echo Configuring for Amazon Linux $DISTRO_VER.
        
        # Amazon configuration
        PULLER_CONFIG_AMZN="${PULLER_CONFIG_AMZN:-config/sle/15.6/rocm-7.2-sle-15.6.config}"
        if [[ -n $PULLER_CONFIG_AL2023 ]]; then 
            PULLER_CONFIG_AMZN=$PULLER_CONFIG_AL2023 
        fi
        
    else
        echo Invalid Distro Type: $PULL_DISTRO_TYPE
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

configure_setup

echo Running Package Puller...

setup_rocm() {
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
            
        elif [ $PULL_DISTRO_TYPE == "amzn" ]; then
        
            echo "Setting up for Amazon RPM."
            ./package-puller-el.sh amd config="$PULLER_CONFIG_AMZN" pkg="$PULLER_PACKAGES_AMZN"
            
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
}

setup_amdgpu() {
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
            
        elif [ $PULL_DISTRO_TYPE == "amzn" ]; then
        
             echo "Setting up for RPM AMDGPU builds."
            ./package-puller-el.sh amd config="$PULLER_CONFIG_AMZN" pkg="$PULLER_PACKAGES_AMDGPU"
            
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
}

setup_rocm

setup_amdgpu

echo Running Package Puller...Complete

