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

get_version() {
    i=0
    
    while IFS= read -r line; do
        case $i in
            0) INSTALLER_VERSION="$line" ;;
            1) ROCM_VERSION="$line" ;;
            2) DISTRO_BUILD_VERSION="$line" ;;
            3) ROCM_BUILD_NUM="$line" ;;
            4) AMDGPU_DKMS_BUILD_NUM="$line" ;;
            5) BUILD_INSTALLER_NAME="$line" ;;
        esac
        
        i=$((i+1))
    done < "./VERSION"
}

print_version() {
    echo ROCm Runfile Installer Version : $INSTALLER_VERSION-$ROCM_VERSION
    echo ROCm Runfile Installer Package : $BUILD_INSTALLER_NAME
}

os_release() {
    get_version
    
    if [[ -r  /etc/os-release ]]; then
        . /etc/os-release

        DISTRO_NAME=$ID
        DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')

        case "$ID" in
        ubuntu)
            echo "Installer running on Ubuntu $DISTRO_VER."
            ;;
        debian)
            echo "Installer running on Debian $DISTRO_VER."
            ;;
        rhel)
            echo "Installer running on RHEL $DISTRO_VER."
            ;;
        ol)
            echo "Installer running on Oracle Linux $DISTRO_VER."
            ;;
        sles)
            echo "Installer running on SLES $DISTRO_VER."
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
}

validate_version() {
    # For non-local builds, verify package version matches for the running host distribution
    if [[ $BUILD_INSTALLER_NAME != *"local"* ]]; then
    
        local version_build=${DISTRO_BUILD_VERSION%%.*}
        local version_install=${DISTRO_VER%%.*}
    
        if [ $version_build != $version_install ]; then
            echo -e "\e[31m++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\e[0m"
            echo -e "\e[31mError: ROCm Runfile Installer Package mismatch:\e[0m"
            echo -e "\e[31mInstall Build: ${DISTRO_NAME} ${version_build}\e[0m"
            echo -e "\e[31mInstall OS   : ${DISTRO_NAME} ${version_install}\e[0m"
            echo -e "\e[31m++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\e[0m"
            echo Exiting installation.
            exit 1
        fi
    fi
}

####### Main script ###############################################################

SUDO=$([[ $(id -u) -ne 0 ]] && echo "sudo" ||:)

os_release

# parse args
while (($#))
do
    case "$1" in
    version)
        print_version
        exit 0
        ;;
    *)
        ARGS+="$1 "
        shift
        ;;
    esac
done

if [ -z "$ARGS" ]; then
    validate_version

    echo Using ROCm Installer UI.
    ./rocm_ui
else
    echo Using ROCm Installer script with args: "$ARGS"
    ./rocm-installer.sh runfile $ARGS
fi

