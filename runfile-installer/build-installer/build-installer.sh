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

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD_EXTRACT="yes"
BUILD_COMPRESS="yes"
BUILD_INSTALLER="yes"
BUILD_UI="yes"

BUILD_DIR=../build
BUILD_DIR_UI=../build-UI

VERSION_FILE="$SCRIPT_DIR/VERSION"

INSTALLER_VERSION=
ROCM_VER=
BUILD_NAME="local"
BUILD_RUNID="1"
BUILD_WORKFLOW_NUM="1"
BUILD_PULL_INFO="1"
BUILD_INSTALLER_NAME=

AMDGPU_DKMS_FILE="../rocm-installer/component-amdgpu/amdgpu-dkms-ver.txt"
AMDGPU_DKMS_BUILD_NUM=

EXTRACT_DIR="../rocm-installer"
EXTRACT_TYPE=""
EXTRACT_TYPE_DEB="nocontent"
EXTRACT_ROCM="yes"
EXTRACT_AMDGPU="yes"
EXTRACT_AMDGPU_MODE="all"

# AlmaLinux 8.10 (EL8) requires specific makeself options
MAKESELF_OPT="--notemp --threads $(nproc)"
MAKESELF_OPT_CLEANUP=
MAKESELF_OPT_HEADER="--header ./rocm-makeself-header-pre.sh --help-header ../rocm-installer/VERSION"
MAKESELF_OPT_TAR=""        # EL8 does not support GNU tar format
MAKESELF_COMPRESS_MODE=""  # Compression mode (set by mscomp: dev1, dev2, etc.)
MAKESELF_OPT_COMPRESS=""   # Compression setting used by makeself
XZ_COMPRESS_LEVEL=9        # XZ compression level (1-9, lower=faster/larger, higher=slower/smaller)

# Architecture family mapping (fine-grained → coarse)
# This will be populated dynamically based on PULL_CONFIG_RELEASE_TYPE
declare -A GFX_FAMILY_MAP

###### Functions ###############################################################

usage() {
cat <<END_USAGE
Usage: $PROG [options]

[options}:
    help                 = Display this help information.

    config=<file>        = Load configuration from file (command-line args override config).
                           Preset configs available in config/ directory:
                           - config/nightly.config
                           - config/prerelease.config
                           - config/release.config
                           - config/dev.config

                           NOTE: When running via build-runfile-installer.sh, the same config
                           is sourced by both parent and child scripts. Each script sources
                           independently, then applies command-line overrides.

    noextract            = Disable package extraction.
    norocm               = Disable ROCm package extraction.
    noamdgpu             = Disable AMDGPU package extraction.
    noextractcontent     = Disable package extraction content. (Extract only deps and scriptlets)
    noextractcontentdeb  = Disable DEB package extraction content. (Extract only deps and scriptlets)
    extractcontentdeb    = Enable DEB package extraction content. (Extract deps, scriptlets, and content)
    contentlist          = List all files extracted to content directories during package extraction.
    nocompress           = Disable component/test compression (skip compression step).
    norunfile            = Disable makeself build of installer runfile.
    nogui                = Disable GUI building.
    runfileonly          = Build only the .run file (implies noextract, nogui, nocompress).
                           Use this when only installer scripts changed and you want to rebuild the .run file quickly.
    noautodeps           = Disable automatic dependency resolution for RPM packages.
    buildname=<name>     = Set a name for the build (default: local).
    buildrunid=<id>      = Set the Runfile build run ID (default: 1).
    buildworkflow=<num>  = Set the build workflow number (default: 1).
    buildpullinfo=<info> = Set build pull information (default: 1).

    mscomp=<mode>        = Makeself compression mode (build speed vs file size):

                           Mode       Speed    Size      Compatibility    Use Case
                           ---------  -------  --------  ---------------  ------------------
                           hybrid     Slowest  Smallest  Universal        RECOMMENDED
                                      xz-9+xz-9 ~50-55%  (embedded xz)    ~7-8 GB installer
                                                                          Everything xz-9
                                                                          Max compression

                           hybriddev  Faster   Medium    Universal        Fast compression
                                      xz-3+xz-3 ~70-75%  (embedded xz)    ~9-10 GB installer
                                                                          Everything xz-3
                                                                          4-6x faster build

                           dev        5-6x     Larger    Universal        Development
                                      pigz -6  ~105%     (gzip)           Fast iteration

                           normal     Slow     Small     Universal        Standard default
                                      gzip -9  100%      (gzip)           Reliable baseline

                           nocomp     Fastest  Largest   Universal        Debugging only
                                      none     ~2000%    (no compress)    ~20-25 GB installer
                                                                          No compression
                                                                          Fast extraction

                           Universal (gzip/bzip2/embedded xz): Works on all Linux including minimal installs
                           Standard (xz): Requires xz-utils on target (may not be in minimal installs)

END_USAGE
}

get_coarse_family() {
    # Maps fine-grained arch to coarse family
    # Args: $1 = fine-grained arch (e.g., gfx1101)
    # Returns: coarse family (e.g., gfx110x) or input if no mapping

    local fine_arch="$1"

    # Check if mapping exists
    if [[ -n "${GFX_FAMILY_MAP[$fine_arch]}" ]]; then
        echo "${GFX_FAMILY_MAP[$fine_arch]}"
    else
        # No mapping, use as-is (future-proof for unknown archs)
        echo "$fine_arch"
    fi
}

initialize_gfx_family_map() {
    # Initialize GFX_FAMILY_MAP based on build type
    # - Single-arch (nightly): 1:1 mapping from ROCM_GFX_ARCHS
    # - Multi-arch (nightly-multiarch): Fine→coarse grouping

    # Clear any existing mappings
    GFX_FAMILY_MAP=()

    if [[ "${PULL_CONFIG_RELEASE_TYPE:-}" == "nightly-multiarch" ]] ; then
        # Multi-arch build: Use fine-grained → coarse family mappings
        echo "Initializing GFX_FAMILY_MAP for multi-arch build"
        GFX_FAMILY_MAP=(
            ["gfx900"]="gfx900"
            ["gfx906"]="gfx906"
            ["gfx908"]="gfx908"
            ["gfx90a"]="gfx90a"
            ["gfx942"]="gfx94x"
            ["gfx950"]="gfx950"
            ["gfx1010"]="gfx101x"
            ["gfx1011"]="gfx101x"
            ["gfx1012"]="gfx101x"
            ["gfx1030"]="gfx103x"
            ["gfx1031"]="gfx103x"
            ["gfx1032"]="gfx103x"
            ["gfx1033"]="gfx103x"
            ["gfx1034"]="gfx103x"
            ["gfx1035"]="gfx103x"
            ["gfx1036"]="gfx103x"
            ["gfx1100"]="gfx110x"
            ["gfx1101"]="gfx110x"
            ["gfx1102"]="gfx110x"
            ["gfx1103"]="gfx110x"
            ["gfx1150"]="gfx115x"
            ["gfx1151"]="gfx115x"
            ["gfx1152"]="gfx115x"
            ["gfx1153"]="gfx115x"
            ["gfx1200"]="gfx120x"
            ["gfx1201"]="gfx120x"
        )
    else
        # Single-arch build: Use 1:1 mapping from ROCM_GFX_ARCHS
        # Each architecture maps to itself
        echo "Initializing GFX_FAMILY_MAP for single-arch build"

        if [[ -n "${ROCM_GFX_ARCHS:-}" ]]; then
            for arch in "${ROCM_GFX_ARCHS[@]}"; do
                GFX_FAMILY_MAP["$arch"]="$arch"
            done
            echo "  Mapped ${#ROCM_GFX_ARCHS[@]} architectures from ROCM_GFX_ARCHS"
        else
            echo "  WARNING: ROCM_GFX_ARCHS not set, GFX_FAMILY_MAP will be empty"
        fi
    fi

    echo "  GFX_FAMILY_MAP initialized with ${#GFX_FAMILY_MAP[@]} entries"
}

