#!/bin/bash

# #############################################################################
# Copyright (C) 2024-2026 Advanced Micro Devices, Inc. All rights reserved.
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

# AMDGPU Installer Script
# This script handles AMDGPU driver installation and uninstallation

# Installer directory (where this script is located)
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logs
AMDGPU_INSTALLER_LOG_DIR="$PWD/logs"
AMDGPU_INSTALLER_CURRENT_LOG="$AMDGPU_INSTALLER_LOG_DIR/install_amdgpu_$(date +%s).log"

# Set AMDGPU-specific paths
EXTRACT_AMDGPU_DIR="$PWD/component-amdgpu"
TARGET_AMDGPU_DIR="/"
COMPO_AMDGPU_FILE=""

# Rsync options for AMDGPU installation
RSYNC_OPTS_AMDGPU="-a --keep-dirlinks --no-perms --no-owner --no-group --omit-dir-times "

# Dependencies required by installer
INSTALLER_DEPS=(rsync findutils)

# Version information
AMDGPU_DKMS_BUILD_NUM=""  # Will be set by get_version()

# Initialize script-specific variables
PROMPT_USER=0
VERBOSE=0
AMDGPU_START=0
DEPS_ARG=""

# Uninstall data
INSTALLED_AMDGPU_DKMS_BUILD_NUM=0
FORCE_UNINSTALL_AMDGPU=0

# On-demand extraction tracking
AMDGPU_EXTRACTED=0  # Track if AMDGPU component has been extracted


###### Functions ###############################################################

usage() {
cat <<END_USAGE
Usage: bash $PROG [options]

[options]:
    help    = Displays this help information.

    Dependencies:
    -------------
        deps=<arg>

        <arg>
            list         = Lists required dependencies for AMDGPU install.
            validate     = Validates installed and not installed required dependencies.
            install-only = Install dependencies only (no AMDGPU driver).
            install      = Install dependencies and AMDGPU driver.

    Install:
    --------
        install = Install AMDGPU driver.
        start   = Start amdgpu driver after installation (modprobe amdgpu).

    Uninstall:
    ----------
        uninstall = Uninstall AMDGPU driver.

    Information/Debug:
    ------------------
        prompt    = Run the installer with user prompts.
        verbose   = Run installer with verbose logging.

+++++++++++++++++++++++++++++++
Usage examples:
+++++++++++++++++++++++++++++++

# AMDGPU installation (no Dependency install)

    bash $PROG install

# AMDGPU + Dependency installation

    bash $PROG install deps=install

# AMDGPU + Dependency installation with verbose output

    bash $PROG install deps=install verbose

# AMDGPU installation with user prompts

    bash $PROG install prompt

# List dependencies only

    bash $PROG install deps=list

# Install dependencies only (no AMDGPU driver)

    bash $PROG install deps=install-only

# AMDGPU uninstall

    bash $PROG uninstall

END_USAGE
}

os_release() {
    if [[ -r  /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release

        DISTRO_NAME=$ID

        case "$ID" in
        ubuntu|debian)
            DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')

            INSTALL_SCRIPTLET_ARG="configure"
            UNINSTALL_SCRIPTLET_ARG="remove"
            PKG_INSTALLED_CMD="apt list --installed"
            UPDATE_INITRAMFS_CMD="update-initramfs -u -k all"
            ;;
        rhel|centos|ol|rocky|almalinux|amzn|tencentos|alinux|anolis)
            DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')

            if [[ $DISTRO_VER != 9* ]] && [[ "$DISTRO_NAME" = "rocky" ]]; then
                echo "$DISTRO_NAME $DISTRO_VER is not a supported OS"
                exit 1
            fi

            if [[ $DISTRO_VER != 9* ]] && [[ "$DISTRO_NAME" = "centos" ]]; then
                echo "$DISTRO_NAME $DISTRO_VER is not a supported OS"
                exit 1
            fi

            if [[ $DISTRO_VER != 8* ]] && [[ "$DISTRO_NAME" = "almalinux" ]]; then
                echo "$DISTRO_NAME $DISTRO_VER is not a supported OS"
                exit 1
            fi

            INSTALL_SCRIPTLET_ARG="1"
            UNINSTALL_SCRIPTLET_ARG="0"
            PKG_INSTALLED_CMD="rpm -qa"
            UPDATE_INITRAMFS_CMD="dracut -f --regenerate-all"
            ;;
        sles)
            if rpm -qa | grep -q "awk"; then
                DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
            else
                DISTRO_VER=$(grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
            fi

            INSTALL_SCRIPTLET_ARG="1"
            UNINSTALL_SCRIPTLET_ARG="0"
            PKG_INSTALLED_CMD="rpm -qa"
            UPDATE_INITRAMFS_CMD="dracut -f --regenerate-all"
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

    # Extract major version from DISTRO_VER (e.g., 22.04 -> 22, 9.3 -> 9, 15.6 -> 15)
    DISTRO_MAJOR_VER=${DISTRO_VER%%.*}

    echo "Installing for $DISTRO_NAME $DISTRO_VER."
}

