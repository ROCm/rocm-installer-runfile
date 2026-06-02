#!/bin/bash
# shellcheck disable=SC2086  # rsync options and command arguments intentionally use word splitting

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

# Installer directory (where this script is located)
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load GFX architecture mappings
# Priority:
#   1. Use .gfx-lists file (has fine→coarse and coarse→fine mappings)
#   2. Fall back to embedded GFX_ARCHS_AVAILABLE from makeself header (.run file)
#
# The .gfx-lists file provides:
#   - GFX_ARCHS_AVAILABLE: all available archs (fine + coarse)
#   - GFX_FINE_TO_COARSE: associative array for fine → coarse mapping
#   - GFX_COARSE_TO_FINE: associative array for coarse → fine members
if [[ -f "$INSTALLER_DIR/component-rocm/.gfx-lists" ]]; then
    # shellcheck source=/dev/null
    source "$INSTALLER_DIR/component-rocm/.gfx-lists"
fi
# If running from .run file without .gfx-lists, GFX_ARCHS_AVAILABLE will be
# set from makeself header, but mappings won't be available

# GPU Detection (populated by detect_hardware_gfx)
DETECTED_DEVICE_IDS=()
DETECTED_DEVICE_NAMES=()
DETECTED_GFX_ARCHS=()
DETECTED_GFX_RESULT=""

# Logs
RUN_INSTALLER_LOG_DIR="$PWD/logs"
RUN_INSTALLER_CURRENT_LOG="$RUN_INSTALLER_LOG_DIR/install_rocm_$(date +%s).log"

# Source extract directories
EXTRACT_ROCM_DIR="$PWD/component-rocm"

# Target install directories
TARGET_ROCM_DEFAULT_DIR="/opt"
TARGET_ROCM_DIR="$TARGET_ROCM_DEFAULT_DIR"

# Component Configuration
COMPO_INSTALL="core"  # Default component: core, core-dev, dev-tools, core-sdk, opencl, test (comma-separated)
COMPO_META_DIR="$EXTRACT_ROCM_DIR/deps/meta"
COMPO_TEST_DIR="$EXTRACT_ROCM_DIR/deps/test"
COMPO_VER_FILE="component-versions.txt"
SIGNATURE_FILE="signature.txt"
USER_SPECIFIED_COMPO=0  # Track if user explicitly specified compo= argument
USER_SPECIFIED_GFX=0    # Track if user explicitly specified gfx= argument
COMPONENTS=
COMPONENTS_GFX=
INSTALL_GFX=
GFX_INSTALL_LIST=()     # Array of GFX architectures to install (for multi-GFX support)

# Graphics Configuration
USE_GRAPHICS=0  # Flag for graphics use case (amdgpu-lib)

# AMDGPU Configuration
AMDGPU_VER_FILE="amdgpu-dkms-ver.txt"

# On-demand extraction tracking
EXTRACTED_CONTENT_ARCHIVES=""  # Track which content archives have been extracted

# Installation manifest tracking
INSTALL_MANIFEST_NAME="manifest.txt"
INSTALL_MANIFEST_FILE=""  # Set after TARGET_DIR and ROCM_VER are known

# Install Configuration
RSYNC_OPTS_ROCM="--keep-dirlinks -rlp "
ROCM_INSTALL=0
AMDGPU_INSTALL=0
NCURSES_BAR=1

COMPONENT_COUNT=0
POSTINST_COUNT=0
PRERM_COUNT=0
POSTRM_COUNT=0

PROMPT_USER=0
POST_ROCM_INSTALL=0
VERBOSE=0
FORCE_INSTALL=0

# Arguments to pass to amdgpu-installer.sh
AMDGPU_INSTALLER_ARGS=""

# Installer preqreqs
INSTALLER_DEPS=(rsync findutils)


###### Functions ###############################################################

usage() {
cat <<END_USAGE
Usage: bash $PROG [options]

[options]:
    help    = Displays this help information.
    version = Display version information.

    Dependencies:
    -------------
        deps=<arg> <compo>

        <arg>
            list <compo>         = Lists required dependencies for install <compo>.
            validate <compo>     = Validates installed and not installed required dependencies for install <compo>.
            install-only <compo> = Install dependencies only for <compo>.
            install <compo>      = Install with dependencies for <compo>.

            file <file_path>      = Install with dependencies from a dependencies configuration file with path <file_path>.
            file-only <file_path> = Install with dependencies from a dependencies configuration file only with path <file_path>.

        <compo> = install component (rocm/amdgpu/rocm amdgpu)

    Install:
    --------
        rocm   = Enable ROCm components install.
        amdgpu = Enable amdgpu driver install.

        force    = Force ROCm/amdgpu driver install.
        graphics = Enable graphics support (installs amdgpu-lib for Mesa/OpenGL)

        target=<directory>
               <directory> = Target directory path for ROCm component install.

        gfx=<arch>
            <arch> = GPU architecture to install (e.g., gfx94x, gfx110x, gfx1101, etc.)
                     Installs base components plus architecture-specific components.
                     If not specified, auto-detects GPU and installs matching architecture.

                     Special values:
                       gfx=all  - Install all available architectures
                       gfx=list - Show available architectures in this installer
                       gfx=list-installed - Show currently installed architectures
                       gfx=show - Detect and display GPU information

        compo=<component_list>
            <component_list> = Comma-separated list of ROCm components to install.
                               If not specified, defaults to 'core'.
                               Use compo=list to see available component categories.
                               Available components:
                                   core      = Core ROCm components (amdrocm-core)
                                   core-dev  = Core development components (amdrocm-core-devel)
                                   dev-tools = Developer tools (amdrocm-developer-tools)
                                   core-sdk  = Core SDK components (amdrocm-core-sdk)
                                   opencl    = OpenCL runtime (amdrocm-opencl)
                                   test      = Test packages (architecture-specific)
                               Examples:
                                   compo=core
                                   compo=core,dev-tools
                                   compo=core-sdk,dev-tools
                                   compo=opencl

    Post Install:
    -------------
        Post-install configuration runs by default after ROCm installation (scripts, symlink create, etc.)

        postrocm     = Run post ROCm installation configuration.
                       Use this to run post-install after installing with 'nopostrocm'.
                       Default target: /opt (can override with target=<path>)
                       Optional: compo= and gfx= to match original installation args
                       If compo=/gfx= not specified, auto-detects installed components

        nopostrocm   = Disable post ROCm installation configuration.
                       By default, post-install runs automatically with 'rocm'.
                       Use this flag to skip post-install processing.

        amdgpu-start = Start the amdgpu driver after install.

        gpu-access=<access_type>

                   <access_type>
                       user = Add current user to render,video group for GPU access
                       all  = Grant GPU access to all users on the system via udev rules.

    Uninstall:
    ----------
        uninstall-rocm target=<directory/rocm-ver> = Uninstall ROCm version at target directory path.
                              <directory/rocm-ver> = ROCm version target directory path for uninstall.
                                         rocm-ver  = ROCm version directory: rocm-x.y.z (x=major, y=minor, patch number)

                             * If target=<directory/rocm-ver> is not provided, uninstall will be from /opt/rocm-x.y.z
                             * Optional: Use gfx= for selective GFX uninstall
                             * If gfx= not specified, auto-detects and uninstalls all installed components

                             Multi-arch selective uninstall:
                             * Use gfx=<arch> to uninstall specific architecture (e.g., gfx=gfx1101)
                             * Use gfx=all to uninstall all architectures
                             * Base components remain until last GFX arch is removed
                             * Requires manifest file for selective uninstall (created during install)

        uninstall-amdgpu = Uninstall amdgpu driver.


    Information/Debug:
    ------------------
    findrocm = Search for an install of ROCm.
    manifest = List the version of all ROCm components included in the installer.
    manifest=<gfx> = List components for specific gfx architecture (e.g., manifest=gfx110x, manifest=base).
    prompt   = Run the installer with user prompts.
    verbose  = Run installer with verbose logging

+++++++++++++++++++++++++++++++
Usage examples:
+++++++++++++++++++++++++++++++

# ROCm installation (no Dependency install)

    * ROCm install location (default) => /opt/rocm-x.y.z
        bash $PROG gfx=gfx94x rocm

# ROCm + Dependency installation

    * ROCm install location (default) => /opt/rocm-x.y.z
        bash $PROG deps=install gfx=gfx94x rocm

# ROCm + Dependency installation + ROCm target location

    * ROCm install location => $HOME/myrocm/rocm-x.y.z
        bash $PROG deps=install target="$HOME/myrocm" gfx=gfx94x rocm

# ROCm + Dependency installation + gpu access (post-install runs by default)

    bash $PROG deps=install gfx=gfx94x rocm gpu-access=all
    bash $PROG deps=install target="$HOME/myrocm" gfx=gfx94x rocm gpu-access=all

# ROCm + Component selection (post-install runs by default)

    * Install core + dev-tools
        bash $PROG compo=core,dev-tools gfx=gfx94x rocm

    * Install core-sdk with gfx support
        bash $PROG compo=core-sdk gfx=gfx94x rocm

    * Multi-arch: Install all available architectures
        bash $PROG gfx=all rocm

    * Install without post-install processing
        bash $PROG gfx=gfx94x rocm nopostrocm

    * Run post-install later (after installing with nopostrocm)
        bash $PROG postrocm                                      # Auto-detect, uses default /opt
        bash $PROG target=/custom/path postrocm                  # Auto-detect, custom location
        bash $PROG gfx=gfx94x postrocm                           # Explicit gfx, uses default /opt
        bash $PROG compo=core-sdk gfx=gfx94x postrocm            # With component selection
        bash $PROG target=/custom/path gfx=gfx94x postrocm       # Custom location with gfx

# ROCm + GFX architecture-specific installation

    * Auto-detect GPU and install matching architecture (default if gfx= not specified)
        bash $PROG rocm
        bash $PROG deps=install rocm

    * Install base ROCm + gfx94x components to default location
        bash $PROG gfx=gfx94x rocm

    * Install base ROCm + gfx950 components with dependencies
        bash $PROG deps=install gfx=gfx950 rocm

    * Install base ROCm + gfx94x components to custom location
        bash $PROG deps=install target="$HOME/myrocm" gfx=gfx94x rocm

    * Multi-arch: Install fine-grained architecture (e.g., gfx1101 instead of gfx110x)
        bash $PROG gfx=gfx1101 rocm
        bash $PROG deps=install gfx=gfx1101 rocm

    * Multi-arch: Install coarse family (all members: gfx1100, gfx1101, gfx1102, gfx1103)
        bash $PROG gfx=gfx110x rocm

# ROCm + Component selection

    * Install core components only (default)
        bash $PROG gfx=gfx94x rocm
        bash $PROG compo=core gfx=gfx94x rocm

    * Install core + developer tools
        bash $PROG compo=core,dev-tools gfx=gfx94x rocm

    * Install core SDK with gfx94x support
        bash $PROG compo=core-sdk gfx=gfx94x rocm

    * Install core development components with dependencies
        bash $PROG deps=install compo=core-dev gfx=gfx950 rocm

    ** Recommended ***

# amdgpu Driver installation (no Dependency install)

    bash $PROG amdgpu

# amdgpu Driver + Dependency installation

    bash $PROG deps=install amdgpu

# Combined Installation

    bash $PROG deps=install gfx=gfx94x rocm amdgpu gpu-access=all
    bash $PROG deps=install target="$HOME/myrocm" gfx=gfx94x rocm amdgpu gpu-access=all

# Uninstall

    * Complete uninstall (auto-detects all installed components)
        bash $PROG uninstall-rocm
        bash $PROG target="$HOME/myrocm/rocm-x.y.z" uninstall-rocm

    * Multi-arch selective uninstall (remove specific GFX arch, keep base + other archs)
        bash $PROG gfx=gfx1101 uninstall-rocm                    # Remove gfx1101, keep base + other archs
        bash $PROG gfx=all uninstall-rocm                        # Remove all architectures
        bash $PROG target=/opt/rocm-7.14 gfx=gfx942 uninstall-rocm  # Selective with custom target

    * Uninstall amdgpu driver
        bash $PROG uninstall-amdgpu

    * Uninstall combined
        bash $PROG uninstall-amdgpu uninstall-rocm

END_USAGE
}

get_coarse_family() {
    # Maps user-specified arch to coarse family for archive extraction
    # Args: $1 = fine-grained arch (e.g., gfx1101)
    # Returns: coarse family (e.g., gfx110x) or input if no mapping

    local fine_arch="$1"

    # Use GFX_FINE_TO_COARSE mapping from .gfx-lists file
    if [[ -n "${GFX_FINE_TO_COARSE[$fine_arch]:-}" ]]; then
        echo "${GFX_FINE_TO_COARSE[$fine_arch]}"
    else
        # No mapping found - could be coarse family itself or unknown arch
        echo "$fine_arch"
    fi
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
            PACKAGE_TYPE="deb"
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
            PACKAGE_TYPE="rpm"

            if ! rpm -qa | grep -qE "ncurses-[0-9]"; then
                NCURSES_BAR=0
            fi

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
    # Line 1: Installer version
    # Line 2: ROCm version
    # Line 3: Build pull info
    # Line 4: Build run ID
    # Line 5: Build workflow number
    # Line 6: AMDGPU DKMS build number
    if [ -n "$version_file" ]; then
        while IFS= read -r line; do
            case $i in
                0) INSTALLER_VERSION="$line" ;;
                1) ROCM_VERSION="$line" ;;
                2) BUILD_PULL_INFO="$line" ;;
                3) BUILD_RUNID="$line" ;;
                4) BUILD_WORKFLOW_NUM="$line" ;;
                5) AMDGPU_DKMS_BUILD_NUM="$line" ;;
            esac
            i=$((i+1))
        done < "$version_file"
    fi

    # If AMDGPU build number wasn't in VERSION file (pre-build state),
    # try reading from component-amdgpu directory
    if [[ -z "$AMDGPU_DKMS_BUILD_NUM" || "$AMDGPU_DKMS_BUILD_NUM" == "" ]]; then
        local amdgpu_ver_file="./component-amdgpu/$AMDGPU_VER_FILE"
        if [ -f "$amdgpu_ver_file" ]; then
            AMDGPU_DKMS_BUILD_NUM=$(tr -d '[:space:]' < "$amdgpu_ver_file")
        else
            AMDGPU_DKMS_BUILD_NUM="N/A"
        fi
    fi

    echo "Installer Version: $INSTALLER_VERSION"
    echo "ROCm Version     : $ROCM_VERSION"
    echo "Build Pull Info  : $BUILD_PULL_INFO"
    echo "Build Run ID     : $BUILD_RUNID"
    echo "Build Workflow   : $BUILD_WORKFLOW_NUM"
    echo "AMDGPU Build     : $AMDGPU_DKMS_BUILD_NUM"
}

setup_rocm_version_info() {
    echo "Setting up ROCm version information from VERSION file..."

    # Use ROCM_VERSION from VERSION file (already read earlier)
    if [[ -z "$ROCM_VERSION" ]]; then
        print_err "ROCM_VERSION not available from VERSION file"
        return 1
    fi

    # Extract short version (major.minor only, e.g., 7.12.0 -> 7.12)
    ROCM_VER=$(echo "$ROCM_VERSION" | cut -d '.' -f 1-2)

    # Set installer version to full version (e.g., 7.12.0)
    INSTALLER_ROCM_VERSION="$ROCM_VERSION"

    # Set version name to rocm/core-{version} format (e.g., rocm/core-7.12)
    INSTALLER_ROCM_VERSION_NAME="rocm/core-$ROCM_VER"

    echo "  INSTALLER_ROCM_VERSION     : $INSTALLER_ROCM_VERSION"
    echo "  INSTALLER_ROCM_VERSION_NAME: $INSTALLER_ROCM_VERSION_NAME"
    echo "  ROCM_VER                   : $ROCM_VER"

    return 0
}