os_release() {
    if [[ -r  /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release

        DISTRO_NAME=$ID
        DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
        DISTRO_MAJOR_VER=${DISTRO_VER%.*}

        case "$ID" in
        almalinux)
            BUILD_DISTRO_PACKAGE_TYPE=rpm
            # Special handling for AlmaLinux 8.10 (ManyLinux)
            if [[ "$DISTRO_MAJOR_VER" == "10" ]]; then
                DISTRO_TAG="el10"
                BUILD_OS=el10
            elif [[ "$DISTRO_MAJOR_VER" == "9" ]]; then
                DISTRO_TAG="el9"
                BUILD_OS=el9
            elif [[ "$DISTRO_MAJOR_VER" == "8" ]]; then
                DISTRO_TAG="el8"
                BUILD_OS=el8
                echo "Detected AlmaLinux $DISTRO_VER (ManyLinux)"
                echo "Disable makeself tar options for EL8."
                MAKESELF_OPT_HEADER="--header ./rocm-makeself-header-pre.sh --help-header ../rocm-installer/VERSION"
                MAKESELF_OPT_TAR=""
            else
                echo "ERROR: Unsupported AlmaLinux version: $DISTRO_VER"
                exit 1
            fi
            ;;
        *)
            echo "ERROR: $ID is not a supported OS"
            echo "Supported OS: AlmaLinux"
            exit 1
            ;;
        esac
    else
        echo "ERROR: /etc/os-release not found. Unsupported OS."
        exit 1
    fi

    echo "Build running on $DISTRO_NAME $DISTRO_VER (tag: $DISTRO_TAG)."
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

format_duration() {
    local duration=$1
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))

    local time_str=""
    if [[ $hours -gt 0 ]]; then
        time_str="${hours}h ${minutes}m ${seconds}s"
    else
        time_str="${minutes}m ${seconds}s"
    fi

    echo -e "\e[36m${time_str} (${duration} seconds)\e[0m"
}

show_compression_progress() {
    local archive_file=$1

    # Wait for archive file to be created
    while [[ ! -f "$archive_file" ]]; do
        sleep 0.5
    done

    # Show immediate feedback that compression has started
    printf "\r\033[K  Compressing..."

    local last_size=0
    local shown_initial=false

    # Loop until killed by parent process
    while true; do
        if [[ -f "$archive_file" ]]; then
            local current_size
            current_size=$(stat -c%s "$archive_file" 2>/dev/null || stat -f%z "$archive_file" 2>/dev/null || echo 0)

            local current_kb=$((current_size / 1024))

            # Show size as soon as we have any data
            if [[ $current_kb -gt 0 ]]; then
                if [[ $current_kb -ne $last_size ]]; then
                    printf "\r\033[K  Compressed: %s" "$(format_size "$current_size")"
                    last_size=$current_kb
                    shown_initial=true
                fi
            elif [[ "$shown_initial" == "false" ]]; then
                # Keep showing "Compressing..." while waiting for first data
                printf "\r\033[K  Compressing..."
            fi
        fi
        sleep 1
    done
}

read_config() {
    # Check for config= argument and source it BEFORE parsing other args
    # This allows command-line args to override config file values
    local CONFIG_FILE=""

    for arg in "$@"; do
        case "$arg" in
            config=*)
                CONFIG_FILE="${arg#*=}"
                break
                ;;
        esac
    done

    if [[ -n "$CONFIG_FILE" ]]; then
        echo -------------------------------------------------------------
        echo "Loading configuration from: $CONFIG_FILE"

        # Check if file exists
        if [[ ! -f "$CONFIG_FILE" ]]; then
            echo -e "\e[31mERROR: Config file not found: $CONFIG_FILE\e[0m"
            exit 1
        fi

        # Check if file is readable
        if [[ ! -r "$CONFIG_FILE" ]]; then
            echo -e "\e[31mERROR: Config file not readable: $CONFIG_FILE\e[0m"
            exit 1
        fi

        # Source the config file
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        echo "Configuration loaded successfully."
        echo "Note: Command-line arguments will override config values."
        echo -------------------------------------------------------------
    fi
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

write_version() {
    echo -------------------------------------------------------------
    echo Setting version and build info...

    get_version

    # Set the runfile installer name
    BUILD_INSTALLER_NAME="rocm-installer-$ROCM_VER-$BUILD_NAME-$BUILD_WORKFLOW_NUM"

    # get the amdgpu-dkms build/version info
    if [ -f "$AMDGPU_DKMS_FILE" ]; then
        AMDGPU_DKMS_BUILD_NUM=$(cat "$AMDGPU_DKMS_FILE")
    fi

    echo "INSTALLER_VERSION        = $INSTALLER_VERSION"
    echo "ROCM_VER                 = $ROCM_VER"
    echo "BUILD_NAME               = $BUILD_NAME"
    echo "BUILD_RUNID              = $BUILD_RUNID"
    echo "BUILD_WORKFLOW_NUM       = $BUILD_WORKFLOW_NUM"
    echo "BUILD_PULL_INFO          = $BUILD_PULL_INFO"
    echo "AMDGPU_DKMS_BUILD_NUM    = $AMDGPU_DKMS_BUILD_NUM"

    # Update the version file
    {
        echo "$INSTALLER_VERSION"
        echo "$ROCM_VER"
        echo "$BUILD_PULL_INFO"
        echo "$BUILD_RUNID"
        echo "$BUILD_WORKFLOW_NUM"
        echo "$AMDGPU_DKMS_BUILD_NUM"
    } > "$VERSION_FILE"

    # Copy VERSION file to rocm-installer directory for makeself --help-header
    cp "$VERSION_FILE" "$EXTRACT_DIR/VERSION"

    echo "Installer name: $BUILD_INSTALLER_NAME"
}

print_directory_size() {
    local dir_path="$1"
    local dir_name="${2:-$(basename "$dir_path")}"
    local size_kb
    local size

    if [ -d "$dir_path" ]; then
        size_kb=$(du -sk "$dir_path" 2>/dev/null | awk '{print $1}')
        if [ -n "$size_kb" ]; then
            size=$(format_size $((size_kb * 1024)))
            echo "  Directory size: $size ($dir_name)"
        fi
    fi
}