get_version() {
    local i=0
    local version_file=""

    # Find VERSION file - check both current directory and parent directory
    if [ -f "./VERSION" ]; then
        version_file="./VERSION"
    elif [ -f "../VERSION" ]; then
        version_file="../VERSION"
    fi

    # Read VERSION file (written by package-extractor and build-installer)
    if [ -n "$version_file" ]; then
        while IFS= read -r line; do
            case $i in
                5) AMDGPU_DKMS_BUILD_NUM="$line" ;;
            esac
            i=$((i+1))
        done < "$version_file"
    fi

    # If AMDGPU build number wasn't in VERSION file (pre-build state),
    # try reading from component-amdgpu directory
    if [[ -z "$AMDGPU_DKMS_BUILD_NUM" || "$AMDGPU_DKMS_BUILD_NUM" == "" ]]; then
        local amdgpu_ver_file="./component-amdgpu/amdgpu-dkms-ver.txt"
        if [ -f "$amdgpu_ver_file" ]; then
            AMDGPU_DKMS_BUILD_NUM=$(tr -d '[:space:]' < "$amdgpu_ver_file")
        else
            AMDGPU_DKMS_BUILD_NUM="N/A"
        fi
    fi
    
    echo "AMDGPU Build: $AMDGPU_DKMS_BUILD_NUM"
}

print_err() {
    local msg=$1
    echo -e "\e[31m++++++++++++++++++++++++++++++++++++\e[0m"
    echo -e "\e[31mError: $msg\e[0m"
    echo -e "\e[31m++++++++++++++++++++++++++++++++++++\e[0m"
}

print_warning() {
    local msg=$1
    echo -e "\e[93m++++++++++++++++++++++++++++++++++++\e[0m"
    echo -e "\e[93mWarning: $msg\e[0m"
    echo -e "\e[93m++++++++++++++++++++++++++++++++++++\e[0m"
}

print_str() {
    local str=$1
    local clr=$2

    if [[ $VERBOSE == 1 ]]; then
        if [[ $clr == 1 ]]; then
            echo -e "\e[93m$str\e[0m"   # yellow
        elif [[ $clr == 2 ]]; then
            echo -e "\e[32m$str\e[0m"   # green
        elif [[ $clr == 3 ]]; then
            echo -e "\e[31m$str\e[0m"   # red
        elif [[ $clr == 4 ]]; then
            echo -e "\e[35m$str\e[0m"   # purple
        elif [[ $clr == 5 ]]; then
            echo -e "\e[36m$str\e[0m"   # cyan
        else
            echo "$str"                 # white
        fi
    fi
}

prompt_user() {
    if [[ $PROMPT_USER == 1 ]]; then
        read -rp "$1" option
    else
        option=y
    fi
}

prereq_installer_check() {
    local not_install=""

    # Check if the require packages are installed on the system for installer to function
    for pkg in "${INSTALLER_DEPS[@]}"; do
        # Check if this a package install of amdgpu
        if ! $PKG_INSTALLED_CMD 2>&1 | grep "$pkg" > /dev/null 2>&1; then
            echo "Package $pkg not installed."
            not_install+="$pkg "
        else
            echo "$pkg" is installed
        fi
    done

    if [[ -n $not_install ]]; then
        print_err "AMDGPU installer requires installation of the following packages: $not_install"
        exit 1
    fi
}