print_no_err() {
    local msg=$1
    echo -e "\e[32m++++++++++++++++++++++++++++++++++++\e[0m"
    echo -e "\e[32m$msg\e[0m"
    echo -e "\e[32m++++++++++++++++++++++++++++++++++++\e[0m"
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

format_size() {
    local bytes=$1
    local kb=$((bytes / 1024))
    local mb=$((kb / 1024))
    local gb=$((mb / 1024))

    if [[ $gb -gt 0 ]]; then
        local gb_dec=$(( (mb * 10 / 1024) % 10 ))
        echo "${gb}.${gb_dec} GB"
    elif [[ $mb -gt 0 ]]; then
        local mb_dec=$(( (kb * 10 / 1024) % 10 ))
        echo "${mb}.${mb_dec} MB"
    else
        echo "${kb} KB"
    fi
}

# Manifest file management for tracking installed components
# Creates/updates manifest at <install-target>/rocm/core-<ver>/.info/manifest.txt
create_manifest_header() {
    local manifest_file=$1
    local manifest_dir
    manifest_dir=$(dirname "$manifest_file")

    # Create .info directory if it doesn't exist
    $SUDO mkdir -p "$manifest_dir"

    # Initialize manifest with header
    $SUDO tee "$manifest_file" > /dev/null <<EOF
# ROCm Runfile Installation Manifest
# Created: $(date '+%Y-%m-%d %H:%M:%S')
# Installer Version: ${INSTALLER_ROCM_VERSION_NAME}
# ROCm Version: ${ROCM_VER}
# Installation Target: ${TARGET_DIR}
#
# Format: <component_type>|<component_name>|<gfx_arch>
# component_type: base or gfx
# gfx_arch: base for base components, gfxXYZ for GFX components
EOF
}

write_to_manifest() {
    local manifest_file=$1
    local component_type=$2  # "base" or "gfx"
    local component_name=$3
    local gfx_arch=$4        # "base" for base components, "gfxXYZ" for GFX

    # Append component entry to manifest
    echo "${component_type}|${component_name}|${gfx_arch}" | $SUDO tee -a "$manifest_file" > /dev/null
}

read_manifest() {
    local manifest_file=$1

    # Read manifest and output component entries (skip comments and empty lines)
    if [[ -f "$manifest_file" ]]; then
        grep -v '^#' "$manifest_file" | grep -v '^[[:space:]]*$'
        return 0
    else
        return 1
    fi
}

load_existing_manifest() {
    local manifest_file=$1
    local -n existing_array=$2  # nameref to associative array (for deduplication)
    local -n order_array=$3     # nameref to indexed array (for preserving order)

    if [[ ! -f "$manifest_file" ]]; then
        return 1
    fi

    echo -e "\e[32mFound existing manifest, preserving previous installation records\e[0m"

    # Read existing manifest entries (skip comments and empty lines)
    # This includes both component entries (base|comp|gfx) and tracking markers (installed-base:yes, installed-gfx:gfxXYZ)
    while IFS= read -r line; do
        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Store all non-comment lines in both:
        # 1. Associative array for deduplication (existing_array)
        # 2. Indexed array for preserving order (order_array)
        # shellcheck disable=SC2034
        existing_array["$line"]=1
        order_array+=("$line")
    done < <(read_manifest "$manifest_file")

    return 0
}

restore_manifest_entries() {
    local manifest_file=$1
    # shellcheck disable=SC2178  # nameref is intentionally used as array reference
    local -n order_array=$2  # nameref to indexed array (preserves order)

    if [[ ${#order_array[@]} -eq 0 ]]; then
        return 0
    fi

    # Restore existing components from previous installations in original order
    for entry in "${order_array[@]}"; do
        echo "$entry" | $SUDO tee -a "$manifest_file" > /dev/null
    done
}

create_manifest() {
    # Set installation manifest file path
    INSTALL_MANIFEST_FILE="$TARGET_DIR/rocm/core-$ROCM_VER/.info/$INSTALL_MANIFEST_NAME"

    echo -e "\e[36mInstallation manifest: $INSTALL_MANIFEST_FILE\e[0m"

    # Check if manifest already exists (for incremental installs)
    declare -gA MANIFEST_ENTRIES  # Global associative array to track existing components (for deduplication)
    # shellcheck disable=SC2034  # Used by reference in load_existing_manifest and restore_manifest_entries
    declare -ga MANIFEST_ORDER    # Global indexed array to preserve order

    # Load existing manifest if present (function returns 1 if not found, which is okay)
    load_existing_manifest "$INSTALL_MANIFEST_FILE" MANIFEST_ENTRIES MANIFEST_ORDER || true

    # Create manifest header (overwrites file, but we'll restore entries)
    echo "Creating installation manifest at: $INSTALL_MANIFEST_FILE"
    create_manifest_header "$INSTALL_MANIFEST_FILE"

    # Restore existing components from previous installations in original order
    restore_manifest_entries "$INSTALL_MANIFEST_FILE" MANIFEST_ORDER
}

add_component_to_manifest() {
    local component_type=$1  # "base" or "gfx"
    local component_name=$2
    local gfx_arch=$3        # "base" for base components, "gfxXYZ" for GFX

    # Only write to manifest if not already present
    local entry="${component_type}|${component_name}|${gfx_arch}"
    if [[ -z "${MANIFEST_ENTRIES[$entry]}" ]]; then
        write_to_manifest "$INSTALL_MANIFEST_FILE" "$component_type" "$component_name" "$gfx_arch"
        MANIFEST_ENTRIES["$entry"]=1  # Mark as added
    fi
}

load_manifest_for_uninstall() {
    local manifest_file=$1

    # Use read_manifest to get entries, return 1 if file doesn't exist
    local manifest_entries
    manifest_entries=$(read_manifest "$manifest_file" 2>/dev/null) || return 1

    echo -e "\e[36mInstallation manifest: $manifest_file\e[0m"
    echo -e "\e[32mFound installation manifest, using it for uninstall detection\e[0m"

    # Reset component variables
    COMPONENTS=
    COMPONENTS_GFX=

    # Process each manifest entry
    while IFS='|' read -r comp_type comp_name gfx_arch; do
        if [[ "$comp_type" == "base" ]]; then
            COMPONENTS="$COMPONENTS $comp_name"
        elif [[ "$comp_type" == "gfx" ]]; then
            # Find or create gfx_components array entry for this architecture
            local found=0
            for i in "${!gfx_components[@]}"; do
                if [[ "${gfx_components[$i]}" == *"|$gfx_arch" ]]; then
                    # shellcheck disable=SC2004
                    gfx_components[$i]="${gfx_components[$i]%|*} $comp_name|$gfx_arch"
                    found=1
                    break
                fi
            done
            [[ $found -eq 0 ]] && gfx_components+=("$comp_name|$gfx_arch")
            [[ -z "$INSTALL_GFX" ]] && INSTALL_GFX="$gfx_arch"
        fi
    done <<< "$manifest_entries"

    # Trim whitespace from COMPONENTS
    COMPONENTS="${COMPONENTS#"${COMPONENTS%%[![:space:]]*}"}"
    COMPONENTS="${COMPONENTS%"${COMPONENTS##*[![:space:]]}"}"

    echo "Components from manifest - Base: $COMPONENTS"
    [[ ${#gfx_components[@]} -gt 0 ]] && echo "Components from manifest - GFX: ${gfx_components[*]}"

    return 0
}

extract_content_if_needed() {
    # Extract ROCm content archives on-demand based on GFX selection
    # Only extracts archives that haven't been extracted yet
    # Handles family-grouped archives (multi-arch) and individual archives (single-arch)

    local gfx_tags_needed="base"

    # Add selected GFX tags
    if [[ -n "$INSTALL_GFX" ]]; then
        gfx_tags_needed="$gfx_tags_needed $INSTALL_GFX"
    fi

    echo "GFX architectures needed: $gfx_tags_needed"

    for gfx_tag in $gfx_tags_needed; do
        # Map to coarse family for archive extraction
        # (for multi-arch installers, fine-grained archs are grouped in family archives)
        local coarse_family
        coarse_family=$(get_coarse_family "$gfx_tag")

        local archive="$INSTALLER_DIR/component-rocm/content-${coarse_family}.tar.xz"
        local extract_dir="$EXTRACT_ROCM_DIR/content"

        # Check if the user-requested arch content already exists
        # (could be from direct extraction of fine-grained dir, or from family archive)
        local content_dir="$extract_dir/$gfx_tag"
        if [[ -d "$content_dir" ]]; then
            echo "  Content for $gfx_tag already extracted, skipping"
            EXTRACTED_CONTENT_ARCHIVES="$EXTRACTED_CONTENT_ARCHIVES $coarse_family"
            continue
        fi

        # Check if the family archive was already extracted in this session
        if echo "$EXTRACTED_CONTENT_ARCHIVES" | grep -q "$coarse_family"; then
            echo "  Content family $coarse_family already extracted (contains $gfx_tag), skipping"
            continue
        fi

        if [[ ! -f "$archive" ]]; then
            echo -e "\e[31mERROR: Required archive not found: $archive\e[0m"
            echo -e "\e[31m       Expected: $archive\e[0m"
            echo -e "\e[31m       Requested GFX: $gfx_tag\e[0m"
            echo -e "\e[31m       Mapped to family: $coarse_family\e[0m"
            exit 1
        fi

        echo "  Extracting content for family: $coarse_family (requested: $gfx_tag) ..."

        if ! "$INSTALLER_DIR/component-extractor.sh" "$archive" "$extract_dir" "$INSTALLER_DIR"; then
            echo -e "\e[31mERROR: Failed to extract $archive\e[0m"
            exit 1
        fi

        # Mark family as extracted (family archive may contain multiple fine-grained archs)
        EXTRACTED_CONTENT_ARCHIVES="$EXTRACTED_CONTENT_ARCHIVES $coarse_family"
    done
}


extract_tests_if_needed() {
    # Only extract tests if explicitly requested via compo=test
    if [[ ! "$COMPO_INSTALL" =~ (^|,)test(,|$) ]]; then
        return 0
    fi

    echo "-------------------------------------------------------------"
    echo "Extracting tests..."
    echo "-------------------------------------------------------------"

    # Determine which GFX architectures are needed for tests
    local gfx_tags_needed="base"

    # Add selected GFX tags
    if [[ -n "$INSTALL_GFX" ]]; then
        gfx_tags_needed="$gfx_tags_needed $INSTALL_GFX"
    fi

    echo "Extracting test packages for: $gfx_tags_needed"

    local extracted_count=0
    local failed_count=0
    local skipped_count=0

    # Track which families we've already extracted to avoid duplicate extraction
    declare -A extracted_families

    for gfx_tag in $gfx_tags_needed; do
        # Map to coarse family for archive extraction
        local coarse_family
        coarse_family=$(get_coarse_family "$gfx_tag")

        # Check if we've already extracted this family
        if [[ -n "${extracted_families[$coarse_family]}" ]]; then
            echo "  Tests for family $coarse_family already extracted (contains $gfx_tag)"
            ((skipped_count++))
            continue
        fi

        local tests_archive="$INSTALLER_DIR/component-rocm/tests-${coarse_family}.tar.xz"
        local content_dir="$EXTRACT_ROCM_DIR/content/$gfx_tag"

        # Check if tests for this architecture are already extracted
        # Look for test packages in the content directory
        if [[ -d "$content_dir" ]]; then
            local has_tests=0
            for test_pkg in "$content_dir"/*test*/; do
                if [[ -d "$test_pkg" ]]; then
                    has_tests=1
                    break
                fi
            done

            if [[ $has_tests -eq 1 ]]; then
                echo "  Tests for $gfx_tag already extracted, skipping"
                ((skipped_count++))
                extracted_families["$coarse_family"]="1"
                continue
            fi
        fi

        # Check if archive exists
        if [[ ! -f "$tests_archive" ]]; then
            echo "  No test archive found for family $coarse_family ($(basename "$tests_archive")), skipping"
            continue
        fi

        echo "  Extracting tests for family: $coarse_family (needed for $gfx_tag) ..."

        local extract_start
        extract_start=$(date +%s)

        # Extract tests using component-extractor.sh
        # Note: Archive contains paths like "component-rocm/content/gfx*/...", so extract to INSTALLER_DIR
        if "$INSTALLER_DIR/component-extractor.sh" "$tests_archive" "$INSTALLER_DIR" "$INSTALLER_DIR"; then
            local extract_end
            extract_end=$(date +%s)

            local extract_duration=$((extract_end - extract_start))
            echo -e "  \e[32mExtracted tests for family $coarse_family successfully ($extract_duration seconds).\e[0m"
            ((extracted_count++))
            extracted_families["$coarse_family"]="1"
        else
            echo -e "  \e[31mERROR: Failed to extract test packages for family $coarse_family\e[0m"
            ((failed_count++))
        fi
    done

    echo ""
    echo "Test extraction summary: $extracted_count extracted, $skipped_count skipped, $failed_count failed"

    if [[ $failed_count -gt 0 ]]; then
        print_warning "Some test packages failed to extract."
        return 1
    fi

    if [[ $extracted_count -eq 0 && $skipped_count -eq 0 ]]; then
        print_warning "No test packages were found or extracted."
        return 1
    fi

    echo "Test extraction complete."
    echo "-------------------------------------------------------------"
    return 0
}

extract_gfx_archives_for_list() {
    # Extract base archive and family archives needed for a list of GFX architectures
    # Deduplicates by family to avoid extracting same archive multiple times
    # Args: $@ = Array of GFX architectures

    local -a gfx_list=("$@")
    declare -A extracted_families

    echo "Extracting archives for base + ${#gfx_list[@]} GFX architecture(s)..."

    # Step 1: Extract base archive first
    local base_archive="$INSTALLER_DIR/component-rocm/content-base.tar.xz"
    local base_content_dir="$EXTRACT_ROCM_DIR/content/base"

    if [[ -d "$base_content_dir" ]]; then
        echo "  Base content already extracted, skipping"
    elif echo "$EXTRACTED_CONTENT_ARCHIVES" | grep -q "base"; then
        echo "  Base content already extracted in this session, skipping"
    elif [[ -f "$base_archive" ]]; then
        echo "  Extracting base content"
        if ! "$INSTALLER_DIR/component-extractor.sh" "$base_archive" "$EXTRACT_ROCM_DIR/content" "$INSTALLER_DIR"; then
            print_err "Failed to extract base archive: $base_archive"
            return 1
        fi
        EXTRACTED_CONTENT_ARCHIVES="$EXTRACTED_CONTENT_ARCHIVES base"
    else
        print_err "Base archive not found: $base_archive"
        return 1
    fi

    # Step 2: Extract GFX family archives
    for gfx in "${gfx_list[@]}"; do
        # Map to coarse family for archive extraction
        local family
        family=$(get_coarse_family "$gfx")

        # Skip if already extracted this family
        if [[ -n "${extracted_families[$family]:-}" ]]; then
            echo "  Family $family already extracted (needed for $gfx), skipping"
            continue
        fi

        # Check if content already exists from previous extraction
        local content_dir="$EXTRACT_ROCM_DIR/content/$gfx"
        if [[ -d "$content_dir" ]]; then
            echo "  Content for $gfx already extracted, skipping"
            extracted_families[$family]=1
            EXTRACTED_CONTENT_ARCHIVES="$EXTRACTED_CONTENT_ARCHIVES $family"
            continue
        fi

        # Check if already extracted in this session
        if echo "$EXTRACTED_CONTENT_ARCHIVES" | grep -q "$family"; then
            echo "  Family $family already extracted (contains $gfx), skipping"
            extracted_families[$family]=1
            continue
        fi

        # Extract family archive
        local archive="$INSTALLER_DIR/component-rocm/content-${family}.tar.xz"

        if [[ ! -f "$archive" ]]; then
            print_err "Required archive not found: $archive"
            print_err "  Requested GFX: $gfx"
            print_err "  Mapped to family: $family"
            return 1
        fi

        echo "  Extracting family: $family (for $gfx)"

        if ! "$INSTALLER_DIR/component-extractor.sh" "$archive" "$EXTRACT_ROCM_DIR/content" "$INSTALLER_DIR"; then
            print_err "Failed to extract archive: $archive"
            return 1
        fi

        extracted_families[$family]=1
        EXTRACTED_CONTENT_ARCHIVES="$EXTRACTED_CONTENT_ARCHIVES $family"
    done

    echo "Archive extraction complete."
    return 0
}

dump_rocm_state() {
    echo ============================
    echo ROCm Install Summary
    echo ============================

    local rocm_install_loc=$TARGET_DIR
    local ls_opt=

    for dir in "$rocm_install_loc"/*; do
        if [[ -d "$dir" && $(basename "$dir") == "$INSTALLER_ROCM_VERSION_NAME" ]]; then
            rocm_directory=$dir
            break
        fi
    done

    echo -e "\e[32mROCm Installed to: $rocm_directory\e[0m"

    if [[ $VERBOSE == 1 ]]; then
        ls_opt="-la"

        echo ----------------------------
        echo -e "\e[95m$rocm_install_loc\e[0m"
        ls $ls_opt "$rocm_install_loc"

        echo ----------------------------
        echo -e "\e[95m$rocm_directory\e[0m"
        ls $ls_opt "$rocm_directory"

        echo ----------------------------
        echo -e "\e[95m/etc/ld.so.conf.d\e[0m"
        ls /etc/ld.so.conf.d

        echo ----------------------------
        echo -e "\e[95m/etc/alternatives\e[0m"
        ls $ls_opt /etc/alternatives

        echo ----------------------------
        echo -e "\e[95m$rocm_directory/include\e[0m"
        ls $ls_opt "$rocm_directory/include"

        echo ----------------------------
        echo -e "\e[95m$rocm_directory/bin\e[0m"
        ls $ls_opt "$rocm_directory/bin"

        echo ----------------------------
        echo -e "\e[95m$rocm_directory/lib\e[0m"
        ls $ls_opt "$rocm_directory/lib"
    fi

    echo ----------------------------
    echo -e "\e[95mInstalled Components:\e[0m"
    echo "Base: $COMPONENTS"
    if [[ -n $COMPONENTS_GFX ]]; then
        echo "GFX (${INSTALL_GFX}): $COMPONENTS_GFX"
    fi
}

get_available_gfx_archs() {
    # Get available GFX architectures from .gfx-lists file
    # Returns space-separated list of all available archs (fine + coarse)

    if [[ -n "${GFX_ARCHS_AVAILABLE:-}" ]]; then
        echo "$GFX_ARCHS_AVAILABLE"
    else
        echo ""
    fi
}

get_available_components() {
    # Return list of available component categories
    # These are the high-level component categories, not individual packages
    local components=("core" "core-dev" "dev-tools" "core-sdk" "opencl" "test")
    echo "${components[@]}"
}

get_existing_rocm_version() {
    # Extract ROCm version from existing installation directory
    # Args: $1 = installation path (e.g., /opt/rocm/core-7.14)
    # Returns: version string (e.g., 7.14) or empty string if not found
    local install_path="$1"

    if [[ -z "$install_path" || ! -d "$install_path" ]]; then
        echo ""
        return 1
    fi

    # Extract version from directory name (e.g., /opt/rocm/core-7.14 -> 7.14)
    local dirname
    dirname=$(basename "$install_path")
    if [[ "$dirname" =~ ^core-([0-9]+\.[0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    echo ""
    return 1
}

check_rocm_version_mismatch() {
    # Check if installer version matches existing ROCm installation
    # Prevents mixing different ROCm versions in multi-GFX scenarios
    # Args: $1 = target directory (e.g., /opt/rocm)
    # Returns: 0 if versions match or no existing install, 1 if mismatch detected

    local target_dir="$1"

    if [[ -z "$ROCM_VER" ]]; then
        print_err "ROCM_VER not set, cannot perform version check"
        return 1
    fi

    # Look for ALL existing ROCm installations in target directory
    # Check all core-* directories (skip symlinks)
    local found_mismatch=0
    local mismatch_version=""
    local mismatch_dir=""
    local found_any=0

    if [[ -d "$target_dir/rocm" ]]; then
        for dir in "$target_dir/rocm"/core-*; do
            # Skip if not a directory or if it's a symlink
            if [[ ! -d "$dir" ]] || [[ -L "$dir" ]]; then
                continue
            fi

            found_any=1

            # Extract version from this installation
            local existing_version
            existing_version=$(get_existing_rocm_version "$dir")

            if [[ -z "$existing_version" ]]; then
                # Could not determine version from this directory, skip it
                continue
            fi

            # Compare versions
            if [[ "$existing_version" != "$ROCM_VER" ]]; then
                found_mismatch=1
                mismatch_version="$existing_version"
                mismatch_dir="$dir"
                break
            fi
        done
    fi

    # No existing installation found, version check passes
    if [[ $found_any -eq 0 ]]; then
        return 0
    fi

    # Version mismatch detected
    if [[ $found_mismatch -eq 1 ]]; then
        echo ""
        echo -e "\e[91m================================================================\e[0m"
        echo -e "\e[91mERROR: ROCm Version Mismatch\e[0m"
        echo -e "\e[91m================================================================\e[0m"
        echo ""
        echo "Existing ROCm installation version: $mismatch_version"
        echo "  Location: $mismatch_dir"
        echo ""
        echo "Installer ROCm version: $ROCM_VER"
        echo ""
        echo "You cannot add/remove/upgrade GFX architectures or components"
        echo "across different ROCm versions."
        echo ""
        echo "Options:"
        echo "  1. Use an installer matching version $mismatch_version"
        echo "  2. Uninstall existing ROCm $mismatch_version first:"
        echo "     $PROG target=$target_dir uninstall-rocm"
        echo ""
        echo -e "\e[91m================================================================\e[0m"
        echo ""
        return 1
    fi

    # All versions match
    return 0
}

#------------------------------------------------------------------------------
# Multi-GFX Tracking Functions (using manifest.txt header)
#------------------------------------------------------------------------------

mark_gfx_installed() {
    # Mark a GFX architecture as installed in manifest header (MULTI-ARCH ONLY)
    # This function is only used by multi-arch builds to track individual GFX archs
    # Args: $1 = GFX architecture (e.g., "gfx1100")
    local gfx="$1"

    if [[ -z "$INSTALL_MANIFEST_FILE" || ! -f "$INSTALL_MANIFEST_FILE" ]]; then
        print_err "Cannot mark GFX installed: manifest file not available"
        return 1
    fi

    local marker="installed-gfx:$gfx"

    # Only add if not already present (check both file and in-memory array)
    if [[ -z "${MANIFEST_ENTRIES[$marker]:-}" ]] && ! is_gfx_installed "$gfx"; then
        echo "$marker" | $SUDO tee -a "$INSTALL_MANIFEST_FILE" > /dev/null
        MANIFEST_ENTRIES["$marker"]=1
        echo "Marked GFX arch as installed: $gfx"
    fi
}

unmark_gfx_installed() {
    # Remove GFX architecture marker from manifest header (MULTI-ARCH ONLY)
    # This function is only used by multi-arch builds
    # Args: $1 = GFX architecture (e.g., "gfx1100")
    local gfx="$1"

    if [[ -z "$INSTALL_MANIFEST_FILE" || ! -f "$INSTALL_MANIFEST_FILE" ]]; then
        return 0
    fi

    sed -i "/^installed-gfx:${gfx}$/d" "$INSTALL_MANIFEST_FILE"
    echo "Unmarked GFX arch: $gfx"
}

is_gfx_installed() {
    # Check if a GFX architecture is marked as installed (MULTI-ARCH ONLY)
    # This function only works with multi-arch manifest format
    # Args: $1 = GFX architecture (e.g., "gfx1100")
    # Returns: 0 if installed, 1 if not
    local gfx="$1"

    if [[ -z "$INSTALL_MANIFEST_FILE" || ! -f "$INSTALL_MANIFEST_FILE" ]]; then
        return 1
    fi

    grep -q "^installed-gfx:${gfx}$" "$INSTALL_MANIFEST_FILE" 2>/dev/null
}

get_installed_gfx_archs() {
    # Get space-separated list of installed GFX architectures (MULTI-ARCH ONLY)
    # This function only works with multi-arch manifest format
    # Returns: "gfx1100 gfx1101 gfx942" or "" if none

    if [[ -z "$INSTALL_MANIFEST_FILE" || ! -f "$INSTALL_MANIFEST_FILE" ]]; then
        echo ""
        return
    fi

    local archs
    archs=$(grep "^installed-gfx:" "$INSTALL_MANIFEST_FILE" 2>/dev/null | cut -d: -f2 | tr '\n' ' ')
    echo "${archs% }"  # Trim trailing space
}

# shellcheck disable=SC2120  # Optional argument is valid, caller may omit it
detect_installed_rocm_version() {
    # Detect installed ROCm and set version info (non-interactive, no progress bar)
    # Returns: 0 if found, 1 if not found
    # Sets global variables: ROCM_VER, INSTALL_MANIFEST_FILE
    # Args: $1 = search base directory (optional, defaults to TARGET_DIR)
    #
    # Use this for quick detection without user feedback.
    # For interactive uninstall with progress bar, use find_rocm_with_progress()

    local search_base="${1:-$TARGET_DIR}"
    local rocm_depth="-maxdepth 4"
    local rocm_core_dirs

    # Search for /rocm/core-* directories
    rocm_core_dirs=$(find "$search_base" $rocm_depth -type d -regex '.*/rocm/core-[^/]*$' \
        ! -path '*/rocm-installer/component-rocm/*' \
        ! -path '*/component-rocm/base/*/rocm/core-*' \
        ! -path '*/component-rocm/gfx*/*/rocm/core-*' \
        -print 2>/dev/null)

    if [[ -z "$rocm_core_dirs" ]]; then
        return 1
    fi

    # Use the first found directory
    local rocm_ver_dir
    rocm_ver_dir=$(echo "$rocm_core_dirs" | head -1)

    # Extract version from directory name (e.g., /opt/rocm/core-7.14 → 7.14)
    ROCM_VER=$(basename "$rocm_ver_dir" | sed 's/^core-//')

    # Set manifest file path
    INSTALL_MANIFEST_FILE="$rocm_ver_dir/.info/$INSTALL_MANIFEST_NAME"

    return 0
}

mark_base_installed() {
    # Mark base packages as installed in manifest header

    if [[ -z "$INSTALL_MANIFEST_FILE" || ! -f "$INSTALL_MANIFEST_FILE" ]]; then
        print_err "Cannot mark base installed: manifest file not available"
        return 1
    fi

    local marker="installed-base:yes"

    # Only add if not already present (check both file and in-memory array)
    if [[ -z "${MANIFEST_ENTRIES[$marker]:-}" ]] && ! is_base_installed; then
        echo "$marker" | $SUDO tee -a "$INSTALL_MANIFEST_FILE" > /dev/null
        MANIFEST_ENTRIES["$marker"]=1
        echo "Marked base packages as installed"
    fi
}

is_base_installed() {
    # Check if base packages are marked as installed
    # Returns: 0 if installed, 1 if not

    if [[ -z "$INSTALL_MANIFEST_FILE" || ! -f "$INSTALL_MANIFEST_FILE" ]]; then
        return 1
    fi

    grep -q "^installed-base:yes$" "$INSTALL_MANIFEST_FILE" 2>/dev/null
}

unmark_base_installed() {
    # Remove base packages marker from manifest header

    if [[ -z "$INSTALL_MANIFEST_FILE" || ! -f "$INSTALL_MANIFEST_FILE" ]]; then
        return 0
    fi

    sed -i "/^installed-base:yes$/d" "$INSTALL_MANIFEST_FILE"
    echo "Unmarked base packages"
}

#------------------------------------------------------------------------------
# GFX Argument Parsing Functions
#------------------------------------------------------------------------------

parse_gfx_argument() {
    # Parse gfx= argument into array of GFX architectures
    # Args:
    #   $1: gfx argument value (e.g., "all", "gfx1100", "gfx1100,gfx1101,gfx942")
    #   $2: name of array variable to populate (nameref)
    # Returns: 0 on success, 1 on error

    local gfx_arg="$1"
    local -n result_array="$2"  # nameref

    # Clear result array
    result_array=()

    if [[ "$gfx_arg" == "all" ]]; then
        # Multi-arch only
        if [[ "${INSTALLER_BUILD_TYPE:-}" != "multi-arch" ]]; then
            print_err "gfx=all is only supported for multi-arch installers."
            print_err "This is a ${INSTALLER_BUILD_TYPE:-single-arch} installer."
            return 1
        fi

        # Return all available archs
        read -r -a result_array <<< "$GFX_ARCHS_AVAILABLE"
        echo "Expanded gfx=all to ${#result_array[@]} architectures"

    elif [[ "$gfx_arg" == *","* ]]; then
        # Comma-separated list - multi-arch only
        if [[ "${INSTALLER_BUILD_TYPE:-}" != "multi-arch" ]]; then
            print_err "Multiple GFX architectures (comma-separated) only supported for multi-arch installers."
            print_err "This is a ${INSTALLER_BUILD_TYPE:-single-arch} installer."
            return 1
        fi

        # Split by comma
        IFS=',' read -ra result_array <<< "$gfx_arg"
        echo "Parsed ${#result_array[@]} GFX architectures from comma-separated list"

    else
        # Single arch (works for both single-arch and multi-arch)
        result_array=("$gfx_arg")
    fi

    return 0
}

validate_gfx_list() {
    # Validate that all GFX archs in list are available in installer
    # Args: $@ = Array of GFX architectures
    # Returns: 0 if all valid, 1 if any invalid

    local -a gfx_list=("$@")
    local all_valid=1

    for gfx in "${gfx_list[@]}"; do
        if [[ ! " $GFX_ARCHS_AVAILABLE " == *" $gfx "* ]]; then
            print_err "GFX architecture '$gfx' is not available in this installer."
            all_valid=0
        fi
    done

    if [[ $all_valid -eq 0 ]]; then
        echo ""
        echo "Available architectures:"
        for arch in $GFX_ARCHS_AVAILABLE; do
            echo "  $arch"
        done
        echo ""
        echo "Use 'gfx=list' to see all available architectures."
        return 1
    fi

    return 0
}

detect_hardware_gfx() {
    # Helper function to detect hardware GFX architecture and device information
    # Sets DETECTED_GFX_RESULT variable with detected GFX architecture string (e.g., "gfx90a")
    # Exit code: 0=success, 1=no GPU, 2=unknown arch, 3=multiple archs
    # Side effects: Populates global arrays DETECTED_DEVICE_IDS, DETECTED_DEVICE_NAMES, DETECTED_GFX_ARCHS
    #               and sets DETECTED_GFX_RESULT global variable

    local detect_script="$INSTALLER_DIR/detect-gpu-gfx.sh"

    # Reset global arrays and result variable
    DETECTED_DEVICE_IDS=()
    DETECTED_DEVICE_NAMES=()
    DETECTED_GFX_ARCHS=()
    DETECTED_GFX_RESULT=""

    if [[ ! -x "$detect_script" ]]; then
        return 1
    fi

    # Use --output all --unique to get all fields in one call (tab-separated: name, device-id, revision, gfx)
    # The --unique flag deduplicates identical GPUs (e.g., 8x MI300 gfx94x → 1 entry)
    # The script now returns proper exit codes: 0=single arch, 1=no GPU, 2=unknown arch, 3=multiple archs
    local all_output
    all_output=$("$detect_script" --output all --unique 2>/dev/null)
    local exit_code=$?

    # Parse the tab-separated output and populate arrays (even on exit code 3)
    if [[ -n "$all_output" ]]; then
        while IFS=$'\t' read -r name device_id revision gfx; do
            DETECTED_DEVICE_NAMES+=("$name")
            DETECTED_DEVICE_IDS+=("$device_id")
            DETECTED_GFX_ARCHS+=("$gfx")
        done <<< "$all_output"
    fi

    # Set the result variable with the first detected GFX (if any)
    if [[ ${#DETECTED_GFX_ARCHS[@]} -gt 0 ]]; then
        DETECTED_GFX_RESULT="${DETECTED_GFX_ARCHS[0]}"
    fi

    return $exit_code
}

auto_detect_gfx() {
    # Auto-detect GFX architecture using detect-gpu-gfx.sh
    # Parameters: $1 = available_archs (space-separated string)
    # Sets INSTALL_GFX on success, exits on failure

    local available_archs="$1"

    echo "=============================================================="
    echo "GFX architecture not specified, attempting auto-detection..."
    echo "=============================================================="

    local detected_gfx=""
    local detect_exit_code=0

    # Detect hardware GFX architecture (sets DETECTED_GFX_RESULT and populates arrays)
    detect_hardware_gfx
    detect_exit_code=$?
    detected_gfx="$DETECTED_GFX_RESULT"

    # Handle detection failure cases
    if [[ $detect_exit_code -ne 0 && $detect_exit_code -ne 3 ]]; then
        echo ""
        case $detect_exit_code in
            1)
                # No GPU detected
                print_err "No AMD GPU detected."
                ;;
            2)
                # AMD GPU detected but unknown architecture
                print_err "AMD GPU detected but architecture is unknown or unsupported."
                ;;
            *)
                # Unknown error
                print_err "GPU detection failed (exit code: $detect_exit_code)."
                ;;
        esac

        echo "The gfx= argument is required."
        if [[ -n "$available_archs" ]]; then
            echo "Available architectures: $available_archs"
        fi
        exit 1
    fi

    # Show device information (for successful detections or multiple GPUs)
    # Device info was already populated by detect_hardware_gfx() in global arrays
    if [[ $detect_exit_code -eq 0 ]] || [[ $detect_exit_code -eq 3 ]]; then
        echo ""
        echo "Detected GPU(s):"

        for i in "${!DETECTED_DEVICE_IDS[@]}"; do
            local dev_id="${DETECTED_DEVICE_IDS[$i]}"
            local dev_name="${DETECTED_DEVICE_NAMES[$i]:-Unknown}"
            local gfx="${DETECTED_GFX_ARCHS[$i]:-unknown}"

            if [[ -n "$dev_name" && "$dev_name" != "Unknown AMD GPU" && "$dev_name" != "N/A" ]]; then
                echo "  GPU $((i+1)): $dev_name (Device: 0x$dev_id, GFX: $gfx)"
            else
                echo "  GPU $((i+1)): AMD GPU Device 0x$dev_id (GFX: $gfx)"
            fi
        done
        echo ""
    fi

    # Handle successful detection or multiple GPUs
    if [[ $detect_exit_code -eq 0 ]]; then
        # Successfully detected single architecture
        INSTALL_GFX="$detected_gfx"
        USER_SPECIFIED_GFX=0  # Mark as auto-detected, not user-specified
        echo "Auto-detected GFX architecture: $INSTALL_GFX"
        echo "=============================================================="
        echo ""

        # Prompt user to confirm auto-detected architecture
        if [[ $PROMPT_USER == 1 ]]; then
            prompt_user "Continue with auto-detected GFX architecture $INSTALL_GFX? (y/n): "
            if [[ "$option" == "N" || "$option" == "n" ]]; then
                echo ""
                if [[ -n "$available_archs" ]]; then
                    echo "To specify a different architecture, use:"
                    echo "  $PROG gfx=<arch> rocm"
                    echo ""
                    echo "Available architectures: $available_archs"
                fi
                exit 1
            fi
            echo ""
        fi
    elif [[ $detect_exit_code -eq 3 ]]; then
        # Multiple different architectures detected
        echo ""
        print_err "Multiple different GPU architectures detected: $detected_gfx"
        echo ""
        echo "This installer only supports installing for a single GPU architecture."
        echo "Please specify which architecture to install using the gfx= argument."
        echo ""
        echo "Detected architectures: $detected_gfx"
        echo ""
        echo "Example: $PROG gfx=${detected_gfx%%,*} rocm"
        exit 1
    fi
}

validate_gfx_arg() {
    # Validate gfx= argument or auto-detect
    # Sets INSTALL_GFX on success, exits on failure

    # Get available architectures (for validation)
    local available_archs
    read -r -a available_archs <<< "$(get_available_gfx_archs)"

    # Validate gfx= format and value if provided
    if [[ -n "$INSTALL_GFX" ]]; then
        # Check for multiple architectures (commas or spaces)
        if [[ "$INSTALL_GFX" == *,* ]] || [[ "$INSTALL_GFX" == *" "* ]]; then
            print_err "The gfx= argument must specify only ONE architecture."
            echo "Invalid: gfx=$INSTALL_GFX"
            echo "Example: gfx=gfx94x (not gfx=gfx94x,gfx950)"
            exit 1
        fi

        # Validate format: must start with "gfx" followed by alphanumeric
        if [[ ! "$INSTALL_GFX" =~ ^gfx[0-9a-z]+$ ]]; then
            print_err "Invalid gfx= format: $INSTALL_GFX"
            echo "The architecture must be in format: gfx<arch>"
            if [ ${#available_archs[@]} -gt 0 ]; then
                echo "Available architectures: ${available_archs[*]}"
            fi
            exit 1
        fi

        # Validate against available architectures in installer
        if [ ${#available_archs[@]} -gt 0 ]; then
            local valid_arch=0
            for arch in "${available_archs[@]}"; do
                if [[ "$INSTALL_GFX" == "$arch" ]]; then
                    valid_arch=1
                    break
                fi
            done

            if [ $valid_arch -eq 0 ]; then
                print_err "Architecture '$INSTALL_GFX' is not available in this installer."
                echo "Available architectures: ${available_archs[*]}"
                exit 1
            fi
        fi
    else
        # No gfx= arg provided, attempt auto-detection of GFX architecture
        auto_detect_gfx "${available_archs[*]}"
    fi
}

validate_compo_arg() {
    # Validate compo= argument for ROCm installation
    # Only validate when actually installing ROCm components (not deps-only)
    if [[ $ROCM_INSTALL == 1 && "$DEPS_ARG" != "install-only" ]]; then
        if [[ -n "$COMPO_INSTALL" ]]; then
            # Get available component categories
            local available_compos
            read -r -a available_compos <<< "$(get_available_components)"

            # Split comma-separated component list
            IFS=',' read -ra compo_list <<< "$COMPO_INSTALL"

            # Validate each component
            for compo_name in "${compo_list[@]}"; do
                # Trim whitespace using bash parameter expansion
                compo_name="${compo_name#"${compo_name%%[![:space:]]*}"}"  # Remove leading whitespace
                compo_name="${compo_name%"${compo_name##*[![:space:]]}"}"  # Remove trailing whitespace

                # Check if component is valid
                local valid_compo=0
                for valid in "${available_compos[@]}"; do
                    if [[ "$compo_name" == "$valid" ]]; then
                        valid_compo=1
                        break
                    fi
                done

                if [ $valid_compo -eq 0 ]; then
                    print_err "Component '$compo_name' is not available in this installer."
                    echo "Available components: ${available_compos[*]}"
                    exit 1
                fi
            done
        fi
    fi
}

validate_install_support() {
    # Validate installation support for special architectures (OEM kernel, etc.)
    # This function checks for architecture-specific restrictions based on DETECTED hardware

    # Determine which GFX architecture to check against OEM kernel list
    local detected_gfx=""

    if [[ $USER_SPECIFIED_GFX -eq 1 ]]; then
        # User specified gfx= argument - need to detect actual hardware to verify match
        detect_hardware_gfx
        detected_gfx="$DETECTED_GFX_RESULT"

        # If we can't detect hardware but user specified gfx=, warn and skip validation
        if [[ -z "$detected_gfx" ]]; then
            print_warning "Could not detect GPU hardware to verify gfx=$INSTALL_GFX."
            echo "Proceeding with user-specified architecture."
            echo ""
            return 0
        fi
    else
        # INSTALL_GFX was auto-detected, so it already matches hardware
        # No need to re-detect - just use INSTALL_GFX
        detected_gfx="$INSTALL_GFX"

        # If INSTALL_GFX is empty, skip validation
        if [[ -z "$detected_gfx" ]]; then
            return 0
        fi
    fi

    # Get list of OEM kernel supported architectures from metadata file
    local -a oem_kernel_archs=()
    local oem_archs_file="$INSTALLER_DIR/component-rocm/deps/oem-kernel-archs.txt"

    if [[ -f "$oem_archs_file" ]]; then
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            # Trim whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            oem_kernel_archs+=("$line")
        done < "$oem_archs_file"
    fi

    # Check if DETECTED hardware is an OEM kernel architecture
    local is_oem_kernel=0
    for arch in "${oem_kernel_archs[@]}"; do
        if [[ "$detected_gfx" == "$arch" ]]; then
            is_oem_kernel=1
            break
        fi
    done

    # Apply OEM kernel restrictions based on detected hardware
    if [[ $is_oem_kernel -eq 1 ]]; then
        # If user specified a different gfx= than what was detected, error out (unless force is used)
        if [[ -n "$INSTALL_GFX" && "$INSTALL_GFX" != "$detected_gfx" ]]; then
            if [[ $FORCE_INSTALL -eq 1 ]]; then
                print_warning "Architecture mismatch detected but force=1, proceeding anyway."
                echo "Detected GPU architecture: $detected_gfx (OEM kernel architecture)"
                echo "Specified gfx= argument: $INSTALL_GFX"
                echo ""
            else
                print_err "Architecture mismatch detected."
                echo "Detected GPU architecture: $detected_gfx (OEM kernel architecture)"
                echo "Specified gfx= argument: $INSTALL_GFX"
                echo ""
                echo "Cannot install ROCm for architecture '$INSTALL_GFX' on '$detected_gfx' hardware."
                echo "Please remove the gfx= argument to use auto-detected architecture."
                echo "Or use 'force' argument to override this check."
                exit 1
            fi
        fi

        # Check if not Ubuntu 24.04
        if [[ ! ("$DISTRO_NAME" == "ubuntu" && "$DISTRO_VER" == "24.04") ]]; then
            # Warn for ROCm installation
            if [[ $ROCM_INSTALL -eq 1 ]]; then
                echo ""
                echo "WARNING: GFX architecture '$detected_gfx' is only supported on Ubuntu 24.04."
                echo "Current OS: $DISTRO_NAME $DISTRO_VER"
                echo ""
                read -rp "Do you want to continue with the installation (y/n)? " option
                if [[ $option == "N" || $option == "n" ]]; then
                    echo "Installation cancelled."
                    exit 1
                fi
            fi
        fi

        # Block AMDGPU installation for OEM kernel architectures (always)
        if [[ $AMDGPU_INSTALL -eq 1 ]]; then
            print_err "AMDGPU driver installation is not supported for GFX architecture '$detected_gfx'."
            echo "This architecture uses the in-box driver included with the OS."
            echo ""
            echo "Please install ROCm only (without amdgpu driver) for this GPU."
            exit 1
        fi
    fi
}

dump_stats() {
    echo ----------------------------
    echo STATS
    echo -----

    echo "COMPONENT_COUNT = $COMPONENT_COUNT"
    echo "POSTINST_COUNT  = $POSTINST_COUNT"

    echo -----
    local stat_dir="$1/$INSTALLER_ROCM_VERSION_NAME"

    if [[ "$stat_dir" == //* ]]; then
        stat_dir="/${stat_dir#//}"
    fi

    echo "$stat_dir":
    echo ----------------------------
    echo "size:"
    echo "-----"
    local size_bytes
    size_bytes=$(du -sb "$stat_dir" | awk '{print $1}')

    format_size "$size_bytes"
    echo "$size_bytes bytes"
    echo "------"
    echo "types:"
    echo "------"
    echo "files = $(find "$stat_dir" -type f | wc -l)"
    echo "dirs  = $(find "$stat_dir" -type d | wc -l)"
    echo "links = $(find "$stat_dir" -type l | wc -l)"
    echo "        ------"
    echo "        $(find "$stat_dir" | wc -l)"
    echo ----------------------------
}

install_deps() {
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo -e "\e[96mINSTALL Dependencies : $DISTRO_NAME $DISTRO_VER\e[0m"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="

    echo Installing Dependencies...

    echo "DEPS_ARG = $DEPS_ARG"

    local status=0

    # select switch deps to be install (rocm/amdgpu)
    # Note: For graphics-only operations, deps_rocm and deps_amdgpu remain empty
    if [[ $ROCM_INSTALL == 1 ]]; then
        deps_rocm="rocm"
    fi

    if [[ $AMDGPU_INSTALL == 1 ]]; then
        deps_amdgpu="amdgpu"
    fi

    # check for verbose logging enable
    if [[ $VERBOSE == 1 ]]; then
        depOp="verbose "
    fi

    if [[ $PROMPT_USER == 1 ]]; then
        depOp+="prompt"
    fi

    # parse the dependency args
    if [[ $DEPS_ARG == "list" ]]; then

        echo Listing required dependencies

        # Build graphics flag for deps-installer
        local graphics_flag=""
        [[ $USE_GRAPHICS -eq 1 ]] && graphics_flag="graphics"

        ./deps-installer.sh "$deps_rocm" "$deps_amdgpu" $depOp gfx=$INSTALL_GFX $graphics_flag list
        status=$?

         if [[ status -ne 0 ]]; then
            print_err "Failed Dependencies list."
            exit 1
        fi

        exit 0

    elif [[ $DEPS_ARG == "validate" ]]; then

        echo Validating required dependencies

        # Build graphics flag for deps-installer
        local graphics_flag=""
        [[ $USE_GRAPHICS -eq 1 ]] && graphics_flag="graphics"

        ./deps-installer.sh "$deps_rocm" "$deps_amdgpu" $depOp gfx=$INSTALL_GFX $graphics_flag
        status=$?

        if [[ status -ne 0 ]]; then
            print_err "Failed Dependencies validation."
            exit 1
        fi

        exit 0

    elif [[ $DEPS_ARG == "install" ]] || [[ $DEPS_ARG == "install-only" ]]; then

        # Build graphics flag for deps-installer
        local graphics_flag=""
        [[ $USE_GRAPHICS -eq 1 ]] && graphics_flag="graphics"

       ./deps-installer.sh "$deps_rocm" "$deps_amdgpu" $depOp gfx=$INSTALL_GFX $graphics_flag install
        status=$?

        if [[ status -ne 0 ]]; then
            print_err "Failed Dependencies Install."
            exit 1
        fi

        if [[ $DEPS_ARG == "install-only" ]]; then
            echo Only dependencies installed.  Exiting.
            exit 0
        fi

    elif [[ $DEPS_ARG == "file" ]] || [[ $DEPS_ARG == "file-only" ]]; then

        ./deps-installer.sh install-file "$DEPS_ARG2" $depOp
        status=$?

        if [[ status -ne 0 ]]; then
            print_err "Failed Dependencies Install."
            exit 1
        fi

        if [[ $DEPS_ARG == "file-only" ]]; then
            echo Only dependencies installed.  Exiting.
            exit 0
        fi

    else
        print_err "Invalid dependencies argument."
        exit 1
    fi

    echo Installing Dependencies...Complete.
}

list_components() {
    local gfx_filter="$1"
    local component_files=()

    echo "================================================================================"

    if [ -n "$gfx_filter" ]; then
        # Filter by specific gfx tag or base
        echo "ROCm Components (${gfx_filter})"
        echo "================================================================================"

        if [ "$gfx_filter" = "base" ]; then
            # Show base only
            component_files=("$EXTRACT_ROCM_DIR/deps/base/$COMPO_VER_FILE")
        else
            # Show base + specific gfx tag
            component_files=(
                "$EXTRACT_ROCM_DIR/deps/base/$COMPO_VER_FILE"
                "$EXTRACT_ROCM_DIR/deps/${gfx_filter}/$COMPO_VER_FILE"
            )
        fi
    else
        # Show all components (combined file)
        echo "ROCm Components (All)"
        echo "================================================================================"

        # Use combined component-versions.txt if it exists, otherwise show all individual files
        if [ -f "$EXTRACT_ROCM_DIR/deps/$COMPO_VER_FILE" ]; then
            component_files=("$EXTRACT_ROCM_DIR/deps/$COMPO_VER_FILE")
        else
            # Fallback: combine base + all gfx tags
            component_files=("$EXTRACT_ROCM_DIR/deps/base/$COMPO_VER_FILE")
            for gfx_dir in "$EXTRACT_ROCM_DIR/deps"/gfx*; do
                if [ -d "$gfx_dir" ] && [ -f "$gfx_dir/$COMPO_VER_FILE" ]; then
                    component_files+=("$gfx_dir/$COMPO_VER_FILE")
                fi
            done
        fi
    fi

    # Display components with nice formatting
    printf "%-50s %s\n" "Component Name" "Version"
    printf "%-50s %s\n" "----------------" "-------"

    local components_found=0
    for comp_file in "${component_files[@]}"; do
        if [ -f "$comp_file" ]; then
            while IFS= read -r line; do
                # Skip empty lines
                [[ -z "$line" ]] && continue

                # Parse: "amdrocm-base7.13 = 7.13.0~20260415"
                if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
                    local comp_name="${BASH_REMATCH[1]}"
                    local comp_version="${BASH_REMATCH[2]}"
                    # Trim whitespace
                    comp_name=$(echo "$comp_name" | xargs)
                    comp_version=$(echo "$comp_version" | xargs)
                    printf "%-50s %s\n" "$comp_name" "$comp_version"
                    components_found=1
                fi
            done < "$comp_file"
        else
            if [ -n "$gfx_filter" ]; then
                print_err "Components list not found: $comp_file"
                exit 1
            fi
        fi
    done

    if [ $components_found -eq 0 ]; then
        echo "No components found."
    fi

    echo "================================================================================"
    exit 0
}

set_prefix_scriptlet() {
    local rocm_ver_dir=$1

    # Set the PREFIX variable for extracted scriptlets (both RPM and DEB)
    # The scriptlets use RPM_INSTALL_PREFIX0 regardless of package format
    if [[ -n $rocm_ver_dir ]]; then
        echo "Setting PREFIX0 = $rocm_ver_dir"
        export RPM_INSTALL_PREFIX0="$rocm_ver_dir"

        # Note: Environment variables are passed explicitly to scriptlets,
        # so sudo -E is not needed (and is rejected by Ubuntu 26.04+)
        if [[ -n $SUDO_OPTS ]]; then
            SUDO_OPTS="$SUDO"
        fi
        echo SUDO_OPTS = "$SUDO_OPTS"
    fi
}

remove_rocm_symlinks() {
    # Remove common update-alternatives symlinks in /opt/rocm parent directory
    # Args: $1 = ROCm parent directory (e.g., /opt/rocm)
    local rocm_parent="$1"

    if [[ ! -d "$rocm_parent" ]]; then
        return 0
    fi

    # Remove common symlinks created by update-alternatives
    for link in core core-7 bin lib include llvm amdgcn libexec share; do
        if [[ -L "$rocm_parent/$link" ]]; then
            echo "Removing symlink: $rocm_parent/$link"
            $SUDO rm -f "$rocm_parent/$link"
        fi
    done
}

configure_scriptlet() {
    print_str "Configuring scriptlet."

    local scriptlet
    scriptlet=$(cat "$1")

    local rocm_default="/opt"
    local rocm_reloc="$TARGET_DIR"
    local postinst_reloc="$1-reloc"

    echo "config: $rocm_reloc"

    if echo "$scriptlet" | grep -q '/opt'; then
         print_str "/opt detected -> $rocm_reloc"
    fi

    print_str "Using scriptlet: $1"

    sed "s|$rocm_default|$rocm_reloc|g" "$1" > "$postinst_reloc"
    $SUDO chmod +x "$postinst_reloc"
}

install_postinst_scriptlet() {
    local component=$1
    local extract_dir=${2:-"$EXTRACT_DIR"}

    local gfx_tag
    gfx_tag=$(basename "$extract_dir")

    local postinst_scriptlet="$EXTRACT_ROCM_DIR/scriptlets/$gfx_tag/$component/postinst"

    # execute post install with arg "configure" or "1"
    if [[ -s "$postinst_scriptlet" ]]; then
        echo --------------------------------
        echo -e "\e[92mExecuting post install script for $component...\e[0m"

        if [[ $VERBOSE == 1 ]]; then
            cat "$postinst_scriptlet"
        fi

        if [[ ! $TARGET_DIR == "/" ]]; then
            print_str "Running Reloc."
            configure_scriptlet "$postinst_scriptlet"
            $SUDO_OPTS env RPM_INSTALL_PREFIX0="$RPM_INSTALL_PREFIX0" bash "$postinst_scriptlet-reloc" "$INSTALL_SCRIPTLET_ARG"
        else
            $SUDO_OPTS env RPM_INSTALL_PREFIX0="$RPM_INSTALL_PREFIX0" bash "$postinst_scriptlet" "$INSTALL_SCRIPTLET_ARG"
        fi

        echo -e "\e[92mComplete: $?\e[0m"

        POSTINST_COUNT=$((POSTINST_COUNT+1))
    fi
}

uninstall_prerm_scriptlet() {
    local component=$1
    local extract_dir=${2:-"$EXTRACT_DIR"}

    local gfx_tag
    gfx_tag=$(basename "$extract_dir")

    local prerm_scriptlet="$EXTRACT_ROCM_DIR/scriptlets/$gfx_tag/$component/prerm"

    # execute pre-install with arg "remove" or "0"
    if [[ -s "$prerm_scriptlet" ]]; then
        echo --------------------------------
        echo -e "\e[92mExecuting prerm script for $component...\e[0m"

        if [[ $VERBOSE == 1 ]]; then
            cat "$prerm_scriptlet"
        fi

        if [[ ! $TARGET_DIR == "/" ]]; then
            print_str "echo Running Reloc."
            configure_scriptlet "$prerm_scriptlet"
            $SUDO_OPTS env RPM_INSTALL_PREFIX0="$RPM_INSTALL_PREFIX0" bash "$prerm_scriptlet-reloc" "$UNINSTALL_SCRIPTLET_ARG"
        else
            $SUDO_OPTS env RPM_INSTALL_PREFIX0="$RPM_INSTALL_PREFIX0" bash "$prerm_scriptlet" "$UNINSTALL_SCRIPTLET_ARG"
        fi

        echo -e "\e[92mComplete: $?\e[0m"

        PRERM_COUNT=$((PRERM_COUNT+1))
    fi
}

uninstall_postrm_scriptlet() {
    local component=$1
    local extract_dir=${2:-"$EXTRACT_DIR"}

    local gfx_tag
    gfx_tag=$(basename "$extract_dir")

    local postrm_scriptlet="$EXTRACT_ROCM_DIR/scriptlets/$gfx_tag/$component/postrm"

    # execute post uninstall with arg "remove" or "0"
    if [[ -s "$postrm_scriptlet" ]]; then
        echo --------------------------------
        echo -e "\e[92mExecuting postrm script for $component...\e[0m"

        if [[ $VERBOSE == 1 ]]; then
            cat "$postrm_scriptlet"
        fi

        if [[ ! $TARGET_DIR == "/" ]]; then
            print_str "echo Running Reloc."
            configure_scriptlet "$postrm_scriptlet"
            $SUDO_OPTS env RPM_INSTALL_PREFIX0="$RPM_INSTALL_PREFIX0" bash "$postrm_scriptlet-reloc" "$UNINSTALL_SCRIPTLET_ARG"
        else
            $SUDO_OPTS env RPM_INSTALL_PREFIX0="$RPM_INSTALL_PREFIX0" bash "$postrm_scriptlet" "$UNINSTALL_SCRIPTLET_ARG"
        fi

        echo -e "\e[92mComplete: $?\e[0m"

        POSTRM_COUNT=$((POSTRM_COUNT+1))
    fi
}

detect_installed_base_components() {
    # Auto-detect which base ROCm components are actually installed at the target
    # Only identifies components that have files in the installation
    #
    # Args:
    #   $1 - ROCm installation directory to check (e.g., /opt/rocm/core-7.11)
    #
    # Returns:
    #   Sets global COMPONENTS variable with space-separated list of installed packages

    local rocm_install_dir="$1"

    COMPONENTS=""

    echo "--------------------------------"
    echo "Auto-detecting installed base components..."

    local deps_base_dir="$EXTRACT_ROCM_DIR/deps/base"

    # Check each base package using signature files
    for pkg_dir in "$deps_base_dir"/*; do
        if [ -d "$pkg_dir" ]; then
            local pkg_name
            pkg_name=$(basename "$pkg_dir")
            local signature_file="$pkg_dir/$SIGNATURE_FILE"

            # Check if signature file exists
            if [ ! -f "$signature_file" ]; then
                # No signature file, skip this package
                continue
            fi

            # Read signature files and check how many exist in the installation
            local total_sigs=0
            local found_sigs=0
            local is_meta_package=0

            while IFS= read -r sig_file; do
                # Skip empty lines
                [ -z "$sig_file" ] && continue

                # Check for meta package marker
                if [ "$sig_file" = "META_PACKAGE_WITH_SCRIPTLETS" ]; then
                    is_meta_package=1
                    total_sigs=1
                    found_sigs=1
                    break
                fi

                total_sigs=$((total_sigs + 1))

                # Strip the rocm/core-X.XX/ prefix to get actual install path
                local rel_path="${sig_file#"${INSTALLER_ROCM_VERSION_NAME}"/}"

                # Check if file exists in the installation
                if [ -f "$rocm_install_dir/$rel_path" ] || [ -L "$rocm_install_dir/$rel_path" ]; then
                    found_sigs=$((found_sigs + 1))
                fi
            done < "$signature_file"

            # Consider package installed if 60% or more signature files exist
            # Minimum of 3 files for packages with 5+ signatures
            # Meta packages are always considered installed if marked
            if [ $total_sigs -gt 0 ]; then
                local threshold=$((total_sigs * 6 / 10))  # 60%
                if [ $threshold -lt 3 ] && [ $total_sigs -ge 5 ]; then
                    threshold=3
                fi

                if [ $found_sigs -ge $threshold ]; then
                    if [ $is_meta_package -eq 1 ]; then
                        echo "Detected installed component: $pkg_name (meta package with scriptlets)"
                    else
                        echo "Detected installed component: $pkg_name ($found_sigs/$total_sigs signature files found)"
                    fi
                    COMPONENTS="$COMPONENTS $pkg_name"
                fi
            fi
        fi
    done

    if [ -n "$COMPONENTS" ]; then
        echo -e "\e[32mFound $(echo "$COMPONENTS" | wc -w) installed base component(s)\e[0m"
    else
        echo "No installed base components detected"
    fi
    echo "--------------------------------"
}

detect_installed_gfx_architectures() {
    # Auto-detect which GFX architectures are actually installed at the target
    # Only identifies GFX architectures that have files in the installation
    #
    # Args:
    #   $1 - ROCm installation directory to check (e.g., /opt/rocm/core-7.11)
    #
    # Returns:
    #   Sets global array: gfx_dirs - array of extraction directories for detected GFX architectures

    local rocm_install_dir="$1"

    gfx_dirs=()

    echo "--------------------------------"
    echo "Auto-detecting installed GFX architectures..."

    # Use deps directory to find available GFX architectures
    local search_dir="$EXTRACT_ROCM_DIR/deps"

    for gfx_dir in "$search_dir"/gfx*/; do
        if [ -d "$gfx_dir" ]; then
            local gfx_arch
            gfx_arch=$(basename "$gfx_dir")
            gfx_arch=${gfx_arch#gfx}

            # Check if this GFX architecture is actually installed at the target
            # Look for GFX-specific files (libraries/kernels with gfx identifier)
            # Extract the numeric part (e.g., "94" from "94x", "1150" from "1150")
            local gfx_pattern="${gfx_arch%x}"  # Remove trailing 'x' if present

            # Search for files with this GFX pattern in the target installation
            local gfx_files_found=0
            if [ -d "$rocm_install_dir/lib" ]; then
                # Look for GFX-specific files (typically .co, .dat, .so files with gfx in name)
                if find "$rocm_install_dir/lib" -type f \( -name "*gfx${gfx_pattern}*" -o -name "*gfx_${gfx_pattern}*" \) 2>/dev/null | head -1 | grep -q .; then
                    gfx_files_found=1
                fi
            fi

            if [ $gfx_files_found -eq 1 ]; then
                echo -e "Detected installed GFX architecture: \e[32mgfx${gfx_arch}\e[0m"
                gfx_dirs+=("$gfx_dir")
            fi
        fi
    done

    if [ ${#gfx_dirs[@]} -gt 0 ]; then
        echo -e "\e[32mFound ${#gfx_dirs[@]} installed GFX architecture(s)\e[0m"
    else
        echo "No installed GFX architectures detected"
    fi
    echo "--------------------------------"
}

detect_installed_gfx_components() {
    # Detect which GFX components are installed for each detected GFX architecture
    #
    # Args:
    #   $1 - ROCm installation directory to check (e.g., /opt/rocm/core-7.11)
    #
    # Returns:
    #   Sets global array: gfx_components - array of "components|extract_dir" entries

    local rocm_install_dir="$1"

    gfx_components=()

    echo "--------------------------------"
    echo "Auto-detecting installed GFX components..."

    for gfx_dir in "${gfx_dirs[@]}"; do
        local gfx_arch
        gfx_arch=$(basename "$gfx_dir")
        echo "Checking components for $gfx_arch..."

        # Get the corresponding deps directory for this GFX architecture
        local deps_gfx_dir="$EXTRACT_ROCM_DIR/deps/$gfx_arch"

        # Detect which GFX packages are actually installed using signature files
        local gfx_comps=""
        if [ -d "$deps_gfx_dir" ]; then
            for pkg_dir in "$deps_gfx_dir"/*; do
                if [ -d "$pkg_dir" ]; then
                    local pkg_name
                    pkg_name=$(basename "$pkg_dir")
                    local signature_file="$pkg_dir/$SIGNATURE_FILE"

                    # Check if signature file exists
                    if [ ! -f "$signature_file" ]; then
                        # No signature file, skip this package
                        continue
                    fi

                    # Read signature files and check how many exist in the installation
                    local total_sigs=0
                    local found_sigs=0
                    local is_meta_package=0

                    while IFS= read -r sig_file; do
                        # Skip empty lines
                        [ -z "$sig_file" ] && continue

                        # Check for meta package marker
                        if [ "$sig_file" = "META_PACKAGE_WITH_SCRIPTLETS" ]; then
                            is_meta_package=1
                            total_sigs=1
                            found_sigs=1
                            break
                        fi

                        total_sigs=$((total_sigs + 1))

                        # Strip the rocm/core-X.XX/ prefix to get actual install path
                        local rel_path="${sig_file#"${INSTALLER_ROCM_VERSION_NAME}"/}"

                        # Check if file exists in the installation
                        if [ -f "$rocm_install_dir/$rel_path" ] || [ -L "$rocm_install_dir/$rel_path" ]; then
                            found_sigs=$((found_sigs + 1))
                        fi
                    done < "$signature_file"

                    # Consider package installed if 60% or more signature files exist
                    # Minimum of 3 files for packages with 5+ signatures
                    # Meta packages are always considered installed if marked
                    if [ $total_sigs -gt 0 ]; then
                        local threshold=$((total_sigs * 6 / 10))  # 60%
                        if [ $threshold -lt 3 ] && [ $total_sigs -ge 5 ]; then
                            threshold=3
                        fi

                        if [ $found_sigs -ge $threshold ]; then
                            if [ $is_meta_package -eq 1 ]; then
                                echo "  Detected: $pkg_name (meta package with scriptlets)"
                            else
                                echo "  Detected: $pkg_name ($found_sigs/$total_sigs signature files found)"
                            fi
                            gfx_comps="$gfx_comps $pkg_name"
                        fi
                    fi
                fi
            done
        fi

        if [ -n "$gfx_comps" ]; then
            gfx_components+=("$gfx_comps|$gfx_dir")
        fi
    done

    if [ ${#gfx_components[@]} -gt 0 ]; then
        echo -e "\e[32mFound GFX components in ${#gfx_components[@]} architecture(s)\e[0m"
    else
        echo "No GFX components detected"
    fi
    echo "--------------------------------"
}

detect_meta_packages() {
    # Infer which meta package was used by matching installed components against meta configs
    # This identifies meta packages (like amdrocm-core) that have scriptlets but no content files
    #
    # Returns:
    #   Updates COMPONENTS (for base) and gfx_components array (for GFX)

    echo "--------------------------------"
    echo "Detecting meta packages with scriptlets..."

    # Combine base and GFX components into one list for matching
    local all_installed_components="$COMPONENTS"
    for entry in "${gfx_components[@]}"; do
        local gfx_comps="${entry%|*}"
        all_installed_components="$all_installed_components $gfx_comps"
    done

    # Check each meta package config to see if it matches installed components
    for meta_config in "$EXTRACT_ROCM_DIR/deps/meta"/*.config; do
        if [ ! -f "$meta_config" ]; then
            continue
        fi

        local meta_name
        meta_name=$(basename "$meta_config" .config)
        meta_name=${meta_name%-meta}

        # Skip if meta package is already in detected components
        if echo " $all_installed_components " | grep -q " $meta_name "; then
            continue
        fi

        # Read the components listed in this meta package config
        local meta_components=""
        while IFS= read -r component; do
            # Skip empty lines
            [ -z "$component" ] && continue
            meta_components="$meta_components $component"
        done < "$meta_config"

        # Check if all components from the config are installed
        # AND check if the meta package itself was actually installed at the target
        local all_matched=1
        local meta_package_installed=0

        for component in $meta_components; do
            # Check if the meta package component itself was installed
            if [ "$component" = "$meta_name" ]; then
                # Determine the GFX arch for lookup
                local check_gfx=""
                if [[ "$meta_name" =~ (gfx[0-9]+x?) ]]; then
                    check_gfx="${BASH_REMATCH[1]}"
                else
                    check_gfx="base"
                fi

                local meta_sig_file="$EXTRACT_ROCM_DIR/deps/$check_gfx/$meta_name/$SIGNATURE_FILE"

                # Check if the meta package was actually installed by verifying its signature files
                if [ -f "$meta_sig_file" ]; then
                    local total_meta_sigs=0
                    local found_meta_sigs=0

                    while IFS= read -r sig_file; do
                        [ -z "$sig_file" ] && continue

                        # Check for meta package marker
                        if [ "$sig_file" = "META_PACKAGE_WITH_SCRIPTLETS" ]; then
                            # Meta package with scriptlets, always consider installed if we got here
                            meta_package_installed=1
                            break
                        fi

                        total_meta_sigs=$((total_meta_sigs + 1))
                        local rel_path="${sig_file#"${INSTALLER_ROCM_VERSION_NAME}"/}"

                        if [ -f "$rocm_install_dir/$rel_path" ] || [ -L "$rocm_install_dir/$rel_path" ]; then
                            found_meta_sigs=$((found_meta_sigs + 1))
                        fi
                    done < "$meta_sig_file"

                    # Meta package is installed if 60% of its signature files are present
                    if [ $total_meta_sigs -gt 0 ]; then
                        local threshold=$((total_meta_sigs * 6 / 10))
                        if [ $threshold -lt 3 ] && [ $total_meta_sigs -ge 5 ]; then
                            threshold=3
                        fi
                        if [ $found_meta_sigs -ge $threshold ]; then
                            meta_package_installed=1
                        fi
                    fi
                fi
                continue
            fi

            # Check if this component is in our installed list
            if ! echo " $all_installed_components " | grep -q " $component "; then
                all_matched=0
                break
            fi
        done

        # Only add meta package if:
        # 1. All its components are installed, AND
        # 2. The meta package itself was actually installed at the target
        if [ $all_matched -eq 1 ] && [ $meta_package_installed -eq 1 ] && [ -n "$meta_components" ]; then
            # Determine if this is a base or GFX meta package
            if echo "$meta_name" | grep -q "gfx"; then
                # GFX meta package - extract GFX arch and add to appropriate entry
                local gfx_arch_pattern
                if [[ "$meta_name" =~ (gfx[0-9]+x?) ]]; then
                    gfx_arch_pattern="${BASH_REMATCH[1]}"

                    # Add to the appropriate GFX component list
                    local updated_gfx_components=()
                    for entry in "${gfx_components[@]}"; do
                        local comps="${entry%|*}"
                        local gfx_extract_dir="${entry#*|}"

                        local gfx_arch
                        gfx_arch=$(basename "$gfx_extract_dir")

                        if [ "$gfx_arch" = "$gfx_arch_pattern" ]; then
                            echo "  Adding GFX meta package: $meta_name (inferred from installed components)"
                            comps="$comps $meta_name"
                        fi
                        updated_gfx_components+=("$comps|$gfx_extract_dir")
                    done
                    gfx_components=("${updated_gfx_components[@]}")
                fi
            else
                # Base meta package
                echo "  Adding base meta package: $meta_name (inferred from installed components)"
                COMPONENTS="$COMPONENTS $meta_name"
            fi
        fi
    done

    # Fallback: Check GFX directories for meta packages with scriptlets that weren't matched
    local updated_gfx_components=()
    for entry in "${gfx_components[@]}"; do
        local comps="${entry%|*}"
        local gfx_extract_dir="${entry#*|}"
        local gfx_arch
        gfx_arch=$(basename "$gfx_extract_dir")

        # Look for packages with scriptlets but no content in this GFX arch
        for pkg_dir in "$EXTRACT_ROCM_DIR/deps/$gfx_arch"/*; do
            if [ ! -d "$pkg_dir" ]; then
                continue
            fi

            local pkg_name
            pkg_name=$(basename "$pkg_dir")

            # Skip if already in the component list
            if echo " $comps " | grep -q " $pkg_name "; then
                continue
            fi

            # Check if this package has removal scriptlets (prerm or postrm)
            local scriptlet_dir="$EXTRACT_ROCM_DIR/scriptlets/$gfx_arch/$pkg_name"
            if [ -d "$scriptlet_dir" ]; then
                if [ -s "$scriptlet_dir/prerm.sh" ] || [ -s "$scriptlet_dir/postrm.sh" ] || \
                   [ -s "$scriptlet_dir/prerm" ] || [ -s "$scriptlet_dir/postrm" ] || \
                   [ -s "$scriptlet_dir/preuninstall.sh" ] || [ -s "$scriptlet_dir/postuninstall.sh" ]; then
                    # Package has removal scriptlets, add it
                    echo "  Adding $gfx_arch meta package: $pkg_name (has scriptlets)"
                    comps="$comps $pkg_name"
                fi
            fi
        done

        # Update the array entry with the new component list
        updated_gfx_components+=("$comps|$gfx_extract_dir")
    done
    gfx_components=("${updated_gfx_components[@]}")

    echo "Meta package detection complete"
    echo "--------------------------------"
}

install_rocm_component() {
    echo --------------------------------

    local component=$1
    local extract_dir=${2:-"$EXTRACT_DIR"}

    local gfx_tag
    gfx_tag=$(basename "$extract_dir")

    local content_dir="$EXTRACT_ROCM_DIR/content/$gfx_tag/$component"

    echo Copying content component: "$component"...

    if [[ -n $INSTALLED_PKGS ]]; then
        local matches
        matches=$(echo "$INSTALLED_PKGS" | grep -E "^($component)/")
        if [[ -n $matches ]]; then
            print_warning "Package installation of ROCm package: $component"
            echo "$matches"
            read -rp "Overwrite package install of $compo (y/n): " option
            if [[ $option == "Y" || $option == "y" ]]; then
                echo "Proceeding with install..."
                # Copy the component content/data to the target location
                if ! $SUDO rsync $RSYNC_OPTS_ROCM "$content_dir/." "$TARGET_DIR/"; then
                    print_err "rsync error."
                    exit 1
                fi
                COMPONENT_COUNT=$((COMPONENT_COUNT+1))
            else
                echo "Skipping $component install."
            fi
        fi
    else
        # Copy the component content/data to the target location
        if ! $SUDO rsync $RSYNC_OPTS_ROCM "$content_dir/." "$TARGET_DIR/"; then
            print_err "rsync error."
            exit 1
        fi
        COMPONENT_COUNT=$((COMPONENT_COUNT+1))
    fi

    echo Copying content component: "$component"...Complete.
}

install_base_components() {
    # Install base ROCm components from component-rocm/base
    # Re-installs on every call to handle upgrades (e.g., core → core-sdk)
    # rsync overwrites ensure identical files are handled efficiently

    if is_base_installed; then
        echo "Re-installing/upgrading base ROCm packages..."
    else
        echo "Installing base ROCm packages..."
    fi

    for compo in $COMPONENTS; do
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        echo -e "\e[32mInstalling base component: $compo\e[0m"
        install_rocm_component "$compo" "$EXTRACT_ROCM_DIR/base"
        add_component_to_manifest "base" "$compo" "base"
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    done

    # Mark base as installed
    mark_base_installed
}

install_gfx_components() {
    # Install GFX-specific components from component-rocm/gfxXYZ if specified
    if [[ -n $INSTALL_GFX ]]; then
        local gfx_extract_dir="$EXTRACT_ROCM_DIR/${INSTALL_GFX}"
        for compo in $COMPONENTS_GFX; do
            echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
            echo -e "\e[32mInstalling GFX component (${INSTALL_GFX}): $compo\e[0m"
            install_rocm_component "$compo" "$gfx_extract_dir"
            add_component_to_manifest "gfx" "$compo" "$INSTALL_GFX"
            echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        done

        # Mark GFX architecture as installed (for multi-GFX support)
        mark_gfx_installed "$INSTALL_GFX"
    fi
}

install_rocm_multi_gfx() {
    # Install multiple GFX architectures with shared base packages
    # Args: $@ = Array of GFX architectures

    local -a gfx_list=("$@")

    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo -e "\e[96mMulti-GFX Installation\e[0m"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo "Installing ROCm for ${#gfx_list[@]} GFX architecture(s): ${gfx_list[*]}"
    echo ""

    # Step 1: Extract needed archives (deduplicated by family)
    if ! extract_gfx_archives_for_list "${gfx_list[@]}"; then
        print_err "Failed to extract GFX archives"
        return 1
    fi

    # Step 2: Install base packages (if not already installed)
    echo ""
    install_base_components

    # Step 3: Install each GFX arch
    for gfx in "${gfx_list[@]}"; do
        echo ""

        if is_gfx_installed "$gfx"; then
            echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
            echo -e "\e[33mRe-installing/upgrading GFX architecture: $gfx\e[0m"
            echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
        else
            echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
            echo -e "\e[32mInstalling GFX architecture: $gfx\e[0m"
            echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
        fi

        # Set INSTALL_GFX for install_gfx_components
        INSTALL_GFX="$gfx"

        # Read GFX meta config to populate COMPONENTS_GFX for this architecture
        COMPONENTS_GFX=""
        local meta_base="amdrocm-${COMPO_INSTALL}${ROCM_VER}"
        local gfx_meta_file="$COMPO_META_DIR/${meta_base}-${gfx}-meta.config"

        if [[ -f "$gfx_meta_file" ]]; then
            while IFS= read -r pkg; do
                # Split packages between base and gfx directories
                if [[ -d "$EXTRACT_ROCM_DIR/content/${gfx}/$pkg" ]] || [[ -d "$EXTRACT_ROCM_DIR/scriptlets/${gfx}/$pkg" ]]; then
                    # Package is in gfx directory
                    if [[ ! " $COMPONENTS_GFX " =~ \ $pkg\  ]]; then
                        COMPONENTS_GFX="$COMPONENTS_GFX $pkg"
                    fi
                fi
            done < "$gfx_meta_file"

            # Trim whitespace
            COMPONENTS_GFX="${COMPONENTS_GFX#"${COMPONENTS_GFX%%[![:space:]]*}"}"
            COMPONENTS_GFX="${COMPONENTS_GFX%"${COMPONENTS_GFX##*[![:space:]]}"}"
        fi

        # Install GFX-specific components
        install_gfx_components

        # Mark as installed
        mark_gfx_installed "$gfx"
    done

    echo ""
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo -e "\e[32mMulti-GFX installation complete\e[0m"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="

    # Show installed summary
    local installed_gfx
    installed_gfx=$(get_installed_gfx_archs)
    echo "Installed GFX architectures: $installed_gfx"
}

draw_progress_bar() {
    local progress=$1
    local width=50
    local filled=$((progress * width / 100))
    local empty=$((width - filled + 1))
    if [[ $NCURSES_BAR = 1 ]]; then
        tput sc
        tput el
        printf "%0.s▇" $(seq 1 $filled)
        printf "%0.s " $(seq 1 $empty)
        tput rc
    else
        printf "\r "
        printf "%0.s#" $(seq 1 $filled)
        printf "%0.s " $(seq 1 $empty)
    fi
}

check_rocm_package_install_therock() {
    # Check for theROCK package format (amdrocm-core7.13-gfxXYZ)
    local rocm_loc=$1
    local ret=0

    # Package install only for /opt installs
    if [[ "$TARGET_DIR" == "/opt" || "$rocm_loc" == "/opt/rocm"* ]]; then
        local rocm_ver_name
        rocm_ver_name=$(basename "$rocm_loc")
        # Strip both "rocm-" and "core-" prefixes to get version number
        local rocm_ver=${rocm_ver_name#rocm-}
        rocm_ver=${rocm_ver#core-}

        # Check for theROCK package format: amdrocm-core<version>-gfx<arch>
        # Examples: amdrocm-core7.13-gfx950, amdrocm-base7.13
        # Use exit code to determine if packages exist (0=found, 1=not found)
        if $PKG_INSTALLED_CMD 2>&1 | grep -q -E "amdrocm-core${rocm_ver}(-gfx|$)"; then
            echo "amdrocm-core package detected (theRock): ${rocm_ver}"

            # cached the installed packages
            INSTALLED_PKGS=$($PKG_INSTALLED_CMD 2>&1)
            ret=1
        fi

        if [[ $FORCE_INSTALL == 1 ]]; then
            echo Force install for package-based install.
            INSTALLED_PKGS=
        fi
    fi

    return $ret
}

check_rocm_package_install_legacy() {
    # Check for legacy package format (rocm-core, rocm-dev, etc.)
    local rocm_loc=$1
    local ret=0

    # Package install only for /opt installs
    if [[ "$TARGET_DIR" == "/opt" || "$rocm_loc" == "/opt/rocm"* ]]; then
        # check for a rocm-core package and if it matches the version of rocm being installed
        local rocm_ver_name
        rocm_ver_name=$(basename "$rocm_loc")
        # Strip both "rocm-" and "core-" prefixes to get version number
        local rocm_ver=${rocm_ver_name#rocm-}
        rocm_ver=${rocm_ver#core-}

        IFS='.' read -r x y z <<< "$rocm_ver"
        local rocm_core_ver
        # Default z to 0 if not set (handles versions like 7.13 without patch)
        rocm_core_ver=$(printf "%d%02d%02d" "$x" "$y" "${z:-0}")

        # Use exit code to determine if packages exist (0=found, 1=not found)
        if $PKG_INSTALLED_CMD 2>&1 | grep -q "rocm-core" | grep -q "$rocm_core_ver"; then
            echo "rocm-core package detected (legacy): $rocm_core_ver"

            # cached the installed packages
            INSTALLED_PKGS=$($PKG_INSTALLED_CMD 2>&1)
            ret=1
        fi

        if [[ $FORCE_INSTALL == 1 ]]; then
            echo Force install for package-based install.
            INSTALLED_PKGS=
        fi
    fi

    return $ret
}

check_rocm_package_install() {
    # Wrapper function that checks both theROCK and legacy package formats
    # Returns 1 if package manager install detected, 0 otherwise
    local rocm_loc=$1

    # Try theROCK format first (newer)
    check_rocm_package_install_therock "$rocm_loc"
    local therock_ret=$?
    if [[ $therock_ret -eq 1 ]]; then
        return 1  # Package found
    fi

    # Fall back to legacy format
    check_rocm_package_install_legacy "$rocm_loc"
    local legacy_ret=$?
    if [[ $legacy_ret -eq 1 ]]; then
        return 1  # Package found
    fi

    return 0  # No packages found
}

find_rocm_with_progress() {
    ROCM_DIR=

    local rocm_find_base=
    local rocm_version_dir=""
    local rocm_depth=

    local find_opt=$1
    local found=1
    local progress=0
    local temp_file
    temp_file=$(mktemp)

    # optimize the search based on if the target arg is set or "all" option
    if [[ "$find_opt" == "all" ]]; then
        echo Using no target.
        rocm_find_base="/"
    else
        echo Using target argument.
        rocm_depth="-maxdepth 4"
        rocm_find_base="$TARGET_DIR"
    fi

    # Look for the rocm install directory
    echo "Looking for ROCm at: $rocm_find_base"

    # Start the find command in the background
    # Use regex to match only paths ending in /rocm/core-* (not subdirectories)
    find "$rocm_find_base" $rocm_depth -type d -regex '.*/rocm/core-[^/]*$' ! -path '*/rocm-installer/component-rocm/*' ! -path '*/component-rocm/base/*/rocm/core-*' ! -path '*/component-rocm/gfx*/*/rocm/core-*' -print 2>/dev/null > "$temp_file" &
    local find_pid=$!

    # Update the progress bar while the find command is running
    while kill -0 "$find_pid" 2>/dev/null; do
        draw_progress_bar $progress
        progress=$((progress + 10))
        if [[ $progress -ge 100 ]]; then
            progress=0
        fi
        sleep 0.1
    done

    # Wait for the find command to complete
    wait "$find_pid"

    # Draw the final progress bar
    draw_progress_bar 100
    echo

    # Read the output from the temporary file into the variable
    rocm_version_dir=$(cat "$temp_file")

    # Check if the version directory was found and set the rocm directory path
    if [ -n "$rocm_version_dir" ]; then
        echo "ROCm detected in target $rocm_find_base"

        ROCM_DIR="$rocm_version_dir"
        echo "ROCm Install Directory found."

        # check if the path is root at the default /opt/rocm*
        if [[ "$ROCM_DIR" == /opt/rocm* ]]; then
            echo ROCm Default Root path.
        fi

        # list any rocm install paths
        ROCM_INSTALLS=
        echo "ROCm Installation/s:"
        while IFS= read -r rocm_inst; do
            echo "    $rocm_inst"
            ROCM_INSTALLS+="${rocm_inst},"
        done < <(sort -V "$temp_file")

        found=0
    fi

    if [ -f "$temp_file" ]; then
        rm "$temp_file"
    fi

    return $found
}

prereq_installer_check() {
    local not_install=""

    # Check if the require packages are installed on the system for installer to function
    for pkg in "${INSTALLER_DEPS[@]}"; do
        # Check if this a package install of rocm
        if ! $PKG_INSTALLED_CMD 2>&1 | grep "$pkg" > /dev/null 2>&1; then
            echo "Package $pkg not installed."
            not_install+="$pkg "
        else
            echo "$pkg" is installed
        fi
    done

    if [[ -n $not_install ]]; then
        print_err "ROCm Runfile installer requires installation of the following packages: $not_install"
        exit 1
    fi
}

query_prev_rocm() {
    local inst=$1
    local pkg_install=0

    # Check for a package manager install of the install version
    check_rocm_package_install "$inst"
    pkg_install=$?

    if [[ $pkg_install -eq 0 ]]; then
        print_warning "Runfile Installation of ROCm detected : $inst"
    else
        print_warning "Package manager Installation of ROCm detected : $inst"
    fi

    echo -e "Overwriting an existing installation may result in a loss of functionality.\n"
    read -rp "Do you wish to continue with a new Runfile ROCm installation (y/n): " option
    if [[ $option == "Y" || $option == "y" ]]; then
        echo "Proceeding with install..."
    else
        echo -e "Exiting Installer.\n"

        if [[ $pkg_install -eq 0 ]]; then
            echo -e "Please uninstall previous version/s of ROCm using the Runfile installer.\n"
            echo "Usage:"
            echo "------"
            echo "bash $PROG target=${inst%/} uninstall-rocm"
        else
            print_err "Package installation of ROCm: $inst"
            echo "Please uninstall previous version of ROCm using the package manager."
        fi
        exit 1
    fi
}

process_prev_rocm() {
    local prev_install=0

    # Check if rocm install is being forced, if not, prompt the user
    if [[ $FORCE_INSTALL == 1 ]]; then
        print_warning "Forcing ROCm install."
    else
        # Check the list of rocm installs for the current target
        IFS=',' read -ra rocm_install <<< "$ROCM_INSTALLS"
        for inst in "${rocm_install[@]}"; do
            # Check if the same version is being installed (use ROCM_VER for major.minor match)
            if [[ "$inst" == *"$ROCM_VER"* ]]; then
                echo Version match: "$ROCM_VER"
                prev_install=1
                break
            fi
        done

        # Query the user for processing of the previous install of rocm
        if [[ $prev_install -eq 1 ]]; then
            # For multi-arch installations, check if we're doing an incremental install
            if [[ "${INSTALLER_BUILD_TYPE:-}" == "multi-arch" && ${#GFX_INSTALL_LIST[@]} -gt 0 ]]; then
                # Multi-arch: check if ANY of the GFX archs are already installed
                local manifest_file="$inst/.info/$INSTALL_MANIFEST_NAME"
                local already_installed_gfx=()
                local new_gfx=()

                for gfx in "${GFX_INSTALL_LIST[@]}"; do
                    if [[ -f "$manifest_file" ]] && grep -q "^installed-gfx:${gfx}$" "$manifest_file" 2>/dev/null; then
                        already_installed_gfx+=("$gfx")
                    else
                        new_gfx+=("$gfx")
                    fi
                done

                # Only prompt if trying to reinstall already-installed GFX archs
                if [[ ${#already_installed_gfx[@]} -gt 0 ]]; then
                    echo "The following GFX architecture(s) are already installed: ${already_installed_gfx[*]}"
                    if [[ ${#new_gfx[@]} -gt 0 ]]; then
                        echo "New GFX architecture(s) to be added: ${new_gfx[*]}"
                    fi
                    echo ""
                    query_prev_rocm "$inst"
                else
                    # All GFX archs are new - this is an incremental install, no prompt needed
                    echo "Incremental multi-GFX install detected."
                    echo "Adding new GFX architecture(s): ${new_gfx[*]}"
                    echo "Proceeding without overwrite prompt..."
                fi
            else
                # Single-arch or no GFX list: use existing behavior (always prompt)
                query_prev_rocm "$inst"
            fi
        fi
    fi
}

preinstall_rocm() {
    echo --------------------------------
    echo Preinstall ROCm...

    # Check for installer prerequisites
    prereq_installer_check

    # Check for ROCm version mismatch (prevents mixing versions)
    if ! check_rocm_version_mismatch "$TARGET_DIR"; then
        exit 1
    fi

    # Check for any previous installs of ROCm for the current target
    if find_rocm_with_progress "$TARGET_DIR"; then
        process_prev_rocm
    else
        print_no_err "ROCm Install not found."
    fi

    echo Preinstall ROCm...Complete.
    echo --------------------------------
}

set_rocm_target() {
    EXTRACT_DIR="$EXTRACT_ROCM_DIR"
    TARGET_DIR="$TARGET_ROCM_DIR"

    if [[ $TARGET_DIR == "/" ]]; then
        TARGET_DIR=/opt
    fi

    echo "EXTRACT_DIR: $EXTRACT_DIR"
    echo "TARGET_DIR : $TARGET_DIR"
}

process_test_component() {
    # Test packages require gfx= to be specified
    if [[ -z "$INSTALL_GFX" ]]; then
        print_err "Test packages require gfx= argument to specify architecture."
        echo "Example: $PROG compo=test gfx=gfx110x rocm"
        exit 1
    fi

    # Read test config file for the specified architecture
    # Test config includes base test packages, gfx-specific test packages, AND all their dependencies
    local test_config_file="$COMPO_TEST_DIR/${INSTALL_GFX}.config"
    if [ -f "$test_config_file" ]; then
        echo "  Reading test config (base + $INSTALL_GFX with dependencies): $test_config_file"
        while IFS= read -r pkg; do
            # Skip empty lines
            [[ -z "$pkg" ]] && continue

            # Check if package is in gfx directory or base directory using deps/
            if [ -d "$EXTRACT_ROCM_DIR/deps/${INSTALL_GFX}/$pkg" ]; then
                # Package is in gfx directory - add to COMPONENTS_GFX if not duplicate
                if [[ ! " $COMPONENTS_GFX " =~ \ $pkg\  ]]; then
                    COMPONENTS_GFX="$COMPONENTS_GFX $pkg"
                fi
            elif [ -d "$EXTRACT_ROCM_DIR/deps/base/$pkg" ]; then
                # Package is in base directory - add to COMPONENTS if not duplicate
                if [[ ! " $COMPONENTS " =~ \ $pkg\  ]]; then
                    COMPONENTS="$COMPONENTS $pkg"
                fi
            fi
        done < "$test_config_file"
    else
        print_err "Test config file not found: $test_config_file"
        echo "Available test architectures:"
        for test_file in "$COMPO_TEST_DIR"/*.config; do
            if [ -f "$test_file" ]; then
                test_arch=$(basename "$test_file" .config)
                echo "  - $test_arch"
            fi
        done
        exit 1
    fi
}

process_base_only_component() {
    local meta_base="$1"

    # Base-only components (dev-tools, opencl) have no gfx variants
    local base_meta_file="$COMPO_META_DIR/${meta_base}-meta.config"
    if [ -f "$base_meta_file" ]; then
        echo "  Reading base meta config: $base_meta_file"
        while IFS= read -r pkg; do
            # Check if package is in base directory
            if [ -d "$EXTRACT_ROCM_DIR/content/base/$pkg" ]; then
                COMPONENTS="$COMPONENTS $pkg"
            fi
        done < "$base_meta_file"
    else
        print_err "Meta config file not found: $base_meta_file"
        exit 1
    fi
}

process_gfx_component() {
    local meta_base="$1"

    # GFX-specific installation
    local gfx_meta_file="$COMPO_META_DIR/${meta_base}-${INSTALL_GFX}-meta.config"

    if [ -f "$gfx_meta_file" ]; then
        echo "  Reading GFX meta config: $gfx_meta_file"
        while IFS= read -r pkg; do
            # Split packages between base and gfx directories
            # Check content first (for install), then scriptlets (for uninstall/post-install)
            if [ -d "$EXTRACT_ROCM_DIR/content/base/$pkg" ] || [ -d "$EXTRACT_ROCM_DIR/scriptlets/base/$pkg" ]; then
                # Package is in base directory
                if [[ ! " $COMPONENTS " =~ \ $pkg\  ]]; then
                    COMPONENTS="$COMPONENTS $pkg"
                fi
            elif [ -d "$EXTRACT_ROCM_DIR/content/${INSTALL_GFX}/$pkg" ] || [ -d "$EXTRACT_ROCM_DIR/scriptlets/${INSTALL_GFX}/$pkg" ]; then
                # Package is in gfx directory
                if [[ ! " $COMPONENTS_GFX " =~ \ $pkg\  ]]; then
                    COMPONENTS_GFX="$COMPONENTS_GFX $pkg"
                fi
            fi
        done < "$gfx_meta_file"
    else
        print_err "GFX meta config file not found: $gfx_meta_file"
        echo "Available GFX architectures:"
        for gfx_dir in "$EXTRACT_ROCM_DIR"/gfx*/; do
            if [ -d "$gfx_dir" ]; then
                gfx_name=$(basename "$gfx_dir")
                echo "  - $gfx_name"
            fi
        done
        exit 1
    fi
}

process_base_component() {
    local meta_base="$1"

    # Base-only installation (no gfx specified)
    # For components that have base variants, install only base packages
    local base_meta_file="$COMPO_META_DIR/${meta_base}-meta.config"

    # Try base-specific meta file first (for base-only installs)
    if [ -f "$base_meta_file" ]; then
        echo "  Reading base meta config: $base_meta_file"
        while IFS= read -r pkg; do
            # Only add packages that are in base directory
            # Check content first (for install), then scriptlets (for uninstall/post-install)
            if [ -d "$EXTRACT_ROCM_DIR/content/base/$pkg" ] || [ -d "$EXTRACT_ROCM_DIR/scriptlets/base/$pkg" ]; then
                if [[ ! " $COMPONENTS " =~ \ $pkg\  ]]; then
                    COMPONENTS="$COMPONENTS $pkg"
                fi
            fi
        done < "$base_meta_file"
    else
        # If no base-specific meta file, try to find any gfx variant and extract base packages
        local any_gfx_meta_file
        any_gfx_meta_file=$(find "$COMPO_META_DIR" -name "${meta_base}-gfx*-meta.config" -print -quit)
        if [ -f "$any_gfx_meta_file" ]; then
            echo "  Reading base packages from: $any_gfx_meta_file"
            while IFS= read -r pkg; do
                # Only add packages that are in base directory
                # Check content first (for install), then scriptlets (for uninstall/post-install)
                if [ -d "$EXTRACT_ROCM_DIR/content/base/$pkg" ] || [ -d "$EXTRACT_ROCM_DIR/scriptlets/base/$pkg" ]; then
                    if [[ ! " $COMPONENTS " =~ \ $pkg\  ]]; then
                        COMPONENTS="$COMPONENTS $pkg"
                    fi
                fi
            done < "$any_gfx_meta_file"
        else
            print_err "No meta config file found for component: $meta_base"
            exit 1
        fi
    fi
}

configure_rocm_install() {
    echo "Configuring ROCm installation using component list: $COMPO_INSTALL"

    # ROCm version info should already be set by setup_rocm_version_info() called earlier
    if [[ -z "$ROCM_VER" ]]; then
        print_err "ROCm version information not available. setup_rocm_version_info() should be called first."
        exit 1
    fi

    # Reset component arrays
    COMPONENTS=
    COMPONENTS_GFX=

    # Split comma-separated component list
    IFS=',' read -ra COMPO_LIST <<< "$COMPO_INSTALL"

    # Process each requested component
    for compo_name in "${COMPO_LIST[@]}"; do
        # Trim whitespace using bash parameter expansion
        compo_name="${compo_name#"${compo_name%%[![:space:]]*}"}"
        compo_name="${compo_name%"${compo_name##*[![:space:]]}"}"

        echo "Processing component: $compo_name"

        # Determine meta base name for the component
        local meta_base
        case "$compo_name" in
            core)
                meta_base="amdrocm-core${ROCM_VER}"
                ;;
            core-dev)
                meta_base="amdrocm-core-devel${ROCM_VER}"
                ;;
            dev-tools)
                meta_base="amdrocm-developer-tools${ROCM_VER}"
                ;;
            core-sdk)
                meta_base="amdrocm-core-sdk${ROCM_VER}"
                ;;
            opencl)
                meta_base="amdrocm-opencl${ROCM_VER}"
                ;;
            test)
                # Test packages are handled separately using test config files
                meta_base="test"
                ;;
            *)
                print_err "Unknown component: $compo_name"
                echo "Valid components: core, core-dev, dev-tools, core-sdk, opencl, test"
                exit 1
                ;;
        esac

        # Process component based on type
        if [[ "$compo_name" == "test" ]]; then
            process_test_component
        elif [[ "$compo_name" == "dev-tools" || "$compo_name" == "opencl" ]]; then
            process_base_only_component "$meta_base"
        else
            # For core, core-dev, core-sdk: read both base packages and gfx packages
            if [[ -n $INSTALL_GFX ]]; then
                process_gfx_component "$meta_base"
            else
                process_base_component "$meta_base"
            fi
        fi
    done

    # Trim leading/trailing spaces using bash parameter expansion
    COMPONENTS="${COMPONENTS#"${COMPONENTS%%[![:space:]]*}"}"
    COMPONENTS="${COMPONENTS%"${COMPONENTS##*[![:space:]]}"}"

    COMPONENTS_GFX="${COMPONENTS_GFX#"${COMPONENTS_GFX%%[![:space:]]*}"}"
    COMPONENTS_GFX="${COMPONENTS_GFX%"${COMPONENTS_GFX##*[![:space:]]}"}"

    echo "Base components to install: $COMPONENTS"
    if [[ -n $INSTALL_GFX ]]; then
        echo "GFX components to install: $COMPONENTS_GFX"
    fi

    if [[ -z "$COMPONENTS" && -z "$COMPONENTS_GFX" ]]; then
        print_err "No components found for installation"
        exit 1
    fi
}

install_rocm() {
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo -e "\e[96mINSTALL ROCm\e[0m"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="

    set_rocm_target

    # If using a target, check that the target directory for install exists
    if [[ -n "$INSTALL_TARGET" && ! -d "$TARGET_DIR" ]]; then
        print_err "Target directory $TARGET_DIR for install does not exist."
        exit 1
    fi

    # ROCm version info should already be set by setup_rocm_version_info() called earlier
    if [[ -z "$INSTALLER_ROCM_VERSION_NAME" ]]; then
        print_err "ROCm version information not available. setup_rocm_version_info() should be called first."
        exit 1
    fi

    # Check if rocm is installable
    preinstall_rocm

    prompt_user "Install ROCm (y/n): "
    if [[ $option == "N" || $option == "n" ]]; then
        echo "Exiting Installer."
        exit 1
    fi

    # Configure the ROCm components for install
    configure_rocm_install

    # Create/initialize the installation manifest
    create_manifest

    # Check if using multi-GFX installation (multi-arch only)
    if [[ "${INSTALLER_BUILD_TYPE:-}" == "multi-arch" && ${#GFX_INSTALL_LIST[@]} -gt 0 ]]; then
        # Multi-arch multi-GFX installation (handles 1 or many GFX archs)
        install_rocm_multi_gfx "${GFX_INSTALL_LIST[@]}"
    else
        # Single-arch build OR multi-arch without GFX list (legacy flow)
        # Extract content archives before installing
        extract_content_if_needed

        # Extract tests if needed (for compo=test)
        extract_tests_if_needed

        # Install base and GFX components
        install_base_components
        install_gfx_components
    fi

    echo "Installation manifest updated successfully"

    dump_rocm_state
    dump_stats "$TARGET_DIR"
}

#------------------------------------------------------------------------------
# Multi-GFX Uninstallation Functions
#------------------------------------------------------------------------------

uninstall_gfx_components() {
    # Uninstall components for specific GFX architecture (MULTI-ARCH ONLY)
    # This function requires multi-arch manifest format with pipe-separated entries
    # Args: $1 = GFX architecture (e.g., "gfx1100")
    #
    # NOTE: This is ONLY for multi-arch installations. Single-arch uses the
    # legacy uninstall flow in uninstall_rocm_target() below.

    local gfx="$1"

    echo "Uninstalling GFX architecture: $gfx"

    # Uninstall GFX-specific components from manifest
    if [[ ! -f "$INSTALL_MANIFEST_FILE" ]]; then
        echo "No manifest file found, cannot uninstall"
        return 1
    fi

    # Collect components for this GFX arch
    local components_to_remove=()
    while IFS='|' read -r type component arch; do
        if [[ "$type" == "gfx" && "$arch" == "$gfx" ]]; then
            components_to_remove+=("$component")
        fi
    done < <(read_manifest "$INSTALL_MANIFEST_FILE")

    # Run prerm scriptlets for GFX components
    if [[ ${#components_to_remove[@]} -gt 0 ]]; then
        echo "Running prerm scriptlets for GFX components ($gfx)..."
        for component in "${components_to_remove[@]}"; do
            uninstall_prerm_scriptlet "$component" "$EXTRACT_ROCM_DIR/$gfx"
        done
    fi

    # Run postrm scriptlets for GFX components
    if [[ ${#components_to_remove[@]} -gt 0 ]]; then
        echo "Running postrm scriptlets for GFX components ($gfx)..."
        for component in "${components_to_remove[@]}"; do
            uninstall_postrm_scriptlet "$component" "$EXTRACT_ROCM_DIR/$gfx"
        done
    fi

    # Delete GFX-specific files (MULTI-ARCH ONLY)
    # This uses the multi-arch directory structure: component-rocm/content/gfxXYZ/
    if [[ ${#components_to_remove[@]} -gt 0 ]]; then
        local rocm_ver_dir="$TARGET_DIR/rocm/core-$ROCM_VER"
        local gfx_content_dir="$EXTRACT_ROCM_DIR/content/$gfx"

        if [[ -d "$gfx_content_dir" ]]; then
            echo "Deleting GFX-specific files for $gfx..."
            local files_deleted=0

            # Iterate through each component and delete its files
            for component in "${components_to_remove[@]}"; do
                local component_dir="$gfx_content_dir/$component"

                if [[ -d "$component_dir" ]]; then
                    # Find all files in the component and delete them from the installation
                    while IFS= read -r file; do
                        # Get path relative to component directory
                        local rel_path="${file#"$component_dir"/}"

                        # Strip rocm/core-X.Y/ prefix using sed since # doesn't support globs
                        rel_path=$(echo "$rel_path" | sed -E 's|^rocm/core-[^/]+/||')

                        # Delete the file from installation directory
                        local install_file="$rocm_ver_dir/$rel_path"
                        if [[ -f "$install_file" ]]; then
                            $SUDO rm -f "$install_file"
                            ((files_deleted++))
                        else
                            echo -e "\e[33mWARNING: Expected file not found: $install_file\e[0m"
                        fi
                    done < <(find "$component_dir" -type f 2>/dev/null)
                fi
            done

            echo "Deleted $files_deleted files for $gfx"

            # Clean up empty directories
            echo "Cleaning up empty directories..."
            $SUDO find "$rocm_ver_dir" -type d -empty -delete 2>/dev/null || true
        else
            echo "WARNING: Multi-arch content directory not found: $gfx_content_dir"
            echo "This function is only for multi-arch installations."
        fi
    fi

    # Remove GFX entries from manifest (pipe-separated format)
    sed -i "/^gfx|.*|${gfx}$/d" "$INSTALL_MANIFEST_FILE"
}

uninstall_base_components() {
    # Uninstall base ROCm components

    echo "Uninstalling base packages..."

    if [[ ! -f "$INSTALL_MANIFEST_FILE" ]]; then
        echo "No manifest file found, cannot uninstall"
        return 1
    fi

    # Collect base components from manifest
    local components_to_remove=()
    while IFS='|' read -r type component arch; do
        if [[ "$type" == "base" ]]; then
            components_to_remove+=("$component")
        fi
    done < <(read_manifest "$INSTALL_MANIFEST_FILE")

    # Run prerm scriptlets for base components
    if [[ ${#components_to_remove[@]} -gt 0 ]]; then
        echo "Running prerm scriptlets for base components..."
        for component in "${components_to_remove[@]}"; do
            uninstall_prerm_scriptlet "$component" "$EXTRACT_ROCM_DIR/base"
        done
    fi

    # Run postrm scriptlets for base components
    if [[ ${#components_to_remove[@]} -gt 0 ]]; then
        echo "Running postrm scriptlets for base components..."
        for component in "${components_to_remove[@]}"; do
            uninstall_postrm_scriptlet "$component" "$EXTRACT_ROCM_DIR/base"
        done
    fi

    # Remove base entries from manifest (pipe-separated format)
    sed -i "/^base|/d" "$INSTALL_MANIFEST_FILE"
}

uninstall_rocm_multi_gfx() {
    # Uninstall multiple GFX architectures (MULTI-ARCH ONLY)
    # Keeps base packages until last GFX arch is removed
    # Args: $@ = Array of GFX architectures
    #
    # IMPORTANT: This function is ONLY for multi-arch builds.
    # - Requires pipe-separated manifest format (type|component|arch)
    # - Uses content/gfxXYZ/ directory structure
    # - Requires installed-gfx:gfxXYZ markers in manifest
    #
    # Single-arch builds use the legacy uninstall flow in uninstall_rocm_target().

    local -a gfx_list=("$@")

    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo -e "\e[95mMulti-GFX Uninstallation\e[0m"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo "Uninstalling ${#gfx_list[@]} GFX architecture(s): ${gfx_list[*]}"
    echo ""

    # Check if manifest file exists
    # If missing, fall back to legacy uninstall (delete entire directory)
    if [[ ! -f "$INSTALL_MANIFEST_FILE" ]]; then
        echo "WARNING: Manifest file not found at: $INSTALL_MANIFEST_FILE"
        echo "Cannot perform selective multi-GFX uninstall without manifest."
        echo "Falling back to legacy uninstall flow (will delete entire ROCm directory)."
        echo ""

        # Fall back to legacy uninstall
        local rocm_ver_dir="$TARGET_DIR/rocm/core-$ROCM_VER"
        if [[ -d "$rocm_ver_dir" && "$rocm_ver_dir" != "/" ]]; then
            echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
            echo -e "\e[93mRemoving ROCm installation directory: $rocm_ver_dir\e[0m"
            echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="

            # Show what's being deleted
            echo "Deleting:"
            echo "  - $(find "$rocm_ver_dir" -type f 2>/dev/null | wc -l) files"
            echo "  - $(find "$rocm_ver_dir" -type d 2>/dev/null | wc -l) directories"
            echo "  - $(find "$rocm_ver_dir" -type l 2>/dev/null | wc -l) symlinks"

            $SUDO rm -rf "$rocm_ver_dir"
            echo "Removed: $rocm_ver_dir"

            # Remove parent directory symlinks
            remove_rocm_symlinks "$TARGET_DIR/rocm"

            # Remove parent directory if empty
            if [[ -d "$TARGET_DIR/rocm" && -z "$(ls -A "$TARGET_DIR/rocm" 2>/dev/null)" ]]; then
                echo "Removing empty ROCm parent directory: $TARGET_DIR/rocm"
                $SUDO rmdir "$TARGET_DIR/rocm" 2>/dev/null || true
            fi

            echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
            echo -e "\e[32mComplete uninstall finished\e[0m"
            echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
        else
            echo "ERROR: ROCm directory not found or invalid: $rocm_ver_dir"
            return 1
        fi

        return 0
    fi

    # Set the PREFIX variable for scriptlets (needed for update-alternatives)
    local rocm_ver_dir="$TARGET_DIR/rocm/core-$ROCM_VER"
    set_prefix_scriptlet "$rocm_ver_dir"

    # Step 1: Uninstall each GFX arch
    local skipped_archs=()
    local uninstalled_archs=()

    for gfx in "${gfx_list[@]}"; do
        if ! is_gfx_installed "$gfx"; then
            skipped_archs+=("$gfx")
            continue
        fi

        uninstalled_archs+=("$gfx")
        echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
        uninstall_gfx_components "$gfx"
        unmark_gfx_installed "$gfx"
        echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
        echo ""
    done

    # Summary of skipped architectures
    if [[ ${#skipped_archs[@]} -gt 0 ]]; then
        echo "Skipped ${#skipped_archs[@]} architecture(s) (not installed): ${skipped_archs[*]}"
        echo ""
    fi

    # Step 2: Check if any GFX archs remain
    local remaining_gfx
    remaining_gfx=$(get_installed_gfx_archs)

    if [[ -z "$remaining_gfx" ]]; then
        echo "No GFX architectures remaining."
        echo ""

        # Uninstall base components
        uninstall_base_components
        unmark_base_installed

        # Remove the ROCm version directory (e.g., /opt/rocm/core-7.14)
        local rocm_ver_dir="$TARGET_DIR/rocm/core-$ROCM_VER"
        if [[ -d "$rocm_ver_dir" ]]; then
            echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
            echo -e "\e[93mRemoving ROCm installation directory: $rocm_ver_dir\e[0m"
            echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="

            # Show what's being deleted
            echo "Deleting:"
            echo "  - $(find "$rocm_ver_dir" -type f 2>/dev/null | wc -l) files"
            echo "  - $(find "$rocm_ver_dir" -type d 2>/dev/null | wc -l) directories"
            echo "  - $(find "$rocm_ver_dir" -type l 2>/dev/null | wc -l) symlinks"

            $SUDO rm -rf "$rocm_ver_dir"
            echo "Removed: $rocm_ver_dir"
        fi

        # Remove update-alternatives symlinks in /opt/rocm
        remove_rocm_symlinks "$TARGET_DIR/rocm"

        # If /opt/rocm is now empty, remove it
        local rocm_parent="$TARGET_DIR/rocm"
        if [[ -d "$rocm_parent" && -z "$(ls -A "$rocm_parent" 2>/dev/null)" ]]; then
            echo "Removing empty ROCm parent directory: $rocm_parent"
            $SUDO rmdir "$rocm_parent"
        fi

        echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
        echo -e "\e[32mComplete uninstall finished\e[0m"
        echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    else
        echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
        echo "Other GFX architectures still installed: $remaining_gfx"
        echo "Keeping base packages."
        echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    fi
}

uninstall_rocm_target() {
    local inst=$1

    # set the version directory
    local rocm_ver_dir="${inst%/}"
    local rocm_rm_dir="${inst%/rocm*}"

    # Set manifest file path for uninstall (use detected install path)
    INSTALL_MANIFEST_FILE="$rocm_ver_dir/.info/$INSTALL_MANIFEST_NAME"

    echo "ROCM Version Directory : $rocm_ver_dir/"
    echo "ROCm Removal Directory : $rocm_rm_dir"

    # Start the uninstall
    prompt_user "Uninstall ROCm (y/n): "
    if [[ $option == "N" || $option == "n" ]]; then
        echo "Exiting Installer."
        exit 1
    fi

    echo -e "\e[95mUninstalling ROCm target: $rocm_ver_dir\e[0m"

    # if the directory for removal exists, then remove the components and delete it
    if [[ -d "$rocm_rm_dir" && "$rocm_rm_dir" != "/" ]]; then
        echo Uninstalling components from config.

        # Reset COMPONENTS to avoid accumulation across multiple uninstall calls
        COMPONENTS=
        COMPONENTS_GFX=

        # Check if user explicitly specified gfx= for multi-GFX uninstall
        if [[ $USER_SPECIFIED_GFX -eq 1 && ${#GFX_INSTALL_LIST[@]} -gt 0 ]]; then
            # Check if manifest exists and has multi-GFX markers
            if [[ -f "$INSTALL_MANIFEST_FILE" ]] && grep -q "^installed-gfx:" "$INSTALL_MANIFEST_FILE" 2>/dev/null; then
                # Multi-arch installation confirmed - use multi-GFX uninstall
                echo "Multi-GFX uninstall requested for: ${GFX_INSTALL_LIST[*]}"
                uninstall_rocm_multi_gfx "${GFX_INSTALL_LIST[@]}"
                return 0
            elif [[ ! -f "$INSTALL_MANIFEST_FILE" ]]; then
                # Manifest missing - use multi-GFX uninstall which has fallback logic
                echo "Multi-GFX uninstall requested for: ${GFX_INSTALL_LIST[*]}"
                echo "Note: Manifest file missing, will use fallback uninstall method."
                uninstall_rocm_multi_gfx "${GFX_INSTALL_LIST[@]}"
                return 0
            else
                # Manifest exists but no multi-GFX markers - this is single-arch
                echo "WARNING: Multi-GFX uninstall requested but this is not a multi-arch installation."
                echo "Falling back to standard uninstall flow."
                # Continue with standard uninstall below
            fi
        elif [[ $USER_SPECIFIED_COMPO -eq 1 || $USER_SPECIFIED_GFX -eq 1 ]]; then
            # Selective uninstall: use compo= and gfx= arguments (same as install)
            echo "Selective uninstall using compo=$COMPO_INSTALL gfx=${INSTALL_GFX:-none}"
            configure_rocm_install
        else
            # Auto-detect uninstall
            echo "Auto-detecting installed components for uninstall..."

            # Check if this is a multi-arch multi-GFX installation (has installed-gfx markers)
            # This check ensures we only use multi-GFX logic for actual multi-arch builds
            if [[ -f "$INSTALL_MANIFEST_FILE" ]] && grep -q "^installed-gfx:" "$INSTALL_MANIFEST_FILE" 2>/dev/null; then
                # Multi-arch multi-GFX installation detected
                echo "Multi-arch multi-GFX installation detected"

                # If GPU auto-detected, uninstall only that GFX
                if [[ -n "$DETECTED_GFX_RESULT" ]]; then
                    echo "Auto-detected GFX: $DETECTED_GFX_RESULT"

                    if is_gfx_installed "$DETECTED_GFX_RESULT"; then
                        echo "Uninstalling detected GFX architecture: $DETECTED_GFX_RESULT"
                        uninstall_rocm_multi_gfx "$DETECTED_GFX_RESULT"
                        return 0
                    else
                        echo "Detected GFX '$DETECTED_GFX_RESULT' is not installed."
                        local installed_gfx
                        installed_gfx=$(get_installed_gfx_archs)
                        if [[ -n "$installed_gfx" ]]; then
                            echo "Installed GFX architectures: $installed_gfx"
                            echo "Use 'gfx=<arch>' to specify which GFX to uninstall."
                        fi
                        exit 1
                    fi
                else
                    # No GPU detected, show what's installed
                    local installed_gfx
                    installed_gfx=$(get_installed_gfx_archs)
                    echo "Multi-arch multi-GFX installation with architectures: $installed_gfx"
                    echo "Please specify which GFX architecture to uninstall using 'gfx=<arch>'"
                    echo "  Example: $PROG gfx=gfx1100 uninstall-rocm"
                    echo "  Or uninstall all: $PROG gfx=all uninstall-rocm"
                    exit 1
                fi
            fi

            # If we reach here, this is NOT a multi-arch multi-GFX installation
            # Continue with legacy single-arch uninstall flow

            # ROCm version info should already be set by setup_rocm_version_info() called earlier
            # If not set, that's okay for uninstall - we can still try based on directory structure

            # Try to read manifest file first (INSTALL_MANIFEST_FILE already set above)
            if ! load_manifest_for_uninstall "$INSTALL_MANIFEST_FILE"; then
                echo -e "\e[93mNo manifest found, falling back to signature-based detection\e[0m"

                # For auto-detection, we need to use component-rocm which has content/ directories.
                # component-rocm-deb only has scriptlets but no content, so detection cannot match files.
                # Save the scriptlet directory and temporarily switch to component-rocm for detection.
                local saved_extract_rocm_dir="$EXTRACT_ROCM_DIR"
                if [ -d "$PWD/component-rocm" ]; then
                    EXTRACT_ROCM_DIR="$PWD/component-rocm"
                fi

                # Step 1: Detect which base components are actually installed at the target
                detect_installed_base_components "$rocm_ver_dir"

                # Step 2: Detect which GFX architectures are actually installed at the target
                detect_installed_gfx_architectures "$rocm_ver_dir"

                # Step 3: Detect which GFX components are installed for each architecture
                detect_installed_gfx_components "$rocm_ver_dir"

                # Restore the scriptlet directory for running removal scripts
                EXTRACT_ROCM_DIR="$saved_extract_rocm_dir"
            fi

            # Step 4: Detect meta packages with scriptlets
            detect_meta_packages

            # Build COMPONENTS_GFX string from gfx_components array for display
            COMPONENTS_GFX=""
            for entry in "${gfx_components[@]}"; do
                local comps="${entry%|*}"
                COMPONENTS_GFX="$COMPONENTS_GFX $comps"
            done
        fi

        echo "Base components for uninstall: $COMPONENTS"
        if [[ -n "$COMPONENTS_GFX" ]]; then
            echo "GFX components for uninstall: $COMPONENTS_GFX"
        fi

        # Set the PREFIX variable for rpm-based extracted scriptlets if required
        set_prefix_scriptlet "$rocm_ver_dir"

        # Run the pre-remove scripts for base components
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        if [[ -n "$COMPONENTS" ]]; then
            echo "prerm executing for base components...."
            for compo in $COMPONENTS; do
                uninstall_prerm_scriptlet "$compo" "$EXTRACT_ROCM_DIR/base"
            done
        fi

        # Run the pre-remove scripts for all detected GFX components
        if [ ${#gfx_components[@]} -gt 0 ]; then
            echo "prerm executing for GFX components...."
            for entry in "${gfx_components[@]}"; do
                local comps="${entry%|*}"
                local gfx_extract_dir="${entry#*|}"
                gfx_extract_dir="${gfx_extract_dir%/}"  # Remove trailing slash

                for compo in $comps; do
                    uninstall_prerm_scriptlet "$compo" "$gfx_extract_dir"
                done
            done
        fi
        echo "prerm executing....Complete."

        # Run the post-remove scripts for base components
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        if [[ -n "$COMPONENTS" ]]; then
            echo "postrm executing for base components...."
            for compo in $COMPONENTS; do
                uninstall_postrm_scriptlet "$compo" "$EXTRACT_ROCM_DIR/base"
            done
        fi

        # Run the post-remove scripts for all detected GFX components
        if [ ${#gfx_components[@]} -gt 0 ]; then
            echo "postrm executing for GFX components...."
            for entry in "${gfx_components[@]}"; do
                local comps="${entry%|*}"
                local gfx_extract_dir="${entry#*|}"
                gfx_extract_dir="${gfx_extract_dir%/}"  # Remove trailing slash

                for compo in $comps; do
                    uninstall_postrm_scriptlet "$compo" "$gfx_extract_dir"
                done
            done
        fi
        echo "postrm executing....Complete."

        # Remove library path configuration
        remove_library_paths

        if [ -d "$rocm_ver_dir" ]; then
            echo -e "\e[93mRemoving ROCm version directory: $rocm_ver_dir\e[0m"
            $SUDO rm -r "$rocm_ver_dir"
        fi

        # Check if the "rocm" symlink exists
        if [[ -L "$rocm_rm_dir/rocm" ]]; then
            echo "Found symlink 'rocm': $rocm_rm_dir/rocm"

            local item_count
            item_count=$(find "$rocm_rm_dir" -mindepth 1 -maxdepth 1 | wc -l)

            # If the directory contains only the "rocm" symlink, delete it
            if [[ $item_count -eq 1 ]]; then
                $SUDO rm "$rocm_rm_dir/rocm"
                echo "Removing symlink 'rocm'."
            fi
        fi

        # Check if /opt/rocm (or equivalent parent) directory is empty and remove it
        local rocm_parent_dir="$rocm_rm_dir/rocm"
        if [ -d "$rocm_parent_dir" ]; then
            local parent_item_count
            parent_item_count=$(find "$rocm_parent_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)

            if [[ $parent_item_count -eq 0 ]]; then
                echo -e "\e[93mRemoving empty ROCm parent directory: $rocm_parent_dir\e[0m"
                $SUDO rmdir "$rocm_parent_dir"
            else
                echo "ROCm parent directory is not empty ($parent_item_count items), keeping it."
            fi
        fi
    else
        print_err "ROCm remove target: $rocm_rm_dir does not exist."
        exit 1
    fi

    echo "PRERM_COUNT  = $PRERM_COUNT"
    echo "POSTRM_COUNT = $POSTRM_COUNT"
    echo -e "\e[95mUNINSTALL ROCm Components. Complete.\e[0m"
}

uninstall_rocm() {
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo -e "\e[95mUNINSTALL ROCm\e[0m"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="

    set_rocm_target

    # Check for ROCm version mismatch (prevents uninstalling wrong version)
    if ! check_rocm_version_mismatch "$TARGET_DIR"; then
        exit 1
    fi

    # Check for any previous installs of ROCm
    if find_rocm_with_progress "$TARGET_DIR"; then

        # Update the target for scriptlet handling
        if [[ "$TARGET_DIR" == *"rocm"* ]]; then
            TARGET_DIR="${TARGET_ROCM_DIR%/rocm*}"
            echo "TARGET_DIR : $TARGET_DIR"
        fi

        # Check the list of rocm installs for the current target
        IFS=',' read -ra rocm_install <<< "$ROCM_INSTALLS"

        print_no_err "ROCm Installs found: ${#rocm_install[@]}"

        # Check if multiple rocm installs at current target
        if [[ ${#rocm_install[@]} -gt 1 ]]; then
            echo "Multiple ROCm installs for target=$INSTALL_TARGET"
            read -rp "Do you wish to uninstall all ROCm installations at target (y/n): " option
            if [[ $option == "Y" || $option == "y" ]]; then
                echo "Proceeding with uninstall..."
            else
                echo "Exiting uninstall."
                exit 1
            fi
        fi

        # Uninstall each rocm install at target
        for inst in "${rocm_install[@]}"; do

            # Check for a package manager install of the install version
            check_rocm_package_install "$inst"
            if [[ $? -eq 1 ]]; then
                print_err "Package installation of ROCm: $inst"
                echo "Please uninstall previous version of ROCm using the package manager."
                exit 1
            fi

            uninstall_rocm_target "$inst"

        done
    else
        print_err "ROCm Install Directory not found."
        exit 1
    fi
}

install_amdgpu() {
    # Call external AMDGPU installer script
    "$PWD/amdgpu-installer.sh" install $AMDGPU_INSTALLER_ARGS
}

uninstall_amdgpu() {
    # Call external AMDGPU installer script
    "$PWD/amdgpu-installer.sh" uninstall $AMDGPU_INSTALLER_ARGS
}

install_postint_scriptlets() {
    echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    echo Running post install scripts...

    # Run post-install scripts for base components
    if [[ -n "$COMPONENTS" ]]; then
        echo "postinst executing for base components...."
        for compo in $COMPONENTS; do
            install_postinst_scriptlet "$compo" "$EXTRACT_ROCM_DIR/base"
        done
    fi

    # Run post-install scripts for GFX-specific components
    # Handle both explicit gfx= specification and auto-detected GFX components
    if [[ -n $INSTALL_GFX ]]; then
        # Explicit gfx= was specified
        local gfx_extract_dir="$EXTRACT_ROCM_DIR/${INSTALL_GFX}"
        echo "postinst executing for GFX components ($INSTALL_GFX)...."
        for compo in $COMPONENTS_GFX; do
            install_postinst_scriptlet "$compo" "$gfx_extract_dir"
        done
    elif [ ${#gfx_components[@]} -gt 0 ]; then
        # Auto-detected GFX components (from uninstall-like detection)
        echo "postinst executing for auto-detected GFX components...."
        for entry in "${gfx_components[@]}"; do
            local comps="${entry%|*}"
            local gfx_extract_dir="${entry#*|}"
            gfx_extract_dir="${gfx_extract_dir%/}"  # Remove trailing slash

            for compo in $comps; do
                install_postinst_scriptlet "$compo" "$gfx_extract_dir"
            done
        done
    fi

    echo Running post install scripts...Complete.
}

configure_library_paths() {
    # Only configure library paths for ROCm 7.12
    if [[ "$ROCM_VER" != "7.12" ]]; then
        return 0
    fi

    echo "Configuring library paths for ROCm..."

    # Determine the target directory
    local target_dir
    if [[ -z "$INSTALL_TARGET" ]]; then
        target_dir="/opt"
    else
        target_dir="$INSTALL_TARGET"
    fi

    # Create the ld.so.conf.d configuration file with versioned filename
    local ld_conf_file="/etc/ld.so.conf.d/rocm-core-${INSTALLER_ROCM_VERSION}.conf"

    echo "Creating library configuration: $ld_conf_file"

    # Write the library paths to the configuration file
    if $SUDO bash -c "cat > '$ld_conf_file'" <<EOF
${target_dir}/${INSTALLER_ROCM_VERSION_NAME}/lib
${target_dir}/${INSTALLER_ROCM_VERSION_NAME}/lib/rocm_sysdeps/lib
EOF
    then
        echo "Library paths configured successfully."

        # Update the library cache
        echo "Updating library cache..."
        if $SUDO ldconfig; then
            echo "Library cache updated successfully."
        else
            echo "WARNING: Failed to update library cache. You may need to run 'sudo ldconfig' manually."
        fi
    else
        echo "WARNING: Failed to create library configuration file."
    fi
}

remove_library_paths() {
    # Only remove library paths for ROCm 7.12
    if [[ "$ROCM_VER" != "7.12" ]]; then
        return 0
    fi

    echo "Removing library path configuration for ROCm..."

    # Create the ld.so.conf.d configuration filename
    local ld_conf_file="/etc/ld.so.conf.d/rocm-core-${INSTALLER_ROCM_VERSION}.conf"

    # Check if the configuration file exists
    if [[ -f "$ld_conf_file" ]]; then
        echo "Removing library configuration: $ld_conf_file"
        if $SUDO rm -f "$ld_conf_file"; then
            echo "Library configuration removed successfully."

            # Update the library cache
            echo "Updating library cache..."
            if $SUDO ldconfig; then
                echo "Library cache updated successfully."
            else
                echo "WARNING: Failed to update library cache. You may need to run 'sudo ldconfig' manually."
            fi
        else
            echo "WARNING: Failed to remove library configuration file."
        fi
    else
        echo "Library configuration file not found (already removed or not installed): $ld_conf_file"
    fi
}

install_post_rocm_extras() {
    echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    echo Setting up extra ROCm post install...

    # Configure library paths for ROCm
    configure_library_paths

    echo Setting up extra ROCm post install...Complete.
}

install_post_rocm() {
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo -e "\e[96mINSTALL ROCm post-install config\e[0m"
    echo "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="

    local rocm_ver_dir=

    # Select component directory based on OS type
    if [ "$PACKAGE_TYPE" == "deb" ]; then
        if [ -d "$PWD/component-rocm-deb" ]; then
            EXTRACT_ROCM_DIR="$PWD/component-rocm-deb"
            echo "Using DEB component directory: $EXTRACT_ROCM_DIR"
        else
            print_warning "component-rocm-deb not found, falling back to component-rocm"
            EXTRACT_ROCM_DIR="$PWD/component-rocm"
        fi
    else
        EXTRACT_ROCM_DIR="$PWD/component-rocm"
        echo "Using RPM component directory: $EXTRACT_ROCM_DIR"
    fi

    # check if postrocm is part of a rocm install
    if [[ $ROCM_INSTALL == 1 ]]; then
        echo ROCm post-install...
        if [[ $TARGET_DIR == "/" ]]; then
            rocm_ver_dir="/opt/$INSTALLER_ROCM_VERSION_NAME"
        else
            rocm_ver_dir="$TARGET_DIR/$INSTALLER_ROCM_VERSION_NAME"
        fi

        # Components are already configured from the rocm install
        # COMPONENTS and COMPONENTS_GFX are already populated by configure_rocm_install

    else
        echo ROCm post-install for target...

        # Use default target if not specified
        if [[ -z "$INSTALL_TARGET" ]]; then
            echo "No target specified, using default: $TARGET_ROCM_DEFAULT_DIR"
            TARGET_ROCM_DIR="$TARGET_ROCM_DEFAULT_DIR"
        fi

        set_rocm_target

        # check if target has a rocm install
        if ! find_rocm_with_progress "$TARGET_DIR"; then
            print_err "ROCm runfile install at target $TARGET_DIR not found."
            exit 1
        fi

        IFS=',' read -ra rocm_install <<< "$ROCM_INSTALLS"
        print_no_err "ROCm Installs found: ${#rocm_install[@]}"

        # Only allow for single post-rocm install
        if [[ ${#rocm_install[@]} -gt 1 ]]; then
            print_err "Multiple ROCm installation found.  Please select a single target for post install."
            exit 1
        fi

        rocm_ver_dir="$ROCM_DIR"
        TARGET_DIR="${TARGET_DIR%/rocm-[0-9]*}"

        # Check if user explicitly specified compo= or gfx= for selective post-install
        if [[ $USER_SPECIFIED_COMPO -eq 1 || $USER_SPECIFIED_GFX -eq 1 ]]; then
            # Selective post-install: use compo= and gfx= arguments (same as install)
            echo "Selective post-install using compo=$COMPO_INSTALL gfx=${INSTALL_GFX:-none}"
            configure_rocm_install
        else
            # Auto-detect post-install: configure everything that's actually installed
            echo "Auto-detecting installed components for post-install..."

            # ROCm version info should already be set by setup_rocm_version_info() called earlier
            # If not set, that's okay for post-install - we can still try based on directory structure

            # For auto-detection, we need to use component-rocm which has content/ directories.
            # component-rocm-deb only has scriptlets but no content, so detection cannot match files.
            # Save the scriptlet directory and temporarily switch to component-rocm for detection.
            local saved_extract_rocm_dir="$EXTRACT_ROCM_DIR"
            if [ -d "$PWD/component-rocm" ]; then
                EXTRACT_ROCM_DIR="$PWD/component-rocm"
                echo "Using component-rocm for auto-detection (has content/ directories)"
            fi

            # Step 1: Detect which base components are actually installed at the target
            detect_installed_base_components "$rocm_ver_dir"

            # Step 2: Detect which GFX architectures are actually installed at the target
            detect_installed_gfx_architectures "$rocm_ver_dir"

            # Step 3: Detect which GFX components are installed for each architecture
            detect_installed_gfx_components "$rocm_ver_dir"

            # Restore the scriptlet directory for running post-install scripts
            EXTRACT_ROCM_DIR="$saved_extract_rocm_dir"

            # Step 4: Detect meta packages with scriptlets
            detect_meta_packages

            # Build COMPONENTS_GFX string from gfx_components array for display
            COMPONENTS_GFX=""
            for entry in "${gfx_components[@]}"; do
                local comps="${entry%|*}"
                COMPONENTS_GFX="$COMPONENTS_GFX $comps"
            done
        fi

        # Now check if the target rocm version matches the installer rocm version
        local rocm_ver_name
        rocm_ver_name=$(basename "${rocm_install[0]}")

        # Remove both "rocm-" and "core-" prefixes and extract version
        local rocm_ver_extracted="${rocm_ver_name#rocm-}"  # Remove rocm- prefix if present
        rocm_ver_extracted="${rocm_ver_extracted#core-}"   # Remove core- prefix if present

        local rocm_ver_short
        rocm_ver_short=$(echo "$rocm_ver_extracted" | cut -d '.' -f 1-2)

        echo "Installer ROCm version: $ROCM_VER"
        echo "Target ROCm version   : $rocm_ver_short"

        if [[ "$rocm_ver_short" != "$ROCM_VER" ]]; then
            print_err "ROCm version mismatch between installer ($ROCM_VER) and target ($rocm_ver_short)."
            exit 1
        fi
    fi

    echo "rocm_ver_dir: $rocm_ver_dir"
    echo "TARGET_DIR  : $TARGET_DIR"

    # Verify that components are configured
    if [[ -z "$COMPONENTS" && -z "$COMPONENTS_GFX" ]]; then
        print_err "No components configured for post-install. Use compo= to specify components."
        exit 1
    fi

    echo "Post-install will process the following components:"
    echo "  Base components: $COMPONENTS"
    if [[ -n "$COMPONENTS_GFX" ]]; then
        echo "  GFX components: $COMPONENTS_GFX"
    fi

    # Set the PREFIX variable for rpm-based extracted scriptlets if required
    set_prefix_scriptlet "$rocm_ver_dir"

    # Run all postinstall scripts for the components
    install_postint_scriptlets

    # Execute any extra non-scriptlet post install
    install_post_rocm_extras
}

set_gpu_access() {
    echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    echo Setting GPU Access...

    if [[ $GPU_ACCESS == "user" ]]; then
        echo Adding current user: "$USER" to render,video group.

        $SUDO usermod -aG render,video "$USER"

        echo -e "\e[31m< System reboot may be required >\e[0m"

    elif [[ $GPU_ACCESS == "all" ]]; then
        echo Enabling GPU access for all users.

        if [ ! -d "/etc/udev/rules.d" ]; then
            $SUDO mkdir -p /etc/udev/rules.d
        fi

        if [ ! -f "/etc/udev/rules.d/70-amdgpu.rules" ]; then
            $SUDO touch "/etc/udev/rules.d/70-amdgpu.rules"
        fi

        if ! grep -q "drm" "/etc/udev/rules.d/70-amdgpu.rules"; then
            # add udev rule
            echo Adding udev rule.
            $SUDO tee -a /etc/udev/rules.d/70-amdgpu.rules <<EOF
KERNEL=="kfd", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
EOF
            $SUDO udevadm control --reload-rules && $SUDO udevadm trigger
        fi
    else
        print_err "Invalid GPU Access option."
    fi

    echo Setting GPU Access...Complete.
}

show_detected_gpu() {
    echo "========================================="
    echo "Detected GPU Information"
    echo "========================================="
    echo ""

    local detect_script="$INSTALLER_DIR/detect-gpu-gfx.sh"

    # Check if detection script exists
    if [[ ! -f "$detect_script" ]]; then
        echo "Error: GPU detection script not found."
        echo ""
        exit 1
    fi

    # Run detection and capture output
    local detected_output
    detected_output=$("$detect_script" --output all --unique 2>/dev/null)
    local detect_exit_code=$?

    if [[ $detect_exit_code -eq 0 ]] && [[ -n "$detected_output" ]]; then
        # Parse tab-separated output: name, device-id, revision, gfx
        echo "Detected AMD GPU(s):"
        echo ""

        local count=0
        while IFS=$'\t' read -r name device_id revision gfx; do
            count=$((count + 1))
            echo "  GPU $count:"
            echo "    Name       : $name"
            echo "    Device ID  : 0x$device_id"
            echo "    Revision   : 0x$revision"
            echo "    GFX Arch   : $gfx"
            echo ""
        done <<< "$detected_output"

        # Get unique GFX architectures
        local -a unique_gfx_list
        mapfile -t unique_gfx_list < <(echo "$detected_output" | cut -f4 | sort -u)

        if [[ ${#unique_gfx_list[@]} -eq 1 ]]; then
            echo "To install ROCm for detected GPU, use:"
            echo "  $PROG gfx=${unique_gfx_list[0]} rocm"
        else
            echo "To install ROCm for detected GPUs, use one of:"
            for gfx_arch in "${unique_gfx_list[@]}"; do
                echo "  $PROG gfx=$gfx_arch rocm"
            done
        fi
    else
        echo "Unable to detect AMD GPU."
    fi

    echo ""
    echo "========================================="
    exit 0
}

####### Main script ###############################################################

# Create the installer log directory
if [ ! -d "$RUN_INSTALLER_LOG_DIR" ]; then
    mkdir -p "$RUN_INSTALLER_LOG_DIR"
fi

exec > >(tee -a "$RUN_INSTALLER_CURRENT_LOG") 2>&1

echo =================================
echo ROCm INSTALLER
echo =================================

SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO="sudo"
SUDO_OPTS="$SUDO"
PROG=${0##*/}

os_release

echo "args: $*"
echo --------------------------------

# parse args
while (($#))
do
    case "$1" in
    help)
        usage
        exit 0
        ;;
    version)
        get_version
        exit 0
        ;;
    deps=*)
        DEPS_ARG="${1#*=}"
        DEPS_ARG2="$2"
        echo "Using Dependency args : $DEPS_ARG"
        if [[ $DEPS_ARG == "file" ]]; then
            echo "Using Dependency args2: $DEPS_ARG2"
        fi
        shift
        ;;
    amdgpu)
        AMDGPU_INSTALL=1
        AMDGPU_ARG="dkms"
        echo "Using amdgpu args : $AMDGPU_ARG"
        shift
        ;;
    amdgpu=*)
        AMDGPU_INSTALL=1
        AMDGPU_ARG="${1#*=}"
        echo "Using amdgpu args : $AMDGPU_ARG"
        shift
        ;;
    amdgpu-start)
        echo "Start amdgpu on install."
        AMDGPU_INSTALLER_ARGS="$AMDGPU_INSTALLER_ARGS start"
        shift
        ;;
    rocm)
        ROCM_INSTALL=1
        ROCM_ARG="all"
        # Only enable POST_ROCM_INSTALL if nopostrocm is not in the arguments
        if [[ ! " $* " =~ " nopostrocm " ]]; then
            POST_ROCM_INSTALL=1
            echo "Enabling Post ROCm install."
        fi
        echo "Using ROCm args : $ROCM_ARG"
        shift
        ;;
    rocm=*)
        ROCM_INSTALL=1
        ROCM_ARG="${1#*=}"
        echo "Using ROCm args : $ROCM_ARG"
        shift
        ;;
    graphics)
        USE_GRAPHICS=1
        echo "Enabling graphics support (amdgpu-lib)"
        shift
        ;;
    target=*)
        INSTALL_TARGET="${1#*=}"
        # Normalize path: remove trailing slashes (but preserve root /)
        if [[ "$INSTALL_TARGET" != "/" ]]; then
            INSTALL_TARGET="${INSTALL_TARGET%/}"
        fi
        echo Using install target location: "$INSTALL_TARGET"
        TARGET_ROCM_DIR="$INSTALL_TARGET"
        shift
        ;;
    gfx=*)
        INSTALL_GFX="${1#*=}"

        # Handle gfx=list to show available architectures
        if [[ "$INSTALL_GFX" == "list" ]]; then
            echo "========================================="
            echo "Available GFX Architectures"
            echo "========================================="

            # Get available architectures from installer
            read -r -a available_archs <<< "$(get_available_gfx_archs)"

            if [ ${#available_archs[@]} -gt 0 ]; then
                echo ""
                for arch in "${available_archs[@]}"; do
                    echo "  $arch"
                done
                echo ""
                echo "Usage: $PROG gfx=<arch> rocm"
                echo "Example: $PROG gfx=${available_archs[0]} rocm"

                # Show multi-arch capabilities
                if [[ "${INSTALLER_BUILD_TYPE:-}" == "multi-arch" ]]; then
                    echo ""
                    echo "Multi-arch installer supports:"
                    echo "  gfx=<arch>           - Install single architecture"
                    echo "  gfx=<arch1>,<arch2>  - Install multiple architectures"
                    echo "  gfx=all              - Install all available architectures"
                fi
            else
                echo ""
                echo "No GFX architectures found in installer."
                echo ""
            fi
            echo "========================================="
            exit 0
        fi

        # Handle gfx=show to display detected GPU information
        if [[ "$INSTALL_GFX" == "show" ]]; then
            show_detected_gpu
        fi

        # Skip parsing for special commands (list-installed handled after arg parsing)
        if [[ "$INSTALL_GFX" == "list-installed" ]]; then
            shift
            continue
        fi

        # Parse gfx argument (handles all, comma-list, single)
        if ! parse_gfx_argument "$INSTALL_GFX" GFX_INSTALL_LIST; then
            exit 1
        fi

        # Validate all GFX archs are available
        if ! validate_gfx_list "${GFX_INSTALL_LIST[@]}"; then
            exit 1
        fi

        USER_SPECIFIED_GFX=1

        # Display what will be installed
        if [[ ${#GFX_INSTALL_LIST[@]} -eq 1 ]]; then
            echo "Using GFX architecture: ${GFX_INSTALL_LIST[0]}"
            # Also set INSTALL_GFX for backward compatibility
            INSTALL_GFX="${GFX_INSTALL_LIST[0]}"
        else
            echo "Using ${#GFX_INSTALL_LIST[@]} GFX architectures: ${GFX_INSTALL_LIST[*]}"
            # Clear INSTALL_GFX for multi-GFX mode (we use GFX_INSTALL_LIST array instead)
            INSTALL_GFX=""
        fi

        shift
        ;;
    compo=*)
        COMPO_INSTALL="${1#*=}"

        # Handle compo=list to show available component categories
        if [[ "$COMPO_INSTALL" == "list" ]]; then
            echo "========================================="
            echo "Available Component Categories"
            echo "========================================="
            echo ""
            echo "  core         Core ROCm components (default)"
            echo "  core-dev     Core development components"
            echo "  dev-tools    Developer tools"
            echo "  core-sdk     Core SDK components"
            echo "  opencl       OpenCL runtime"
            echo "  test         Test packages (architecture-specific)"
            echo ""
            echo "Component categories can be combined with commas:"
            echo ""
            echo "Usage: $PROG compo=<category>[,<category>,...] gfx=<arch> rocm"
            echo ""
            echo "Examples:"
            echo "  $PROG compo=core gfx=gfx110x rocm"
            echo "  $PROG compo=core,dev-tools gfx=gfx110x rocm"
            echo "  $PROG compo=core-sdk gfx=gfx110x rocm"
            echo "  $PROG compo=core-sdk,test gfx=gfx110x rocm"
            echo "========================================="
            exit 0
        fi

        USER_SPECIFIED_COMPO=1
        echo Using component installation: "$COMPO_INSTALL"
        shift
        ;;
    force)
        FORCE_INSTALL=1
        echo "Forcing install."
        shift
        ;;
    postrocm)
        echo "Enabling Post ROCm install."
        POST_ROCM_INSTALL=1
        shift
        ;;
    nopostrocm)
        echo "Disabling Post ROCm install."
        POST_ROCM_INSTALL=0
        shift
        ;;
    gpu-access=*)
        GPU_ACCESS="${1#*=}"
        echo Setting GPU access: "$GPU_ACCESS"
        shift
        ;;
    findrocm)
        echo "Finding ROCm install."

        find_rocm_with_progress "all"

        if [[ $? -eq 1 ]]; then
            echo "ROCm Install not found."
            exit 1
        fi

        IFS=',' read -ra rocm_install <<< "$ROCM_INSTALLS"
        echo
        print_no_err "ROCm Installs found: ${#rocm_install[@]}"

        echo -e "\nChecking rocm installation type...\n"
        for inst in "${rocm_install[@]}"; do
            if check_rocm_package_install "$inst"; then
                echo "Runfile        : $inst"
            else
                echo "Package manager: $inst"
            fi

        done

        exit 0
        ;;
    manifest)
        list_components
        ;;
    manifest=*)
        GFX_FILTER="${1#*=}"
        list_components "$GFX_FILTER"
        ;;
    prompt)
        echo "Enabling user prompts."
        PROMPT_USER=1
        AMDGPU_INSTALLER_ARGS="prompt"
        shift
        ;;
    verbose)
        echo "Enabling verbose logging."
        VERBOSE=1
        RSYNC_OPTS_ROCM+="--itemize-changes -v "
        AMDGPU_INSTALLER_ARGS="$AMDGPU_INSTALLER_ARGS verbose"
        shift
        ;;
    uninstall-rocm)
        echo "Enabling Uninstall ROCm"
        UNINSTALL_ROCM=1

        DEPS_ARG=
        ROCM_INSTALL=0
        AMDGPU_INSTALL=0
        POST_ROCM_INSTALL=0
        GPU_ACCESS=
        shift
        ;;
    uninstall-amdgpu)
        echo "Enabling Uninstall amdgpu"
        UNINSTALL_AMDGPU=1

        DEPS_ARG=
        ROCM_INSTALL=0
        AMDGPU_INSTALL=0
        GPU_ACCESS=
        shift
        ;;
    *)
        print_err "Invalid argument: $1"
        echo "For usage: $PROG help"
        exit 1
        ;;
    esac
done

# Handle gfx=list-installed after all arguments are parsed (needs target= to be processed first)
if [[ "$INSTALL_GFX" == "list-installed" ]]; then
    echo "========================================="
    echo "Installed GFX Architectures"
    echo "========================================="

    # Set target directory (respects target= argument if provided)
    set_rocm_target

    # Detect installed ROCm version
    # shellcheck disable=SC2119  # No argument needed, uses TARGET_DIR default
    if ! detect_installed_rocm_version; then
        echo ""
        echo "No ROCm installation found at: $TARGET_DIR"
        echo ""
        echo "========================================="
        exit 1
    fi

    # Get installed GFX architectures
    installed_gfx=$(get_installed_gfx_archs)

    # Reconstruct installation directory for display
    rocm_install_dir="$TARGET_DIR/rocm/core-$ROCM_VER"

    echo ""
    echo "Installation directory: $rocm_install_dir"
    echo "ROCm version: $ROCM_VER"
    echo ""

    if [[ -n "$installed_gfx" ]]; then
        echo "Installed GFX architectures:"
        for arch in $installed_gfx; do
            echo "  $arch"
        done
    else
        echo "No GFX architectures installed (base-only installation)."
    fi

    echo ""
    echo "========================================="
    exit 0
fi

# Validate arguments
# Skip validate_gfx_arg for multi-GFX installations (already validated in gfx= parsing)
if [[ ${#GFX_INSTALL_LIST[@]} -eq 0 ]]; then
    validate_gfx_arg
fi
validate_compo_arg
validate_install_support

get_version

# Set up ROCm version information early if any ROCm operations are requested
if [[ $ROCM_INSTALL == 1 || $POST_ROCM_INSTALL == 1 || $UNINSTALL_ROCM == 1 ]]; then
    setup_rocm_version_info
fi

prompt_user "Start installation (y/n): "
if [[ $option == "N" || $option == "n" ]]; then
    echo "Exiting Installer."
    exit 1
fi

# Install/Check any dependencies
if [[ -n $DEPS_ARG ]]; then
    install_deps
fi

# Install ROCm components if required
if [[ $ROCM_INSTALL == 1 ]]; then
    install_rocm
fi

# Install/set any post install configuration
if [[ $POST_ROCM_INSTALL == 1 ]]; then
    install_post_rocm
fi

# Install AMDGPU components if required
if [[ $AMDGPU_INSTALL == 1 ]]; then
    install_amdgpu
fi

# Apply any GPU access requirements
if [[ -n $GPU_ACCESS ]]; then
    set_gpu_access
fi

# Uninstall if required
if [[ $UNINSTALL_ROCM == 1 ]]; then
    uninstall_rocm
fi

# Uninstall amdgpu if required
if [[ $UNINSTALL_AMDGPU == 1 ]]; then
    uninstall_amdgpu
fi

prompt_user "Exit installer (y/n): "
if [[ $option == "Y" || $option == "y" ]]; then
    echo "Exiting Installer."
fi

# Only print main installer log if ROCm operations were performed
# (AMDGPU-only operations already printed their own log)
if [[ $ROCM_INSTALL == 1 ]] || [[ $POST_ROCM_INSTALL == 1 ]] || [[ $UNINSTALL_ROCM == 1 ]] || [[ -n $DEPS_ARG ]]; then
    echo "Installer log stored in: $RUN_INSTALLER_CURRENT_LOG"
fi
