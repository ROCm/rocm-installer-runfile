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

BUILD_EXTRACT="yes"
BUILD_INSTALLER="yes"
BUILD_UI="yes"

BUILD_DIR=build
BUILD_DIR_UI=build-UI

VERSION_FILE="./VERSION"

INSTALLER_VERSION=
ROCM_VER=
BUILD_NUMBER="${BUILD_NUMBER:-}"
LKG_BUILD_NUM="${LKG_BUILD_NUM:-}"
BUILD_INSTALLER_NAME=

AMDGPU_DKMS_FILE="rocm-installer/component-amdgpu/amdgpu-dkms-ver.txt"
AMDGPU_DKMS_BUILD_NUM=

EXTRACT_DIR="../rocm-installer"

MAKESELF_OPT="--notemp --threads $(nproc)"
MAKESELF_OPT_CLEANUP=
MAKESELF_OPT_HEADER="--header ./rocm-makeself-header.sh --help-header ./rocm-installer/VERSION"
MAKESELF_OPT_TAR="--tar-format gnu"


###### Functions ###############################################################

usage() {
cat <<END_USAGE
Usage: $PROG [options]

[options}:
    help      = Display this help information.
    noextract = Disable package extraction.
    norunfile = Disable makeself build of installer runfile.
    nogui     = Disable GUI building.
END_USAGE
}

os_release() {
    if [[ -r  /etc/os-release ]]; then
        . /etc/os-release
        
        DISTRO_NAME=$ID
        DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
        
        case "$ID" in
        ubuntu|debian)
            BUILD_DISTRO_TYPE=deb
            BUILD_OS=$DISTRO_VER
            ;;
        rhel|ol)
            BUILD_DISTRO_TYPE=el
                        	    
            if [[ $DISTRO_VER == 8* ]]; then
                echo Disable makeself tar options for EL8.
                MAKESELF_OPT_HEADER="--header ./rocm-makeself-header-pre.sh --help-header ./rocm-installer/VERSION"
                MAKESELF_OPT_TAR=
                BUILD_OS=el8
            else
                BUILD_OS=el9
            fi	    
            ;;
        sles)
            BUILD_DISTRO_TYPE=sle
            BUILD_OS=sles${DISTRO_VER//./}
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
        
    echo "Build running on $DISTRO_NAME $DISTRO_VER."
}

get_version() {
    i=0
    
    while IFS= read -r line; do
        case $i in
            0) INSTALLER_VERSION="$line" ;;
            1) ROCM_VER="$line" ;;
        esac
        
        i=$((i+1))
    done < "$VERSION_FILE"
}

setup_version() {
    echo -------------------------------------------------------------
    echo Setting version and build info...
    
    if [[ -z $BUILD_NUMBER ]] || [[ -z $LKG_BUILD_NUM ]]; then
        BUILD_INFO=local
    else
        BUILD_INFO=$BUILD_NUMBER-$LKG_BUILD_NUM
    fi
    
    get_version
    
     # Split the version number into major, minor, and patch components
    IFS='.' read -r major minor patch <<< "$ROCM_VER"

    # Convert the version number to x0y0z0 format
    ROCM_VER_STRING=$(printf "%d%02d%02d" "$major" "$minor" "$patch")
    
    # set the runfile installer name
    BUILD_INSTALLER_NAME="rocm-installer_$INSTALLER_VERSION.$ROCM_VER_STRING-$BUILD_INFO~$BUILD_OS"
    
    # get the amdgpu-dkms build/version info
    if [ -f "$AMDGPU_DKMS_FILE" ]; then
        AMDGPU_DKMS_BUILD_NUM=$(cat "$AMDGPU_DKMS_FILE")
    fi
    
    echo "INSTALLER_VERSION     = $INSTALLER_VERSION"
    echo "ROCM_VER              = $ROCM_VER"
    echo "ROCM_VER_STRING       = $ROCM_VER_STRING"
    echo "BUILD_NUMBER          = $BUILD_NUMBER"
    echo "LKG_BUILD_NUM         = $LKG_BUILD_NUM"
    echo "AMDGPU_DKMS_BUILD_NUM = $AMDGPU_DKMS_BUILD_NUM"
    echo "BUILD_INSTALLER_NAME  = $BUILD_INSTALLER_NAME"
    
    # Update the version file
    echo "$INSTALLER_VERSION" > "$VERSION_FILE"
    echo "$ROCM_VER" >> "$VERSION_FILE"
    echo "$DISTRO_VER" >> "$VERSION_FILE"
    echo "$LKG_BUILD_NUM" >> "$VERSION_FILE"
    echo "$AMDGPU_DKMS_BUILD_NUM" >> "$VERSION_FILE"
    echo "$BUILD_INSTALLER_NAME" >> "$VERSION_FILE"
}