read_components() {
    echo --------------------------------
    echo "Read Component Configuration: $COMPO_FILE ..."

    if [ ! -f "$COMPO_FILE" ]; then
        print_err "Component config file $COMPO_FILE does not exist."
        exit 1
    fi

    # Read all AMDGPU components
    while IFS= read -r compo; do
        COMPONENTS="$COMPONENTS $compo"
    done < "$COMPO_FILE"
    echo "COMPONENTS = $COMPONENTS"

    echo "Read Component Configuration...Complete."
}

install_postinst_scriptlet() {
    local component=$1
    local extract_dir=${2:-"$EXTRACT_DIR"}
    # For AMDGPU: scriptlets are at component-amdgpu/scriptlets/{distro}/{package}
    local postinst_scriptlet="$extract_dir/scriptlets/$AMDGPU_DISTRO_TAG/$component/postinst"

    # execute post install with arg "configure" or "1"
    if [[ -s "$postinst_scriptlet" ]]; then
        echo --------------------------------
        echo -e "\e[92mExecuting post install script for $component...\e[0m"

        if [[ $VERBOSE == 1 ]]; then
            cat "$postinst_scriptlet"
        fi

        $SUDO_OPTS "$postinst_scriptlet" "$INSTALL_SCRIPTLET_ARG"

        echo -e "\e[92mComplete: $?\e[0m"
    fi
}

patch_scriptlet_version() {
    local scriptlet_file="$1"
    local search_string="$2"
    local replace_string="$3"

    if [[ $VERBOSE == 1 ]]; then
        echo "Replacing '$search_string' with '$replace_string'"
        echo "Processing $scriptlet_file"
    fi

    # Create a backup of the original file
    cp "$scriptlet_file" "$scriptlet_file.bak"

    # Perform the replacement and check if successful
    if sed -i "s/$search_string/$replace_string/g" "$scriptlet_file"; then
        echo "Successfully updated $scriptlet_file"
    else
        echo "Error processing $scriptlet_file"
        # Restore backup if there was an error
        mv "$scriptlet_file.bak" "$scriptlet_file"
    fi

}

uninstall_postrm_scriptlet() {
    local component=$1
    local extract_dir=${2:-"$EXTRACT_DIR"}
    # For AMDGPU: scriptlets are at component-amdgpu/scriptlets/{distro}/{package}
    local postrm_scriptlet="$extract_dir/scriptlets/$AMDGPU_DISTRO_TAG/$component/postrm"

    # execute post uninstall with arg "remove" or "0"
    if [[ -s "$postrm_scriptlet" ]]; then
        echo --------------------------------
        echo -e "\e[92mExecuting postrm script for $component...\e[0m"

        if [[ $VERBOSE == 1 ]]; then
            cat "$postrm_scriptlet"
        fi

        $SUDO_OPTS "$postrm_scriptlet" "$UNINSTALL_SCRIPTLET_ARG"

        echo -e "\e[92mComplete: $?\e[0m"
    fi
}

###### AMDGPU-Specific Functions ###############################################

get_amdgpu_distro_tag() {
    # Map the current distro to the AMDGPU component directory name
    local distro_tag=""

    case "$DISTRO_NAME" in
        ubuntu)
            # Ubuntu: 24.04 -> ub24, 22.04 -> ub22
            distro_tag="ub${DISTRO_MAJOR_VER}"
            ;;
        debian)
            # Debian: 12 -> ub22, 13 -> ub24
            case "$DISTRO_MAJOR_VER" in
                12)
                    distro_tag="ub22"
                    ;;
                13)
                    distro_tag="ub24"
                    ;;
                *)
                    distro_tag="ub${DISTRO_MAJOR_VER}"
                    ;;
            esac
            ;;
        rhel|centos|ol|rocky|almalinux|anolis)
            # RHEL-like distros: RHEL, CentOS Stream, Oracle Linux, Rocky, AlmaLinux, Anolis
            # Map directly: 9 -> el9, 8 -> el8
            distro_tag="el${DISTRO_MAJOR_VER}"
            ;;
        tencentos|alinux)
            # TencentOS and Alibaba Cloud Linux: 3 -> el8, 4 -> el9
            case "$DISTRO_MAJOR_VER" in
                3)
                    distro_tag="el8"
                    ;;
                4)
                    distro_tag="el9"
                    ;;
                *)
                    distro_tag="el${DISTRO_MAJOR_VER}"
                    ;;
            esac
            ;;
        amzn)
            # Amazon Linux: 2023 -> amzn23
            # Strip leading "20" from version (2023 -> 23)
            local amzn_short_ver="${DISTRO_VER#20}"
            distro_tag="amzn${amzn_short_ver}"
            ;;
        sles)
            # SLES: 15.x -> sle15, 16.x -> sle16
            distro_tag="sle${DISTRO_MAJOR_VER}"
            ;;
        *)
            echo "Unknown distro: $DISTRO_NAME"
            return 1
            ;;
    esac

    echo "$distro_tag"
    return 0
}