generate_component_lists() {
    echo -------------------------------------------------------------
    echo Generating GFX architecture lists from GFX_FAMILY_MAP...

    local all_archs=()
    local -A coarse_families
    local is_multiarch=false

    # Detect build type by checking if we have actual fine→coarse grouping
    # Multi-arch: gfx1100→gfx110x (fine != coarse)
    # Single-arch: gfx110x→gfx110x (fine == coarse) or no mapping
    for fine_arch in "${!GFX_FAMILY_MAP[@]}"; do
        local coarse="${GFX_FAMILY_MAP[$fine_arch]}"
        if [[ "$fine_arch" != "$coarse" ]]; then
            is_multiarch=true
            break
        fi
    done

    if [[ "$is_multiarch" == "true" ]]; then
        # Multi-arch build: Only expose fine-grained archs to users
        # Coarse families (gfx110x, gfx94x) are internal for compression
        echo "Build type: Multi-arch (fine-grained architectures)"
        for fine_arch in "${!GFX_FAMILY_MAP[@]}"; do
            all_archs+=("$fine_arch")
        done
    else
        # Single-arch build: Expose coarse families to users
        # This is what packages are built for in single-arch
        echo "Build type: Single-arch (coarse family architectures)"
        for arch in "${!GFX_FAMILY_MAP[@]}"; do
            all_archs+=("$arch")
            coarse_families["${GFX_FAMILY_MAP[$arch]}"]=1
        done
        # Add unique coarse families
        for coarse in "${!coarse_families[@]}"; do
            all_archs+=("$coarse")
        done
    fi

    # Create space-separated list (sorted)
    GFX_LIST=$(printf '%s\n' "${all_archs[@]}" | sort -u | tr '\n' ' ' | sed 's/ *$//')

    # Component categories are fixed (defined in rocm-installer.sh)
    COMPO_LIST="core core-dev dev-tools core-sdk opencl"

    echo "GFX architectures: ${GFX_LIST:-<none>}"
    echo "Component categories: $COMPO_LIST"

    # Write .gfx-lists file to component-rocm directory
    echo "Writing .gfx-lists file..."
    local gfx_lists_file="../rocm-installer/component-rocm/.gfx-lists"

    # Determine build type
    local installer_build_type="single-arch"
    if [[ "$is_multiarch" == "true" ]]; then
        installer_build_type="multi-arch"
    fi

    # Write file header and base variables
    cat > "$gfx_lists_file" << EOF
#!/bin/bash
# Auto-generated GFX architecture mappings
# Generated during build, used by installer and build scripts

# All available architectures (fine-grained + coarse families)
GFX_ARCHS_AVAILABLE="$GFX_LIST"

# Build type: single-arch or multi-arch
# - single-arch: Users select coarse families (gfx110x, gfx1150, etc.)
# - multi-arch: Users select fine-grained archs (gfx1100, gfx1101, etc.)
INSTALLER_BUILD_TYPE="$installer_build_type"

# Fine-grained to coarse family mapping
declare -A GFX_FINE_TO_COARSE=(
EOF

    # Write fine→coarse mappings
    for fine_arch in "${!GFX_FAMILY_MAP[@]}"; do
        local coarse_family="${GFX_FAMILY_MAP[$fine_arch]}"
        echo "    [\"$fine_arch\"]=\"$coarse_family\"" >> "$gfx_lists_file"
    done

    # Write coarse→fine mapping header
    cat >> "$gfx_lists_file" << 'EOF'
)

# Coarse family to fine-grained members mapping
declare -A GFX_COARSE_TO_FINE=(
EOF

    # Build and write coarse→fine mappings
    local -A coarse_members
    for fine_arch in "${!GFX_FAMILY_MAP[@]}"; do
        local coarse_family="${GFX_FAMILY_MAP[$fine_arch]}"
        if [[ -n "${coarse_members[$coarse_family]}" ]]; then
            coarse_members[$coarse_family]+=" $fine_arch"
        else
            coarse_members[$coarse_family]="$fine_arch"
        fi
    done

    for coarse_family in "${!coarse_members[@]}"; do
        echo "    [\"$coarse_family\"]=\"${coarse_members[$coarse_family]}\"" >> "$gfx_lists_file"
    done

    echo ")" >> "$gfx_lists_file"

    echo "  Written: $gfx_lists_file"
}

generate_headers() {
    echo -------------------------------------------------------------
    echo Generating makeself header with embedded component lists...

    # Generate makeself header (used for all AlmaLinux versions)
    if [ -f "rocm-makeself-header-pre.sh.template" ]; then
        sed -e "s|@@GFX_ARCHS_LIST@@|$GFX_LIST|g" \
            -e "s|@@COMPONENTS_LIST@@|$COMPO_LIST|g" \
            rocm-makeself-header-pre.sh.template > rocm-makeself-header-pre.sh
        echo "Generated: rocm-makeself-header-pre.sh (embedded GFX_ARCHS_AVAILABLE)"
    else
        echo "ERROR: rocm-makeself-header-pre.sh.template not found!"
        exit 1
    fi
}

install_makeself() {
    echo ----------------------
    echo "Installing makeself..."

    # Check if makeself command is already available
    if command -v makeself &> /dev/null; then
        local makeself_version
        makeself_version=$(makeself --version)
        echo -e "\e[32mmakeself already installed\e[0m"
        echo -e "\e[32mVersion: $makeself_version\e[0m"
        return 0
    fi

    # Try to install from package manager first
    echo "Attempting to install makeself from package manager..."
    if [ "$BUILD_DISTRO_PACKAGE_TYPE" == "deb" ]; then
        $SUDO apt-get install -y makeself
    elif [ "$BUILD_DISTRO_PACKAGE_TYPE" == "rpm" ]; then
        $SUDO dnf install -y makeself
    fi

    # Check if package manager install succeeded
    if command -v makeself &> /dev/null; then
        local makeself_version
        makeself_version=$(makeself --version)
        echo -e "\e[32mmakeself installed successfully from package manager\e[0m"
        echo -e "\e[32mVersion: $makeself_version\e[0m"
        return 0
    fi

    # Package manager install failed, download and install from GitHub
    echo "Package manager install failed. Downloading makeself from GitHub..."

    local makeself_ver="2.4.5"
    local makeself_url="https://github.com/megastep/makeself/releases/download/release-$makeself_ver/makeself-$makeself_ver.run"

    # Download the makeself package
    echo "Downloading makeself package from github..."
    if ! wget -q "$makeself_url"; then
        echo -e "\e[31mmakeself package not found: $makeself_url.\e[0m"
        exit 1
    fi

    $SUDO chmod +x "makeself-$makeself_ver.run"

    # Install the makeself package
    echo "Installing makeself package..."
    bash "makeself-$makeself_ver.run"

    # Clean up
    echo "Cleaning up..."
    rm -f makeself-$makeself_ver.run

    # Add makeself to PATH
    echo "Adding makeself to PATH..."
    $SUDO ln -sf "$PWD/makeself-$makeself_ver/makeself.sh" /usr/local/bin/makeself

    echo Installing makeself...Complete
}

install_pigz() {
    echo ----------------------
    echo -e "\e[32mInstalling pigz (parallel gzip)...\e[0m"

    # Check if pigz is already installed
    if command -v pigz &> /dev/null; then
        echo "pigz is already installed: $(pigz --version 2>&1 | head -1)"
        return 0
    fi

    # Install pigz for AlmaLinux (build system)
    # Note: Creates gzip-compatible archives that decompress with standard gzip on ANY target system
    if [[ "$DISTRO_NAME" != "almalinux" ]]; then
        echo -e "\e[93mWARNING: Build system must be AlmaLinux.\e[0m"
        echo "Falling back to standard gzip compression"
        return 1
    fi

    echo "Installing pigz via dnf..."
    $SUDO dnf install -y pigz

    # Verify installation
    if command -v pigz &> /dev/null; then
        echo "pigz installed successfully: $(pigz --version 2>&1 | head -1)"
        echo "Target system requirement: gzip (universally available)"
        return 0
    else
        echo -e "\e[93mWARNING: pigz installation failed.\e[0m"
        return 1
    fi
}

install_ncurses_el() {
    echo Installing ncurses libraries...

    # Check if ncurses-devel is already installed
    if rpm -q ncurses-devel > /dev/null 2>&1; then
        echo "ncurses-devel already installed"
    else
        echo "Installing ncurses-devel"
        $SUDO dnf install -y ncurses-devel
    fi

    # For AlmaLinux 8, install ncurses-static from devel repo
    if [[ $DISTRO_NAME == "almalinux" ]] && [[ $DISTRO_VER == 8* ]]; then
        # Check if ncurses-static is already installed
        if rpm -q ncurses-static > /dev/null 2>&1; then
            echo "ncurses-static already installed"
        else
            echo "Installing ncurses-static for AlmaLinux 8..."

            # Create AlmaLinux Devel repository configuration
            echo "Creating AlmaLinux Devel repository configuration..."
            $SUDO tee /etc/yum.repos.d/almalinux-devel.repo > /dev/null <<'EOF'
[devel]
name=AlmaLinux $releasever - Devel
baseurl=https://repo.almalinux.org/almalinux/$releasever/devel/$basearch/os/
enabled=1
gpgcheck=1
countme=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux
metadata_expire=86400
enabled_metadata=1
EOF

            echo "Devel repository configuration created."

            # Force metadata refresh
            echo "Refreshing repository metadata..."
            $SUDO dnf clean metadata
            $SUDO dnf makecache

            # Check if package is now available
            echo "Checking if ncurses-static is available..."
            dnf list ncurses-static || echo "WARNING: ncurses-static not found in package lists"

            # Install from devel repository
            echo "Installing ncurses-static from devel repository..."
            $SUDO dnf install -y ncurses-static || {
                echo "ERROR: Failed to install ncurses-static"
                return 1
            }

            # Verify installation
            if rpm -q ncurses-static >/dev/null 2>&1; then
                echo "SUCCESS: ncurses-static installed from devel repository"
            else
                echo "ERROR: ncurses-static package not found after installation"
                return 1
            fi
        fi
    else
        # For other EL distros, check if ncurses-static is already installed
        if rpm -q ncurses-static > /dev/null 2>&1; then
            echo "ncurses-static already installed"
        else
            echo "Installing ncurses-static..."
            $SUDO dnf install -y ncurses-static || echo "WARNING: ncurses-static not available"
        fi
    fi

    # Verify static libraries
    if [ ! -f /usr/lib64/libncurses.a ]; then
        echo "ERROR: Static ncurses library not found after installation."
        echo "Location checked: /usr/lib64/libncurses.a"
        echo "Build will fail. Please install ncurses-static manually."
        return 1
    else
        echo "SUCCESS: Static ncurses library found: /usr/lib64/libncurses.a"
    fi

    echo Installing ncurses libraries...Complete
}

install_tools_el(){
    echo Installing EL tools...

    # Define required tools to check (command names)
    local required_cmds=(wget ar tar rpmbuild cpio dpkg cmake gcc g++)

    # Define packages to install (package names)
    local required_pkgs=(wget binutils tar rpm-build cpio dpkg cmake gcc gcc-c++)

    # Check if all required tools are already installed
    local all_installed=1
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            all_installed=0
            break
        fi
    done

    if [ $all_installed -eq 1 ]; then
        echo "All core build tools are already installed"
    else
        # One or more tools missing, install all
        echo "Installing core build tools: ${required_pkgs[*]}"
        $SUDO dnf install -y "${required_pkgs[@]}"
    fi

    # Install ncurses libraries (only if UI build is enabled)
    if [ "$BUILD_UI" == "yes" ]; then
        install_ncurses_el
    else
        echo "Skipping ncurses installation (GUI build disabled)"
    fi

    if [[ $DISTRO_NAME == "amzn" ]]; then
        # Amazon Linux may need additional packages
        if ! command -v bzip2 &> /dev/null; then
            $SUDO dnf install -y tar bzip2
        fi
    fi

    # Install makeself for .run creation (only if runfile build is enabled)
    if [ "$BUILD_INSTALLER" == "yes" ]; then
        install_makeself

        # Check the version of makeself and enable cleanup script support if >= 2.4.2
        makeself_version_min=2.4.2
        makeself_version=$(makeself --version)
        makeself_version=${makeself_version#Makeself version }

        if [[ "$(printf '%s\n' "$makeself_version_min" "$makeself_version" | sort -V | head -n1)" = "$makeself_version_min" ]]; then
            MAKESELF_OPT_CLEANUP+="--cleanup ../rocm-installer/cleanup-install.sh"
            echo Enabling cleanup script support.
        fi
    else
        echo "Skipping makeself installation (runfile build disabled)"
    fi

    echo Installing EL tools...Complete
}

install_tools() {
    echo -------------------------------------------------------------
    echo "Installing tools for $DISTRO_NAME $DISTRO_VER..."
    install_tools_el
    echo Installing tools...Complete
}

configure_compression() {
    echo -------------------------------------------------------------
    echo Configuring makeself compression...

    case "$MAKESELF_COMPRESS_MODE" in
        hybrid)
            # Hybrid: everything=xz-9, embedded xz-static, maximum compression
            HYBRID_COMPRESSION="yes"
            HYBRID_ALL_XZ="yes"
            XZ_COMPRESS_LEVEL=9
            MAKESELF_OPT_COMPRESS="--nocomp"
            echo "Compression: Hybrid (everything compressed with xz level 9)"
            ;;
        hybriddev)
            # Hybrid Dev: everything=xz-3, embedded xz-static, fast compression
            HYBRID_COMPRESSION="yes"
            HYBRID_ALL_XZ="yes"
            XZ_COMPRESS_LEVEL=3
            MAKESELF_OPT_COMPRESS="--nocomp"
            echo "Compression: Hybrid Dev (everything compressed with xz level 3)"
            ;;
        dev)
            # Install and use pigz with compression level 6 (balanced)
            # SAFE: gzip-compatible, works on all target systems
            if install_pigz; then
                MAKESELF_OPT_COMPRESS="--pigz --complevel 6"
                echo "Compression: Pigz level 6 (fast, universal gzip-compatible)"
            else
                MAKESELF_OPT_COMPRESS="--complevel 6"
                echo "Compression: Gzip level 6 (pigz not available, universal)"
            fi
            ;;
        normal)
            # Explicit normal: standard gzip with level 9 (maximum compression)
            # SAFE: Universal compatibility
            MAKESELF_OPT_COMPRESS=""
            echo "Compression: Gzip level 9 (normal, universal)"
            ;;
        nocomp)
            # No compression: fastest extraction, largest file size
            # For debugging purposes only - not recommended for production
            # Does NOT set HYBRID_COMPRESSION, so no internal archives are created
            MAKESELF_OPT_COMPRESS="--nocomp"
            echo "Compression: None (debugging mode - WARNING: very large installer ~20-25 GB)"
            echo "  - Makeself: no compression (fastest build and extraction)"
            echo "  - Internal archives: NOT created (all content left uncompressed)"
            ;;
        "")
            # No argument: standard gzip with level 9 (maximum compression)
            # SAFE: Universal compatibility
            MAKESELF_OPT_COMPRESS=""
            echo "Compression: Gzip level 9 (normal, universal)"
            ;;
        *)
            echo -e "\e[31mERROR: Invalid compression mode: $MAKESELF_COMPRESS_MODE\e[0m"
            exit 1
            ;;
    esac
}