install_tools_deb() {
    echo Installing DEB tools...
    
    # Install tools for UI
    $SUDO apt-get install -y cmake
    $SUDO apt-get install -y libncurses5-dev
    
    # Install for ar
    $SUDO apt-get install -y binutils
    
    # Install makself for .run creation
    $SUDO apt-get install -y makeself
    
    # Check the version of makself and enable cleanup script support if >= 2.4.2
    makeself_version_min=2.4.2
    makeself_version=$(makeself --version)
    makeself_version=${makeself_version#Makeself version }

    if [[ "$(printf '%s\n' "$makeself_version_min" "$makeself_version" | sort -V | head -n1)" = "$makeself_version_min" ]]; then
        MAKESELF_OPT_CLEANUP+="--cleanup ./cleanup-install.sh"
        echo Enabling cleanup script support.
    fi
    
    echo Installing DEB tools...Complete
}

install_tools_el(){
    echo Installing EL tools...
    
    # Install tools for UI
    $SUDO dnf install -y cmake
    $SUDO dnf install -y gcc gcc-c++
    $SUDO dnf install -y ncurses-devel
    
    # Install makself for .run creation
    $SUDO dnf install -y makeself
    
    # Check the version of makself and enable cleanup script support if >= 2.4.2
    makeself_version_min=2.4.2
    makeself_version=$(makeself --version)
    makeself_version=${makeself_version#Makeself version }

    if [[ "$(printf '%s\n' "$makeself_version_min" "$makeself_version" | sort -V | head -n1)" = "$makeself_version_min" ]]; then
        MAKESELF_OPT_CLEANUP+="--cleanup ./cleanup-install.sh"
        echo Enabling cleanup script support.
    fi
    
    echo Installing EL tools...Complete
}

install_tools_sle(){
    echo Installing SLE tools...
    
    # Install tools for UI
    $SUDO zypper install -y cmake
    $SUDO zypper install -y gcc gcc-c++
    $SUDO zypper install -y ncurses-devel
    
    # Install makself for .run creation
    $SUDO zypper install -y makeself
    
    # Check the version of makself and enable cleanup script support if >= 2.4.2
    makeself_version_min=2.4.2
    makeself_version=$(makeself --version)
    makeself_version=${makeself_version#Makeself version }

    if [[ "$(printf '%s\n' "$makeself_version_min" "$makeself_version" | sort -V | head -n1)" = "$makeself_version_min" ]]; then
        MAKESELF_OPT_CLEANUP+="--cleanup ./cleanup-install.sh"
        echo Enabling cleanup script support.
    fi
    
    echo Installing SLE tools...Complete
}

install_tools() {
    echo -------------------------------------------------------------
    echo Installing tools...
    
    if [ $BUILD_DISTRO_TYPE == "deb" ]; then
        install_tools_deb
    elif [ $BUILD_DISTRO_TYPE == "el" ]; then
        install_tools_el
    elif [ $BUILD_DISTRO_TYPE == "sle" ]; then
        install_tools_sle
    else
        echo Invalid Distro Type: $BUILD_DISTRO_TYPE
        exit 1
    fi
    
    echo Installing tools...Complete
}

extract_packages() {
    echo -------------------------------------------------------------
    echo Running Package Extractor...
    
    if [ $BUILD_EXTRACT == "yes" ]; then
        echo Extracting packages...
        
        pushd package-extractor
            if [ $BUILD_DISTRO_TYPE == "deb" ]; then
                # extract the rocm packages - debian
                ./package-extractor-debs.sh rocm ext-rocm="../rocm-installer"
                if [[ $? -ne 0 ]]; then
                    echo -e "\e[31mFailed extraction of ROCm packages.\e[0m"
                    exit 1
                fi
                
                # extract the amdgpu packages - debian
                ./package-extractor-debs.sh amdgpu ext-amdgpu="$EXTRACT_DIR"
                if [[ $? -ne 0 ]]; then
                    echo -e "\e[31mFailed extraction of AMDGPU packages.\e[0m"
                    exit 1
                fi
            else
                # extract the rocm packages - rpm
                ./package-extractor-rpms.sh rocm ext-rocm="../rocm-installer"
                if [[ $? -ne 0 ]]; then
                    echo -e "\e[31mFailed extraction of ROCm packages.\e[0m"
                    exit 1
                fi
                
                # extract the amdgpu packages - rpm
                ./package-extractor-rpms.sh amdgpu ext-amdgpu="$EXTRACT_DIR"
                if [[ $? -ne 0 ]]; then
                    echo -e "\e[31mFailed extraction of AMDGPU packages.\e[0m"
                    exit 1
                fi
            fi
        popd
    else
        echo Extract Packages disabled.
    fi

    echo Running Package Extractor...Complete
}

build_UI() {
    echo -------------------------------------------------------------
    echo Building Installer UI...
    
    if [ $BUILD_UI == "yes" ]; then
        if [ -d $BUILD_DIR_UI ]; then
            echo Removing UI Build directory.
            $SUDO rm -r $BUILD_DIR_UI
        fi
    
        echo Creating $BUILD_DIR_UI directory.
        mkdir $BUILD_DIR_UI
    
        pushd $BUILD_DIR_UI
            cmake -DINSTALLER_NAME="$BUILD_INSTALLER_NAME" -DAMDGPU_DKMS="$AMDGPU_DKMS_BUILD_NUM" ..
            make
            if [[ $? -ne 0 ]]; then
                echo -e "\e[31mFailed GUI build.\e[0m"
                exit 1
            fi
        popd
    else
        echo UI build disabled.
    fi
    
    echo Building Installer UI...Complete
}

build_installer() {
    echo -------------------------------------------------------------
    echo Building Installer Package...

    if [ ! -d $BUILD_DIR ]; then
        echo Creating $BUILD_DIR directory.
        mkdir $BUILD_DIR
    fi
    
    if [ $BUILD_INSTALLER == "yes" ]; then
        echo Building installer runfile...
        
        echo "MAKESELF_OPT_HEADER  = $MAKESELF_OPT_HEADER"
        echo "MAKESELF_OPT         = $MAKESELF_OPT"
        echo "MAKESELF_OPT_CLEANUP = $MAKESELF_OPT_CLEANUP"
        echo "MAKESELF_OPT_TAR     = $MAKESELF_OPT_TAR"
        
        makeself $MAKESELF_OPT_HEADER $MAKESELF_OPT $MAKESELF_OPT_CLEANUP $MAKESELF_OPT_TAR ./rocm-installer "./$BUILD_DIR/$BUILD_INSTALLER_NAME.run" "ROCm Runfile Installer" ./install-init.sh
        if [[ $? -ne 0 ]]; then
            echo -e "\e[31mFailed makeself build.\e[0m"
            exit 1
        fi
            
        echo Building installer runfile...Complete
    else
        echo Runfile build disabled.
    fi
    
    echo Building Installer Package...Complete
}


####### Main script ###############################################################

echo ==============================
echo ROCM RUNFILE INSTALLER BUILDER
echo ==============================

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
    noextract)
        echo "Disabling package extraction."
        BUILD_EXTRACT="no"
        shift
        ;;    
    norunfile)
        echo "Disabling runfile build."
        BUILD_INSTALLER="no"
        shift
        ;;
    nogui)
        echo "Disabling UI build."
        BUILD_UI="no"
        shift
        ;;
    *)
        shift
        ;;
    esac
done

# Install any required tools for the build
install_tools

# Extract all ROCm/AMDGPU packages
extract_packages

# Setup version/build info
setup_version

# Build the UI
build_UI

# Build the installer
build_installer