extract_amdgpu_if_needed() {
    # Extract AMDGPU content archive on-demand
    # Only extracts content; deps and scriptlets are already available (uncompressed)

    if [[ $AMDGPU_EXTRACTED -eq 1 ]]; then
        echo "AMDGPU content already extracted, skipping"
        return 0
    fi

    local archive="$INSTALLER_DIR/component-amdgpu/content-amdgpu.tar.xz"
    local extract_dir="$INSTALLER_DIR/component-amdgpu"

    if [[ ! -f "$archive" ]]; then
        echo -e "\e[31mERROR: AMDGPU content archive not found: $archive\e[0m"
        exit 1
    fi

    echo "Extracting AMDGPU content..."

    if ! "$INSTALLER_DIR/component-extractor.sh" "$archive" "$extract_dir" "$INSTALLER_DIR"; then
        echo -e "\e[31mERROR: Failed to extract AMDGPU content\e[0m"
        exit 1
    fi

    AMDGPU_EXTRACTED=1
    echo "AMDGPU content extracted successfully"
}

setup_amdgpu_paths() {
    # Initialize AMDGPU paths based on distro
    if ! AMDGPU_DISTRO_TAG=$(get_amdgpu_distro_tag); then
        print_err "Failed to determine AMDGPU distro tag"
        exit 1
    fi

    # AMDGPU config file is in deps/{distro}/
    COMPO_AMDGPU_FILE="$EXTRACT_AMDGPU_DIR/deps/$AMDGPU_DISTRO_TAG/amdgpu-packages.config"

    echo "AMDGPU_DISTRO_TAG = $AMDGPU_DISTRO_TAG"
}

uninstall_prerm_scriptlet_amdgpu() {
    local component=$1
    local prerm_scriptlet="$EXTRACT_AMDGPU_DIR/scriptlets/$AMDGPU_DISTRO_TAG/$component/prerm"

    # execute pre-install with arg "remove" or "0"
    if [[ -s "$prerm_scriptlet" ]]; then
        echo --------------------------------
        echo -e "\e[92mExecuting prerm script for $component...\e[0m"

        if [[ $FORCE_UNINSTALL_AMDGPU == 1 ]]; then
            echo "Patching prerm scriptlet $prerm_scriptlet"
            patch_scriptlet_version "$prerm_scriptlet" "$AMDGPU_DKMS_BUILD_NUM" "$INSTALLED_AMDGPU_DKMS_BUILD_NUM"
        fi

        if [[ $VERBOSE == 1 ]]; then
            cat "$prerm_scriptlet"
        fi

        $SUDO_OPTS "$prerm_scriptlet" "$UNINSTALL_SCRIPTLET_ARG"

        echo -e "\e[92mComplete: $?\e[0m"

        if [[ $FORCE_UNINSTALL_AMDGPU == 1 ]]; then
            echo "Restoring prerm scriptlet $prerm_scriptlet"
            mv "$prerm_scriptlet.bak" "$prerm_scriptlet"
        fi
    fi
}