extract_rocm_packages_deb() {
    echo "Extracting ROCm DEB packages for $BUILD_OS..."

    # Extract all ROCm DEB packages (common and gfx-specific)
    # The extractor script will auto-detect all packages-rocm*-deb directories
    echo "Extracting ROCm DEB packages (common and gfx-specific)..."

    if [ $BUILD_DISTRO_PACKAGE_TYPE == "rpm" ]; then
        # On RPM-based systems, use nodpkg extractor and extract to separate directory
        if [[ -z "$EXTRACT_TYPE_DEB" ]]; then
            echo "Using nodpkg extractor for RPM-based system (full extraction)"
        else
            echo "Using nodpkg extractor for RPM-based system ($EXTRACT_TYPE_DEB mode)"
        fi
        PACKAGE_ROCM_DIR="$PWD/packages-rocm-deb" EXTRACT_FORMAT=deb ./package-extractor-debs-nodpkg.sh rocm ext-rocm="../rocm-installer/component-rocm-deb" $EXTRACT_TYPE_DEB
        extract_status=$?
    else
        # On DEB-based systems, use standard extractor
        # shellcheck disable=SC2086  # EXTRACT_TYPE intentionally unquoted for word splitting
        PACKAGE_ROCM_DIR="$PWD/packages-rocm-deb" EXTRACT_FORMAT=deb ./package-extractor-debs.sh rocm ext-rocm="../rocm-installer/component-rocm" $EXTRACT_TYPE
        extract_status=$?
    fi

    if [[ $extract_status -ne 0 ]]; then
        echo -e "\e[31mFailed extraction of ROCm DEB packages.\e[0m"
        exit 1
    fi

    echo "ROCm DEB package extraction complete."
    if [ $BUILD_DISTRO_PACKAGE_TYPE == "rpm" ]; then
        print_directory_size "../rocm-installer/component-rocm-deb" "component-rocm-deb"
    else
        print_directory_size "../rocm-installer/component-rocm" "component-rocm"
    fi
}

extract_amdgpu_packages_deb() {
    echo "Extracting AMDGPU DEB packages for $BUILD_OS (tag: $DISTRO_TAG)..."

    # AMDGPU packages are stored in subdirectories: packages-amdgpu/<DISTRO_TAG>
    AMDGPU_PKG_DIR="packages-amdgpu/${DISTRO_TAG}"

    # Verify AMDGPU package directory exists
    if [ ! -d "$AMDGPU_PKG_DIR" ]; then
        echo -e "\e[31mERROR: $AMDGPU_PKG_DIR directory not found!\e[0m"
        echo "Please run setup-installer.sh first to download AMDGPU packages."
        exit 1
    fi

    # Extract the AMDGPU packages to component-amdgpu/<DISTRO_TAG>
    if ! PACKAGE_AMDGPU_DIR="$PWD/$AMDGPU_PKG_DIR" EXTRACT_FORMAT=deb ./package-extractor-debs.sh amdgpu ext-amdgpu="${EXTRACT_DIR}/component-amdgpu/${DISTRO_TAG}"; then
        echo -e "\e[31mFailed extraction of AMDGPU DEB packages.\e[0m"
        exit 1
    fi

    echo "AMDGPU DEB package extraction complete."
    print_directory_size "${EXTRACT_DIR}/component-amdgpu/${DISTRO_TAG}" "component-amdgpu/${DISTRO_TAG}"
}