install_amdgpu_component() {
    echo --------------------------------

    local component=$1
    local content_dir="$EXTRACT_AMDGPU_DIR/content/$AMDGPU_DISTRO_TAG/$component"
    local script_dir="$EXTRACT_AMDGPU_DIR/scriptlets/$AMDGPU_DISTRO_TAG/$component"

    echo Copying content component: "$component"...

    # Copy the component content/data to the target location
    # shellcheck disable=SC2086
    if ! $SUDO rsync $RSYNC_OPTS_AMDGPU "$content_dir/"* "$TARGET_DIR"; then
        print_err "rsync error."
        exit 1
    fi

    # Workaround for amdgpu-dkms: amdgpu_firmware may be called via amdgpu-dkms.amdgpu_firmware
    if [[ $component == "amdgpu-dkms" ]] && [ -f "$script_dir/amdgpu_firmware" ]; then
        $SUDO cp -p "$script_dir/amdgpu_firmware" "$script_dir/amdgpu-dkms.amdgpu_firmware"
    fi

    echo Copying content component: "$component"...Complete.

    # Process any scriptlets
    for scriptlet in "$script_dir"/*; do
        if [[ -f $scriptlet ]]; then
            print_str "Detected: $scriptlet."
        fi
    done

    # Execute any postinst scriptlets
    install_postinst_scriptlet "$component"
}

query_prev_driver_version() {
    # Get DKMS status output
    # SUSE require sudo for dkms
    dkms_output=$($SUDO dkms status)

    while read -r line; do
        # Extract driver name and version (format is "module, version, kernel/arch/...")
        if [[ $line =~ ^([^\/]+)\/([^,]+),\ ([^,]+),\ (.+)$ ]]; then
            driver=${BASH_REMATCH[1]}
            if [ "$driver" = "amdgpu" ]; then
                INSTALLED_AMDGPU_DKMS_BUILD_NUM="${BASH_REMATCH[2]}"
                kernel_version=${BASH_REMATCH[3]}
                if [[ $VERBOSE == 1 ]]; then
                    echo "Driver: $driver"
                    echo "Version: $INSTALLED_AMDGPU_DKMS_BUILD_NUM"
                    echo "Kernel Version: $kernel_version"
                fi
            fi
        fi
    done < <(echo "$dkms_output")
}

get_amdgpu_version_from_scriptlet() {
    # Get the full AMDGPU version (with distro suffix) from the postinst scriptlet
    # This ensures we use the correct version for the current distro
    # Different distros store the version differently:
    #   - Ubuntu/Debian: CVERSION=6.18.4-2286447.24.04
    #   - EL (RHEL/Rocky): $postinst amdgpu 6.18.4-2286447.el10
    #   - SLES: $postinst amdgpu 6.18.4-2286447

    local scriptlet_file="$EXTRACT_AMDGPU_DIR/scriptlets/$AMDGPU_DISTRO_TAG/amdgpu-dkms/postinst"

    if [[ -f $scriptlet_file ]]; then
        # Try Ubuntu/Debian pattern: CVERSION=...
        local version
        version=$(grep "^CVERSION=" "$scriptlet_file" | cut -d'=' -f2)

        if [[ -z "$version" ]]; then
            # Try RPM pattern: $postinst amdgpu <version>
            # shellcheck disable=SC2016  # Single quotes intentional - searching for literal '$postinst'
            version=$(grep '\$postinst amdgpu' "$scriptlet_file" | awk '{print $3}')
        fi

        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi

    # Fallback: return empty if scriptlet not found or version not extracted
    return 1
}

preinstall_amdgpu() {
    echo --------------------------------
    echo Preinstall amdgpu...

    # Check for installer prerequisites
    prereq_installer_check

    # Check for a previous amdgpu install via the package manager
    if $PKG_INSTALLED_CMD 2>&1 | grep "amdgpu-dkms"; then
        print_err "Package installation of amdgpu"
        echo "Please uninstall previous version of amdgpu using the package manager."
        exit 1
    else
        echo "No package-based amdgpu install found."
    fi

    # Check if deps are installed ie. dkms
    if $PKG_INSTALLED_CMD 2>&1 | grep "dkms" > /dev/null 2>&1; then
        echo "dkms package installed."

        # Workaround for DKMS path mismatch on some distros (e.g., Alibaba Cloud Linux 4)
        # Some distros install dkms to /usr/bin/dkms instead of /usr/sbin/dkms
        # but amdgpu-dkms postinst scripts expect it at /usr/sbin/dkms
        if [ -f /usr/bin/dkms ] && [ ! -f /usr/sbin/dkms ]; then
            echo "DKMS found at /usr/bin/dkms but not at /usr/sbin/dkms"
            echo "Creating symlink /usr/sbin/dkms -> /usr/bin/dkms for compatibility..."
            $SUDO ln -s /usr/bin/dkms /usr/sbin/dkms
            echo "DKMS symlink created successfully."
        fi

        # Check if driver already present in dkms
        query_prev_driver_version

        if [ ! "$INSTALLED_AMDGPU_DKMS_BUILD_NUM" = 0 ] ; then
            print_warning "The amdgpu driver installed, version $INSTALLED_AMDGPU_DKMS_BUILD_NUM"
            echo "Consider uninstalling previous versions of amdgpu using the Runfile installer."
            echo "Usage: bash $PROG uninstall-amdgpu"
        fi
    else
        print_err "dkms package not installed."
        exit 1
    fi

    echo Preinstall amdgpu...Complete.
    echo --------------------------------
}

install_amdgpu() {
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo -e "\e[96mINSTALL AMDGPU\e[0m"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="

    # Extract AMDGPU component if needed
    extract_amdgpu_if_needed

    # Set up AMDGPU paths based on distro
    setup_amdgpu_paths

    # Check if amdgpu is installable
    preinstall_amdgpu

    echo "EXTRACT_AMDGPU_DIR = $EXTRACT_AMDGPU_DIR"
    echo "TARGET_AMDGPU_DIR  = $TARGET_AMDGPU_DIR"

    EXTRACT_DIR="$EXTRACT_AMDGPU_DIR"
    TARGET_DIR="$TARGET_AMDGPU_DIR"
    COMPO_FILE="$COMPO_AMDGPU_FILE"

    # Reset COMPONENTS
    COMPONENTS=

    read_components

    # Install each component in the component list for amdgpu
    for compo in $COMPONENTS; do
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        echo -e "\e[32mInstalling $compo\e[0m"
        install_amdgpu_component "$compo"
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    done

    # Start amdgpu after install if required
    if [[ $AMDGPU_START == 1 ]]; then
        echo Starting amdgpu driver...
        $SUDO modprobe amdgpu
        echo Starting amdgpu driver...Complete.
    fi
}

find_and_delete() {
    local file_path=$1
    local type=$2
    local force_remove_dir=0

    find "$file_path" -type "$type" -print0 | while IFS= read -r -d '' filename; do
        remove_filename="${filename#"$path_to_files"}"

        if [[ $FORCE_UNINSTALL_AMDGPU == 1 ]]; then
            if [[ "$remove_filename" == *"$AMDGPU_DKMS_BUILD_NUM"* ]]; then
                force_remove_filename=${remove_filename//$AMDGPU_DKMS_BUILD_NUM/$INSTALLED_AMDGPU_DKMS_BUILD_NUM}
                # Workaround to delete all folders in /usr/src/amdgpu because of diffrent versions numbers in directory name
                # delete all files and subfolders
                force_remove_dir=$(dirname "$force_remove_filename")
                if [[ $VERBOSE == 1 ]]; then
                    echo "remove: $force_remove_dir"
                fi
                $SUDO rm -rf "$force_remove_dir" 2>/dev/null
            fi
            if [[ "$remove_filename" == *"/lib/firmware/updates"* ]]; then
                force_remove_dir=$(dirname "$remove_filename")
                remove_filename="$force_remove_dir/*"
                if [[ $VERBOSE == 1 ]]; then
                    echo "remove: $remove_filename"
                fi
                # Here delete only files, folder deleted as in normal uninstall
                $SUDO rm -f "$remove_filename" 2>/dev/null
            fi
        fi

        if [ -e "$remove_filename" ] || [ -L "$remove_filename" ]; then
            if [[ $VERBOSE == 1 ]]; then
                echo "remove: $remove_filename"
            fi
            # workaround for files with spaces, ex /usr/src/amdgpu-6.10.5-2084815.24.04/amd/dkms/m4/drm_vblank_crtc_config .m4
            $SUDO rm "$remove_filename" 2>/dev/null
        fi
    done
}

delete_empty_dirs() {
    local files_dir=$1

    # Recursively check all subdirs under files starting from the deepest level

    find "$files_dir" -depth -type d | while read -r subdir_files_dir; do
        # Remove the base path of installation to get the relative path
        relativePath="${subdir_files_dir#"$files_dir"}"

        # Construct the corresponding path in installed dir
        subdir_installed="$relativePath"

        # Check if the subdir exists in installation and is empty
        if [ -d "$subdir_installed" ] && [ -z "$(ls -A "$subdir_installed")" ]; then
            if [[ $VERBOSE == 1 ]]; then
                echo "Deleting empty directory: $subdir_installed"
            fi
            $SUDO rmdir "$subdir_installed" 2>/dev/null
        fi
    done
}

uninstall_amdgpu() {
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo -e "\e[95mUNINSTALL amdgpu\e[0m"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="

    # Set up AMDGPU paths based on distro
    setup_amdgpu_paths

    echo "EXTRACT_AMDGPU_DIR = $EXTRACT_AMDGPU_DIR"
    echo "TARGET_AMDGPU_DIR  = $TARGET_AMDGPU_DIR"

    EXTRACT_DIR="$EXTRACT_AMDGPU_DIR"
    TARGET_DIR="$TARGET_AMDGPU_DIR"

    query_prev_driver_version

    if [ "$INSTALLED_AMDGPU_DKMS_BUILD_NUM" == 0 ] ; then
        print_err "amdgpu driver not installed."
        echo "Please install amdgpu using the Runfile installer."
        echo "Usage: bash $PROG amdgpu"
        exit 1
    fi

    # Get the full AMDGPU version (with distro suffix) from the scriptlet
    # This overrides the version from VERSION file which has suffix stripped
    local scriptlet_version
    scriptlet_version=$(get_amdgpu_version_from_scriptlet)
    if [[ -n "$scriptlet_version" ]]; then
        AMDGPU_DKMS_BUILD_NUM="$scriptlet_version"
        echo "Using AMDGPU version from scriptlet: $AMDGPU_DKMS_BUILD_NUM"
    fi

    echo "Installed amdgpu version $INSTALLED_AMDGPU_DKMS_BUILD_NUM"
    echo "Runfile amdgpu version $AMDGPU_DKMS_BUILD_NUM"

    if [ ! "$INSTALLED_AMDGPU_DKMS_BUILD_NUM" == "$AMDGPU_DKMS_BUILD_NUM" ] ; then
        print_err "amdgpu driver installed version does not match runfile version."
        prompt_user "Force uninstall (y/n): "
        if [[ $option == "Y" || $option == "y" ]]; then
            FORCE_UNINSTALL_AMDGPU=1;
        fi
        if [[ $option == "N" || $option == "n" ]]; then
            exit 1
        fi
    fi

    echo Uninstalling components from config.

    COMPO_FILE="$COMPO_AMDGPU_FILE"

    # Reset COMPONENTS
    COMPONENTS=

    read_components

    # Run the pre-remove scripts for each component
    # Workaround for amdgpu packages order
    local remove_arr
    read -r -a remove_arr <<< "$COMPONENTS"
    for(( i=0; i<${#remove_arr[@]}; i++ )) do
        compo=${remove_arr[i]}

        uninstall_prerm_scriptlet_amdgpu "$compo"

        # remove files
        path_to_files="$EXTRACT_AMDGPU_DIR/content/$AMDGPU_DISTRO_TAG/$compo"

        echo "Removing amdgpu files..."
        find_and_delete "$path_to_files" "l"
        find_and_delete "$path_to_files" "f"

        delete_empty_dirs "$path_to_files"

        uninstall_postrm_scriptlet "$compo"
    done

    # Update initramfs for all kernels
    # shellcheck disable=SC2086
    $SUDO $UPDATE_INITRAMFS_CMD

    echo -e "\e[95mUNINSTALL amdgpu Components. Complete.\e[0m"
}

###### Dependency Installation #####################################################

install_deps() {
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo -e "\e[96mINSTALL AMDGPU Dependencies : $DISTRO_NAME $DISTRO_VER\e[0m"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="

    echo Installing AMDGPU Dependencies...

    echo "DEPS_ARG = $DEPS_ARG"

    local status=0

    # Check for verbose logging enable
    local depOp=""
    if [[ $VERBOSE == 1 ]]; then
        depOp="verbose "
    fi

    if [[ $PROMPT_USER == 1 ]]; then
        depOp+="prompt"
    fi

    # Parse the dependency args
    if [[ $DEPS_ARG == "list" ]]; then
        echo Listing required AMDGPU dependencies
        # shellcheck disable=SC2086  # depOp intentionally unquoted for word splitting
        ./deps-installer.sh "amdgpu" $depOp list
        status=$?

        if [[ $status -ne 0 ]]; then
            print_err "Failed AMDGPU dependencies list."
            exit 1
        fi

        exit 0

    elif [[ $DEPS_ARG == "validate" ]]; then
        echo Validating required AMDGPU dependencies
        # shellcheck disable=SC2086  # depOp intentionally unquoted for word splitting
        ./deps-installer.sh "amdgpu" $depOp
        status=$?

        if [[ $status -ne 0 ]]; then
            print_err "Failed AMDGPU dependencies validation."
            exit 1
        fi

        exit 0

    elif [[ $DEPS_ARG == "install" ]] || [[ $DEPS_ARG == "install-only" ]]; then
        # shellcheck disable=SC2086  # depOp intentionally unquoted for word splitting
        ./deps-installer.sh "amdgpu" $depOp install
        status=$?

        if [[ $status -ne 0 ]]; then
            print_err "Failed AMDGPU dependencies install."
            exit 1
        fi

        if [[ $DEPS_ARG == "install-only" ]]; then
            echo Only AMDGPU dependencies installed. Exiting.
            exit 0
        fi

    else
        print_err "Invalid dependencies argument: $DEPS_ARG"
        exit 1
    fi
}

####### Main script ################################################################

# Create the installer log directory
if [ ! -d "$AMDGPU_INSTALLER_LOG_DIR" ]; then
    mkdir -p "$AMDGPU_INSTALLER_LOG_DIR"
fi

exec > >(tee -a "$AMDGPU_INSTALLER_CURRENT_LOG") 2>&1

echo =================================
echo AMDGPU INSTALLER
echo =================================

SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO="sudo"
SUDO_OPTS="$SUDO"
PROG=${0##*/}