extract_rocm_packages_rpm() {
    echo "Extracting ROCm RPM packages for $BUILD_OS..."

    # Extract all ROCm RPM packages (common and gfx-specific)
    # The extractor script will auto-detect all packages-rocm*-rpm directories
    echo "Extracting ROCm RPM packages (common and gfx-specific)..."

    # Build extractor arguments with auto dependency resolution if build config is available
    local extractor_args="rocm ext-rocm=../rocm-installer $EXTRACT_TYPE"

    # Check if automatic dependency resolution is disabled
    if [[ "$DISABLE_AUTO_DEPS" == "yes" ]]; then
        echo "Automatic dependency resolution disabled (noautodeps flag specified)"
    else
        # Check for a ROCm RPM build config file for auto dependency resolution
        # Note: We're already in package-extractor/ directory due to pushd in extract_packages()
        # Use relative path since it works both on host and inside containers (docker/chroot)
        local rocm_rpm_config
        rocm_rpm_config=$(find ../build-config -name "rocm-*-rpm.config" -type f 2>/dev/null | sort -r | head -1)

        if [[ -n "$rocm_rpm_config" ]] && [[ -f "$rocm_rpm_config" ]]; then
            # Don't quote the path here - let it be quoted when passed as individual argument
            extractor_args+=" resolveautodeps build-config=$rocm_rpm_config"
            echo "Enabling automatic dependency resolution with: $rocm_rpm_config"
        else
            echo "No ROCm RPM build config found - skipping automatic dependency resolution"
        fi
    fi

    # shellcheck disable=SC2086  # extractor_args intentionally unquoted for word splitting
    if ! PACKAGE_ROCM_DIR="$PWD/packages-rocm-rpm" EXTRACT_FORMAT=rpm ./package-extractor-rpms.sh $extractor_args; then
        echo -e "\e[31mFailed extraction of ROCm RPM packages.\e[0m"
        exit 1
    fi

    echo "ROCm RPM package extraction complete."
    print_directory_size "../rocm-installer/component-rocm" "component-rocm"
}

extract_amdgpu_packages_rpm() {
    echo "Extracting AMDGPU RPM packages for $BUILD_OS (tag: $DISTRO_TAG)..."

    # AMDGPU packages are stored in subdirectories: packages-amdgpu/<DISTRO_TAG>
    AMDGPU_PKG_DIR="packages-amdgpu/${DISTRO_TAG}"

    # Verify AMDGPU package directory exists
    if [ ! -d "$AMDGPU_PKG_DIR" ]; then
        echo -e "\e[31mERROR: $AMDGPU_PKG_DIR directory not found!\e[0m"
        echo "Please run setup-installer.sh first to download AMDGPU packages."
        exit 1
    fi

    # Extract the AMDGPU packages to component-amdgpu/<DISTRO_TAG>
    if ! PACKAGE_AMDGPU_DIR="$PWD/$AMDGPU_PKG_DIR" EXTRACT_FORMAT=rpm ./package-extractor-rpms.sh amdgpu ext-amdgpu="${EXTRACT_DIR}/component-amdgpu/${DISTRO_TAG}"; then
        echo -e "\e[31mFailed extraction of AMDGPU RPM packages.\e[0m"
        exit 1
    fi

    echo "AMDGPU RPM package extraction complete."
    print_directory_size "${EXTRACT_DIR}/component-amdgpu/${DISTRO_TAG}" "component-amdgpu/${DISTRO_TAG}"
}