os_release

# Parse all arguments (order-independent)
COMMAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        install|uninstall)
            COMMAND="$1"
            shift
            ;;
        help|--help|-h)
            COMMAND="help"
            shift
            ;;
        prompt)
            PROMPT_USER=1
            shift
            ;;
        verbose)
            VERBOSE=1
            RSYNC_OPTS_AMDGPU+="--itemize-changes -v "
            shift
            ;;
        start)
            AMDGPU_START=1
            shift
            ;;
        deps=*)
            DEPS_ARG="${1#*=}"
            echo "Using Dependency args: $DEPS_ARG"
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            COMMAND="help"
            shift
            ;;
    esac
done

# Default to help if no command specified
if [[ -z "$COMMAND" ]]; then
    COMMAND="help"
fi

# Get version info
get_version

# Handle dependency installation if deps= argument was provided
if [[ -n "$DEPS_ARG" ]]; then
    install_deps
fi

case "$COMMAND" in
    install)
        prompt_user "Start AMDGPU installation (y/n): "
        if [[ $option == "Y" || $option == "y" ]]; then
            install_amdgpu
        else
            echo "Installation cancelled."
            exit 0
        fi
        ;;
    uninstall)
        prompt_user "Start AMDGPU uninstallation (y/n): "
        if [[ $option == "Y" || $option == "y" ]]; then
            uninstall_amdgpu
        else
            echo "Uninstallation cancelled."
            exit 0
        fi
        ;;
    help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 1
        ;;
esac

echo "Installer log stored in: $AMDGPU_INSTALLER_CURRENT_LOG"