extract_amdgpu_packages_all() {
    echo "Extracting AMDGPU packages for all distros..."

    # AMDGPU packages are stored in subdirectories: packages-amdgpu/<distro_tag>
    # Find all subdirectories in packages-amdgpu/
    if [ ! -d "packages-amdgpu" ]; then
        echo -e "\e[31mERROR: packages-amdgpu directory not found!\e[0m"
        echo "Please run setup-installer.sh amdgpu-mode=all first to download AMDGPU packages for all distros."
        exit 1
    fi

    # Find all distro subdirectories
    local amdgpu_dirs=(packages-amdgpu/*/)

    if [ ${#amdgpu_dirs[@]} -eq 0 ] || [ ! -d "${amdgpu_dirs[0]}" ]; then
        echo -e "\e[31mERROR: No distro subdirectories found in packages-amdgpu/!\e[0m"
        echo "Please run setup-installer.sh amdgpu-mode=all first to download AMDGPU packages for all distros."
        exit 1
    fi

    echo "Found ${#amdgpu_dirs[@]} AMDGPU package directories to extract"

    # Extract packages from each distro-specific subdirectory
    for amdgpu_dir in "${amdgpu_dirs[@]}"; do
        # Remove trailing slash
        amdgpu_dir="${amdgpu_dir%/}"

        if [ -d "$amdgpu_dir" ]; then
            # Extract distro tag from directory name (e.g., packages-amdgpu/el8 -> el8)
            local distro_tag
            distro_tag="$(basename "$amdgpu_dir")"

            echo "Extracting AMDGPU packages from $amdgpu_dir (tag: $distro_tag)..."

            # Extract the AMDGPU packages to component-amdgpu/<distro_tag>
            if ! PACKAGE_AMDGPU_DIR="$PWD/$amdgpu_dir" ./package-extractor-all.sh amdgpu pkgs-amdgpu="$PWD/$amdgpu_dir" ext-amdgpu="${EXTRACT_DIR}/component-amdgpu/${distro_tag}"; then
                echo -e "\e[31mFailed extraction of AMDGPU packages from $amdgpu_dir.\e[0m"
                exit 1
            fi

            print_directory_size "${EXTRACT_DIR}/component-amdgpu/${distro_tag}" "component-amdgpu/${distro_tag}"
        fi
    done

    echo "AMDGPU-all package extraction complete."
    print_directory_size "${EXTRACT_DIR}/component-amdgpu" "component-amdgpu (total)"
}

extract_packages_rocm() {
    echo "Extracting ROCm packages..."

    if [ $EXTRACT_ROCM != "yes" ]; then
        echo "ROCm package extraction disabled."
        return
    fi

    # Check for RPM packages and extract if present
    if [ -d "packages-rocm-rpm" ]; then
        extract_rocm_packages_rpm
    fi

    # Check for DEB packages and extract if present
    if [ -d "packages-rocm-deb" ]; then
        extract_rocm_packages_deb
        echo disable DEB extraction.
    fi
}

extract_packages_amdgpu() {
    echo "Extracting AMDGPU packages..."

    # Check if AMDGPU extraction is enabled
    if [ $EXTRACT_AMDGPU == "yes" ]; then
        # Extract AMDGPU packages based on mode
        if [ $EXTRACT_AMDGPU_MODE == "all" ]; then
            # Extract AMDGPU-all packages (all distros)
            extract_amdgpu_packages_all
        else
            # Extract distro-specific AMDGPU packages
            if [ $BUILD_DISTRO_PACKAGE_TYPE == "deb" ]; then
                extract_amdgpu_packages_deb
            elif [ $BUILD_DISTRO_PACKAGE_TYPE == "rpm" ]; then
                extract_amdgpu_packages_rpm
            else
                echo -e "\e[31mERROR: Invalid Distro Package Type: $BUILD_DISTRO_PACKAGE_TYPE\e[0m"
                exit 1
            fi
        fi
    else
        echo "AMDGPU package extraction disabled."
    fi
}

extract_packages() {
    echo -------------------------------------------------------------
    echo Running Package Extractor...

    if [ $BUILD_EXTRACT == "yes" ]; then
        pushd ../package-extractor || exit

        # Extract ROCm packages
        extract_packages_rocm

        # Extract AMDGPU packages
        extract_packages_amdgpu

        popd || exit
    else
        echo Extract Packages disabled.
    fi

    echo Running Package Extractor...Complete
}

compress_directory() {
    # Wrapper function for component-compressor.sh helper
    # Usage: compress_directory <source_dir> <output_archive> [compression_type] [xz_level]
    #
    # Parameters:
    #   source_dir       - Directory to compress (relative or absolute path)
    #   output_archive   - Output archive filename (e.g., "content-base.tar.xz")
    #   compression_type - Optional: "xz", "pigz", or "auto" (default: auto)
    #   xz_level         - Optional: XZ compression level 1-9 (default: XZ_COMPRESS_LEVEL)
    #
    # Returns: 0 on success, 1 on failure

    local source_dir="$1"
    local output_archive="$2"
    local compression_type="${3:-auto}"
    local xz_level="${4:-$XZ_COMPRESS_LEVEL}"

    # Call component-compressor.sh helper with all parameters including HYBRID_ALL_XZ
    if "$SCRIPT_DIR/component-compressor.sh" "$source_dir" "$output_archive" "$compression_type" "$xz_level" "$HYBRID_ALL_XZ"; then
        return 0
    else
        return 1
    fi
}

compress_setup() {
    echo "-------------------------------------------------------------"
    echo "Setting up compression tools..."
    echo "-------------------------------------------------------------"

    local INSTALLER_DIR="../rocm-installer"
    local XZ_STATIC_SRC="$SCRIPT_DIR/tools/xz-static"
    local XZ_STATIC_DEST="$INSTALLER_DIR/bin/xz-static"

    # Create bin directory for embedded xz
    mkdir -p "$INSTALLER_DIR/bin"

    # Check for static xz binary and validate it's truly static
    local need_rebuild=0

    if [[ ! -f "$XZ_STATIC_SRC" ]]; then
        echo "xz-static not found, will build from source..."
        need_rebuild=1
    elif ldd "$XZ_STATIC_SRC" 2>&1 | grep -qv "not a dynamic executable"; then
        echo "xz-static exists but is dynamically linked, rebuilding for static..."
        need_rebuild=1
    fi

    if [[ $need_rebuild -eq 1 ]]; then
        echo ""
        if [[ -f "$SCRIPT_DIR/tools/build-xz-static.sh" ]]; then
            cd "$SCRIPT_DIR/tools" || exit 1

            # Remove old binary if it exists
            rm -f xz-static

            # Set environment variable to indicate non-interactive build
            export XZ_STATIC_NONINTERACTIVE=1

            if ./build-xz-static.sh; then
                echo ""
                echo -e "\e[32mxz-static built successfully.\e[0m"
                cd - >/dev/null || exit
            else
                echo -e "\e[31mERROR: Failed to build xz-static\e[0m"
                cd - >/dev/null || exit
                exit 1
            fi
        else
            echo -e "\e[31mERROR: build-xz-static.sh script not found\e[0m"
            exit 1
        fi
        echo ""
    fi

    # Copy static xz binary to installer
    echo "Embedding static xz binary..."
    cp "$XZ_STATIC_SRC" "$XZ_STATIC_DEST"
    chmod +x "$XZ_STATIC_DEST"

    local xz_bytes
    local xz_size

    xz_bytes=$(stat -c%s "$XZ_STATIC_DEST" 2>/dev/null || stat -f%z "$XZ_STATIC_DEST" 2>/dev/null)
    xz_size=$(format_size "$xz_bytes")
    echo "  xz-static embedded: $xz_size"

    # Verify it's actually static
    if ldd "$XZ_STATIC_DEST" 2>&1 | grep -q "not a dynamic executable"; then
        echo -e "  \e[32mBinary is statically linked (no dependencies).\e[0m"
    else
        echo -e "\e[93m  WARNING: xz binary may have dynamic dependencies.\e[0m"
    fi

    echo "Compression setup complete."
    echo ""
}

compress_tests() {
    echo "-------------------------------------------------------------"
    echo "Compressing tests..."
    echo "-------------------------------------------------------------"

    local INSTALLER_DIR="../rocm-installer"
    cd "$INSTALLER_DIR" || exit 1

    # Find all GFX architectures with test packages
    local gfx_archs=()
    if [[ -d "component-rocm/content" ]]; then
        for arch_dir in component-rocm/content/*/; do
            if [[ -d "$arch_dir" ]]; then
                local arch_name
                arch_name=$(basename "$arch_dir")

                # Check if this arch has any test packages
                if compgen -G "$arch_dir*test*" > /dev/null; then
                    gfx_archs+=("$arch_name")
                fi
            fi
        done
    fi

    if [[ ${#gfx_archs[@]} -eq 0 ]]; then
        echo "No test packages found, skipping test compression."
        cd - >/dev/null || exit
        return 0
    fi

    echo ""
    echo "Found test packages for ${#gfx_archs[@]} architecture(s): ${gfx_archs[*]}"
    echo ""

    # Group test packages by coarse family (same as main components)
    declare -A GFX_FAMILY_TESTS

    for gfx_arch in "${gfx_archs[@]}"; do
        # Map to coarse family
        local coarse_family
        coarse_family=$(get_coarse_family "$gfx_arch")

        # Add to family group
        GFX_FAMILY_TESTS["$coarse_family"]+="$gfx_arch "
    done

    local total_archives_created=0
    local total_removed_dirs=0

    # Compress test packages for each family
    for family in "${!GFX_FAMILY_TESTS[@]}"; do
        local members="${GFX_FAMILY_TESTS[$family]}"
        # Trim trailing space
        members="${members% }"

        echo "  Processing tests for family: $family"
        echo "    Members: $members"

        # Collect test packages for all members in this family
        local family_test_dirs=()
        for gfx_arch in $members; do
            for component in "component-rocm/content/$gfx_arch"/*test*/; do
                if [[ -d "$component" ]]; then
                    family_test_dirs+=("$component")
                fi
            done
        done

        if [[ ${#family_test_dirs[@]} -eq 0 ]]; then
            echo "    No test packages found for family $family, skipping."
            continue
        fi

        local tests_archive="component-rocm/tests-${family}.tar.xz"

        # Calculate source size
        local source_size_kb
        source_size_kb=$(du -sk "${family_test_dirs[@]}" 2>/dev/null | awk '{s+=$1} END {print s}')

        echo "    Source: ${#family_test_dirs[@]} test package(s) ($(format_size $((source_size_kb * 1024))))"

        # List test packages being compressed
        for test_dir in "${family_test_dirs[@]}"; do
            local pkg_name
            pkg_name=$(basename "$test_dir")
            echo "      - $pkg_name"
        done

        echo "    Target: $tests_archive"
        echo "    Method: xz (level: $XZ_COMPRESS_LEVEL)"

        # Remove old archive
        rm -f "$tests_archive" 2>/dev/null

        local start_time
        start_time=$(date +%s)

        # Start progress monitor
        show_compression_progress "$tests_archive" &
        local progress_pid=$!
        trap 'kill $progress_pid 2>/dev/null; wait $progress_pid 2>/dev/null' EXIT INT TERM

        # Compress using same pattern as component-compressor.sh
        local success=0
        if tar -cf - "${family_test_dirs[@]}" 2>/dev/null | \
           xz "-$XZ_COMPRESS_LEVEL" -T"$(nproc)" --verbose 2>/tmp/compress-tests.log > "$tests_archive"; then
            success=1
        fi

        # Stop progress monitor
        kill $progress_pid 2>/dev/null
        wait $progress_pid 2>/dev/null
        trap - EXIT INT TERM

        if [[ $success -eq 0 ]]; then
            echo ""
            echo -e "    \e[31mFailed to compress tests for family $family\e[0m"
            cd - >/dev/null || exit
            exit 1
        fi

        # Display final size
        local final_size
        final_size=$(stat -c%s "$tests_archive" 2>/dev/null || stat -f%z "$tests_archive" 2>/dev/null || echo 0)
        printf "\r\033[K    Compressed: %s\n" "$(format_size "$final_size")"

        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        # Calculate and display compression stats
        local archive_size_kb
        archive_size_kb=$(du -k "$tests_archive" | awk '{print $1}')
        # Calculate ratio with one decimal place using awk to avoid integer truncation
        local ratio
        ratio=$(awk "BEGIN {printf \"%.1f\", $source_size_kb / $archive_size_kb}")
        local reduction=$(( 100 - (archive_size_kb * 100 / source_size_kb) ))

        echo -e "    \e[32mCompressed: $(format_size $((archive_size_kb * 1024))) (${ratio}:1, ${reduction}%) in \e[36m$(format_duration "$duration")\e[0m"

        # Remove uncompressed test directories
        for test_dir in "${family_test_dirs[@]}"; do
            rm -rf "$test_dir"
        done
        echo -e "    \e[93mRemoved ${#family_test_dirs[@]} uncompressed test content directories\e[0m"

        ((total_archives_created++))
        total_removed_dirs=$((total_removed_dirs + ${#family_test_dirs[@]}))
        echo ""
    done

    cd - >/dev/null || exit
    echo ""
    echo "Test compression complete: $total_archives_created archive(s) created, $total_removed_dirs directories removed."
    echo "-------------------------------------------------------------"
}

print_compression_stats() {
    local source_size=$1
    local compressed_size=$2
    local duration=$3

    local ratio="0.0"
    if [[ $compressed_size -gt 0 ]]; then
        ratio=$(awk "BEGIN {printf \"%.1f\", $source_size / $compressed_size}")
    fi

    local reduction=0
    if [[ $source_size -gt 0 ]]; then
        reduction=$(awk "BEGIN {printf \"%.0f\", 100 - ($compressed_size * 100 / $source_size)}")
    fi

    echo -e "  \e[32mCompressed: $(format_size "$compressed_size") (${ratio}:1, ${reduction}%) in $(format_duration "$duration")\e[0m"
}

compress_gfx() {
    local -n compressed_count=$1
    local -n error_count=$2

    if [[ ! -d "component-rocm/content" ]]; then
        return 0
    fi

    echo "Compressing ROCm content directories (grouped by family)..."
    echo ""

    # Group GFX directories by coarse family
    declare -A GFX_FAMILY_DIRS
    for content_dir in component-rocm/content/*; do
        if [[ -d "$content_dir" ]]; then
            local gfx_name
            gfx_name=$(basename "$content_dir")

            # Skip base directory (handled separately)
            [[ "$gfx_name" == "base" ]] && continue

            # Map to coarse family and add to group
            local coarse_family
            coarse_family=$(get_coarse_family "$gfx_name")
            GFX_FAMILY_DIRS["$coarse_family"]+="$gfx_name "
        fi
    done

    # Compress each family group
    for family in "${!GFX_FAMILY_DIRS[@]}"; do
        local members="${GFX_FAMILY_DIRS[$family]% }"  # Trim trailing space
        local archive_name="component-rocm/content-${family}.tar.xz"

        echo "[$((compressed_count + 1))] Compressing ROCm family: $family"
        echo "  Members: $members"

        # Calculate source size
        local source_size=0
        for member in $members; do
            local member_size
            member_size=$(du -sb "component-rocm/content/$member" 2>/dev/null | awk '{print $1}')
            source_size=$((source_size + member_size))
        done

        echo "  Source: $(format_size $source_size)"
        echo "  Target: $archive_name"
        echo "  Method: xz (level: ${XZ_COMPRESS_LEVEL:-9})"

        # Compress
        local start_time
        start_time=$(date +%s)
        local success=0

        if [[ "$HYBRID_ALL_XZ" == "yes" ]] || [[ "${MAKESELF_COMPRESS_MODE:-auto}" == "xz" ]]; then
            # shellcheck disable=SC2086  # $members needs word splitting for multiple directories
            tar -cf - -C component-rocm/content $members 2>/dev/null | \
                xz "-${XZ_COMPRESS_LEVEL:-9}" -T"$(nproc)" > "$archive_name" && success=1
        else
            if command -v pigz &> /dev/null; then
                # shellcheck disable=SC2086  # $members needs word splitting for multiple directories
                tar -cf - -C component-rocm/content $members 2>/dev/null | \
                    pigz -6 -p "$(nproc)" > "$archive_name" && success=1
            else
                # shellcheck disable=SC2086  # $members needs word splitting for multiple directories
                tar -czf "$archive_name" -C component-rocm/content $members 2>/dev/null && success=1
            fi
        fi

        if [[ $success -eq 1 ]]; then
            local end_time
            end_time=$(date +%s)
            local compressed_size
            compressed_size=$(stat -c%s "$archive_name" 2>/dev/null || stat -f%z "$archive_name" 2>/dev/null || echo 0)

            print_compression_stats "$source_size" "$compressed_size" "$((end_time - start_time))"

            ((compressed_count++))
            for member in $members; do
                rm -rf "component-rocm/content/$member"
                echo -e "  \e[93mRemoved uncompressed: component-rocm/content/$member\e[0m"
            done
        else
            ((error_count++))
            echo -e "  \e[31mERROR: Failed to compress family $family\e[0m"
        fi
        echo ""
    done
}

compress_base() {
    local -n compressed_count=$1
    local -n error_count=$2

    if [[ ! -d "component-rocm/content/base" ]]; then
        return 0
    fi

    local archive_name="component-rocm/content-base.tar.xz"
    echo "[$((compressed_count + 1))] Compressing ROCm content for: base"

    if compress_directory "component-rocm/content/base" "$archive_name"; then
        ((compressed_count++))
        rm -rf "component-rocm/content/base"
        echo -e "  \e[93mRemoved uncompressed: component-rocm/content/base\e[0m"
    else
        ((error_count++))
        echo -e "  \e[31mERROR: Failed to compress base\e[0m"
    fi
    echo ""

    # Remove empty content directory
    if [[ -d "component-rocm/content" ]] && [[ -z "$(ls -A component-rocm/content)" ]]; then
        rmdir component-rocm/content
        echo -e "  \e[93mRemoved empty content directory\e[0m"
        echo ""
    fi
}

compress_amdgpu() {
    local -n compressed_count=$1
    local -n error_count=$2

    if [[ ! -d "component-amdgpu" ]]; then
        return 0
    fi

    echo "Compressing AMDGPU component..."
    echo ""
    echo "[$((compressed_count + 1))] Compressing component-amdgpu/content"

    if [[ -d "component-amdgpu/content" ]]; then
        if compress_directory "component-amdgpu/content" "component-amdgpu/content-amdgpu.tar.xz"; then
            ((compressed_count++))
            rm -rf "component-amdgpu/content"
            echo -e "  \e[93mRemoved uncompressed: component-amdgpu/content\e[0m"
        else
            ((error_count++))
            echo -e "  \e[31mERROR: Failed to compress component-amdgpu/content\e[0m"
        fi
    else
        echo -e "  \e[93mNo content directory found in component-amdgpu, skipping compression\e[0m"
    fi
    echo ""
}

compress_components() {
    echo "-------------------------------------------------------------"
    echo "Compressing components..."
    echo "-------------------------------------------------------------"

    local INSTALLER_DIR="../rocm-installer"
    cd "$INSTALLER_DIR" || exit 1

    # Remove old archives
    echo ""
    echo "Removing old component archives..."
    rm -f component-rocm/content-*.tar.* component-amdgpu/content-amdgpu.tar.* 2>/dev/null
    echo -e "  \e[93mRemoved old archives.\e[0m"
    echo ""

    local total_compressed=0
    local total_errors=0

    # Compress GFX families
    compress_gfx total_compressed total_errors

    # Compress base directory
    compress_base total_compressed total_errors

    # Compress AMDGPU
    compress_amdgpu total_compressed total_errors

    # Skip component-rocm-deb (metadata-only)
    if [[ -d "component-rocm-deb" ]]; then
        echo "Skipping compression for component-rocm-deb (metadata-only, <1MB)"
    fi

    cd - >/dev/null || exit

    # Summary
    echo ""
    echo "-------------------------------------------------------------"
    echo "Compression Summary:"
    echo "  Total archives created: $total_compressed"
    echo "  Errors: $total_errors"

    if [[ $total_errors -gt 0 ]]; then
        echo -e "  \e[31mStatus: FAILED (with errors)\e[0m"
        exit 1
    else
        echo -e "  \e[32mStatus: SUCCESS\e[0m"
    fi

    echo "-------------------------------------------------------------"
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

        pushd $BUILD_DIR_UI || exit
            # Detect multi-arch build by checking GFX_FAMILY_MAP
            local is_multiarch=false
            for fine_arch in "${!GFX_FAMILY_MAP[@]}"; do
                local coarse="${GFX_FAMILY_MAP[$fine_arch]}"
                if [[ "$fine_arch" != "$coarse" ]]; then
                    is_multiarch=true
                    break
                fi
            done

            # UI now reads VERSION file at runtime - no version parameters needed
            if [[ "$is_multiarch" == "true" ]]; then
                echo "Building UI with MULTI_ARCH_BUILD support"
                cmake -DMULTI_ARCH_BUILD=ON ../build-installer
            else
                echo "Building UI for single-arch installer"
                cmake -DMULTI_ARCH_BUILD=OFF ../build-installer
            fi
            if ! make; then
                echo -e "\e[31mFailed GUI build.\e[0m"
                exit 1
            fi

            # Verify static linking worked
            echo "Checking UI binary dependencies:"
            if ldd rocm_ui | grep -E "ncurses|menu|form|tinfo"; then
                echo "WARNING: UI binary has ncurses dynamic dependencies"
            else
                echo "SUCCESS: No ncurses dynamic dependencies found (fully static)"
            fi
        popd || exit
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

        echo "MAKESELF_OPT_HEADER   = $MAKESELF_OPT_HEADER"
        echo "MAKESELF_OPT          = $MAKESELF_OPT"
        echo "MAKESELF_OPT_COMPRESS = $MAKESELF_OPT_COMPRESS"
        echo "MAKESELF_OPT_CLEANUP  = $MAKESELF_OPT_CLEANUP"
        echo "MAKESELF_OPT_TAR      = $MAKESELF_OPT_TAR"

        # shellcheck disable=SC2086
        if ! makeself $MAKESELF_OPT_HEADER $MAKESELF_OPT $MAKESELF_OPT_COMPRESS $MAKESELF_OPT_CLEANUP $MAKESELF_OPT_TAR ../rocm-installer "./$BUILD_DIR/$BUILD_INSTALLER_NAME.run" "ROCm Runfile Installer" ./install-init.sh; then
            echo -e "\e[31mFailed makeself build.\e[0m"
            exit 1
        fi

        echo Building installer runfile...Complete

        # Display the built runfile name and size
        RUNFILE_PATH="./$BUILD_DIR/$BUILD_INSTALLER_NAME.run"
        if [ -f "$RUNFILE_PATH" ]; then
            RUNFILE_SIZE_BYTES=$(stat -c%s "$RUNFILE_PATH" 2>/dev/null || stat -f%z "$RUNFILE_PATH" 2>/dev/null)
            RUNFILE_SIZE=$(format_size "$RUNFILE_SIZE_BYTES")
            echo ""
            echo -e "\e[32m========================================\e[0m"
            echo -e "\e[32mBuilt runfile: $BUILD_INSTALLER_NAME.run\e[0m"
            echo -e "\e[95mSize: $RUNFILE_SIZE ($RUNFILE_SIZE_BYTES bytes)\e[0m"
            echo -e "\e[32m========================================\e[0m"
        fi
    else
        echo Runfile build disabled.
    fi

    echo Building Installer Package...Complete
}


####### Main script ###############################################################

# Record start time
BUILD_START_TIME=$(date +%s)

echo ==============================
echo BUILD INSTALLER
echo ==============================

SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO="sudo"
echo SUDO: "$SUDO"

os_release

# Load config file if specified (allows command-line args to override)
read_config "$@"

# Initialize GFX_FAMILY_MAP based on build type (after config is loaded)
initialize_gfx_family_map

# parse args
while (($#))
do
    case "$1" in
    config=*)
        # Already processed before argument parsing loop
        # Skip to allow other args to override config values
        shift
        ;;
    help)
        usage
        exit 0
        ;;
    noextract)
        echo "Disabling package extraction."
        BUILD_EXTRACT="no"
        shift
        ;;
    norocm)
        echo "Disabling ROCm package extraction."
        EXTRACT_ROCM="no"
        shift
        ;;
    noamdgpu)
        echo "Disabling AMDGPU package extraction."
        EXTRACT_AMDGPU="no"
        shift
        ;;
    noextractcontent)
        echo "Disabling content extraction (deps and scriptlets only)."
        EXTRACT_TYPE="nocontent"
        shift
        ;;
    noextractcontentdeb)
        echo "Disabling DEB content extraction (deps and scriptlets only)."
        EXTRACT_TYPE_DEB="nocontent"
        shift
        ;;
    extractcontentdeb)
        echo "Enabling DEB content extraction (deps, scriptlets, and content)."
        EXTRACT_TYPE_DEB=""
        shift
        ;;
    contentlist)
        echo "Enabling content file listing during extraction."
        EXTRACT_TYPE="contentlist"
        shift
        ;;
    nocompress)
        echo "Disabling component/test compression."
        BUILD_COMPRESS="no"
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
    runfileonly)
        echo "Build runfile only (skipping extraction, compression, and UI build)."
        BUILD_EXTRACT="no"
        BUILD_COMPRESS="no"
        BUILD_UI="no"
        BUILD_INSTALLER="yes"
        shift
        ;;
    noautodeps)
        echo "Disabling automatic dependency resolution for RPM packages."
        DISABLE_AUTO_DEPS="yes"
        shift
        ;;
    buildname=*)
        BUILD_NAME="${1#*=}"
        echo "Setting BUILD_NAME = $BUILD_NAME"
        shift
        ;;
    buildrunid=*)
        BUILD_RUNID="${1#*=}"
        echo "Setting BUILD_RUNID = $BUILD_RUNID"
        shift
        ;;
    buildworkflow=*)
        BUILD_WORKFLOW_NUM="${1#*=}"
        echo "Setting BUILD_WORKFLOW_NUM = $BUILD_WORKFLOW_NUM"
        shift
        ;;
    buildpullinfo=*)
        BUILD_PULL_INFO="${1#*=}"
        echo "Setting BUILD_PULL_INFO = $BUILD_PULL_INFO"
        shift
        ;;
    mscomp=*)
        MAKESELF_COMPRESS_MODE="${1#*=}"
        case "$MAKESELF_COMPRESS_MODE" in
            hybrid)
                echo "Setting compression mode: hybrid (xz-9 for everything, maximum compression)"
                ;;
            hybriddev)
                echo "Setting compression mode: hybriddev (xz-3 for everything, fast compression)"
                ;;
            dev)
                echo "Setting compression mode: dev (pigz + complevel 6)"
                ;;
            normal)
                echo "Setting compression mode: normal (gzip -9)"
                ;;
            nocomp)
                echo "Setting compression mode: nocomp (no compression - debugging only)"
                ;;
            *)
                echo -e "\e[31mERROR: Invalid mscomp value: $MAKESELF_COMPRESS_MODE\e[0m"
                echo "Valid options: hybrid, hybriddev, dev, normal, nocomp"
                exit 1
                ;;
        esac
        shift
        ;;
    *)
        echo "Unknown option: $1"
        shift
        ;;
    esac
done

# Install any required tools for the build
install_tools

# Configure compression (install pigz/lz4 if needed)
configure_compression

# Extract all ROCm/AMDGPU packages
extract_packages

# Setup version/build info (before compression to access amdgpu-dkms-ver.txt)
write_version

# Compress packages if hybrid mode is enabled and compression not disabled
if [[ "$HYBRID_COMPRESSION" == "yes" ]] && [[ "$BUILD_COMPRESS" == "yes" ]]; then
    compress_setup
    compress_tests
    compress_components
elif [[ "$BUILD_COMPRESS" == "no" ]]; then
    echo "-------------------------------------------------------------"
    echo "Skipping compression (nocompress flag specified)"
    echo "-------------------------------------------------------------"
fi

# Generate component lists and headers
generate_component_lists
generate_headers

# Build the UI
build_UI

# Build the installer
build_installer

# Calculate and display build time
BUILD_END_TIME=$(date +%s)
BUILD_ELAPSED=$((BUILD_END_TIME - BUILD_START_TIME))

# Convert seconds to hours, minutes, seconds
BUILD_HOURS=$((BUILD_ELAPSED / 3600))
BUILD_MINUTES=$(((BUILD_ELAPSED % 3600) / 60))
BUILD_SECONDS=$((BUILD_ELAPSED % 60))

echo ""
echo ==============================
echo "Build completed successfully!"
echo "=============================="
echo -e "\e[36mTotal build time: ${BUILD_HOURS}h ${BUILD_MINUTES}m ${BUILD_SECONDS}s (${BUILD_ELAPSED} seconds)\e[0m"
echo ==============================
echo ""
