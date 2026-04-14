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

# Extraction Output - supports multi-format with EXTRACT_FORMAT variable
EXTRACT_FORMAT="${EXTRACT_FORMAT:-rpm}"

# ROCm Packages Source - defaults to format-specific directory
PACKAGE_ROCM_DIR="${PACKAGE_ROCM_DIR:-$PWD/packages-rocm-${EXTRACT_FORMAT}}"

# AMDGPU Packages Source - defaults to format-specific directory
PACKAGE_AMDGPU_DIR="${PACKAGE_AMDGPU_DIR:-$PWD/packages-amdgpu-${EXTRACT_FORMAT}}"

# Extraction output directories
EXTRACT_ROCM_DIR="$PWD/component-rocm-${EXTRACT_FORMAT}"
EXTRACT_AMDGPU_DIR="$PWD/component-amdgpu-${EXTRACT_FORMAT}"

# Top-level extraction directories for new structure (Phase 1 optimization)
EXTRACT_CONTENT_DIR=""     # Will be set to component-rocm/content
EXTRACT_DEPS_DIR=""        # Will be set to component-rocm/deps
EXTRACT_SCRIPTLETS_DIR=""  # Will be set to component-rocm/scriptlets

# Extraction Files
EXTRACT_ROCM_PKG_CONFIG_FILE="rocm-packages.config"
EXTRACT_AMDGPU_PKG_CONFIG_FILE="amdgpu-packages.config"

EXTRACT_AMDGPU_DKMS_VER_FILE="amdgpu-dkms-ver.txt"

EXTRACT_COMPO_LIST_FILE="components.txt"          # list the component version of extracted packages
EXTRACT_PACKAGE_LIST_FILE="packages.txt"          # list all extracted packages
EXTRACT_REQUIRED_DEPS_FILE="required_deps.txt"    # list only required dependencies (non-amd deps)
EXTRACT_GLOBAL_DEPS_FILE="global_deps.txt"        # list all extracted dependencies

# Auto dependency resolution (RPM only)
RESOLVE_AUTO_DEPS=0                               # flag to enable/disable auto dependency resolution
BUILD_CONFIG_FILE=""                              # build config file path (contains repo info for auto resolution)
declare -A AUTO_DEPS_CACHE                        # in-memory cache (persists across all packages during extraction)
declare -A LOCAL_PROVIDES_CACHE                   # local ROCm RPM provides cache (built once, used for all packages)
RESOLVED_AUTO_DEPS=""                             # resolved dependencies for current package (set by resolve_auto_deps)

# Meta packages - GFX-specific (extracted from gfxXYZ directories)
GFX_META_PACKAGES=(
    "amdrocm-core"
    "amdrocm-core-sdk"
    "amdrocm-core-devel"
)

# Meta packages - Base (extracted from base directory)
BASE_META_PACKAGES=(
    "amdrocm-developer-tools"
    "amdrocm-opencl"
)

# Extra/Installer dependencies
EXTRA_DEPS=()
INSTALLER_DEPS=(rsync wget)

# Logs
EXTRACT_LOGS_DIR="$PWD/logs"
EXTRACT_CURRENT_LOG="$EXTRACT_LOGS_DIR/extract_$(date +%s).log"

# Config
PROMPT_USER=0
ROCM_EXTRACT=0
AMDGPU_EXTRACT=0
EXTRACT_CONTENT=1
CONTENT_LIST=0

######## Build tags EXTRACT FROM ROCM meta package
ROCM_VER=

# Stats
PACKAGES=
AMD_PACKAGES=
OTHER_PACKAGES=

SCRIPLET_PREINST_COUNT=0
SCRIPLET_POSTINST_COUNT=0
SCRIPLET_PRERM_COUNT=0
SCRIPLET_POSTRM_COUNT=0
SCRIPTLET_OPT_COUNT=0
SCRIPTLET_OPT=

GLOBAL_DEPS=


###### Functions ###############################################################

usage() {
cat <<END_USAGE
Usage: $PROG [options]

[options}:
    help                    = Display this help information.
    prompt                  = Run the extractor with user prompts.
    amdgpu                  = Extract AMDGPU packages.
    rocm                    = Extract ROCm packages.

    nocontent               = Disables content extraction (deps, scriptlets will be extracted only).
    contentlist             = Lists all files extracted to content directories during extraction.

    resolveautodeps          = Enable automatic dependency resolution.  Requires build-config to be specified.
    build-config=<file_path> = <file_path> Path to build-config file used during package pull.
                               Contains ROCM_REPO variable with repository configuration.

    pkgs-rocm=<file_path>   = <file_path> Path to ROCm source packages directory for extract.
    pkgs-amdgpu=<file_path> = <file_path> Path to AMDGPU source packages directory for extract.
    ext-rocm=<file_path>    = <file_path> Path to ROCm packages extraction directory.
    ext-amdgpu=<file_path>  = <file_path> Path to AMDGPU packages extraction directory.

    Example:

    ./package-extractor-rpms.sh prompt rocm ext-rocm="/extracted-rocm"
    ./package-extractor-rpms.sh rocm resolveautodeps build-config="../build-config/rocm-nightly-20260308-22813991811-rpm.config"

END_USAGE
}

os_release() {
    if [[ -r  /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release

        DISTRO_NAME=$ID
        DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')

        case "$ID" in
        rhel|ol|rocky|almalinux)
            echo "Extracting for EL $DISTRO_VER."
            EXTRACT_DISTRO_TYPE=el
            ;;
        sles)
            echo "Extracting for SUSE $DISTRO_VER."
            EXTRACT_DISTRO_TYPE=sle
            ;;
        amzn)
            echo "Extracting for Amazon $DISTRO_VER."
            EXTRACT_DISTRO_TYPE=el
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

print_no_err() {
    local msg=$1
    echo -e "\e[32m++++++++++++++++++++++++++++++++++++\e[0m"
    echo -e "\e[32m$msg\e[0m"
    echo -e "\e[32m++++++++++++++++++++++++++++++++++++\e[0m"
}

print_err() {
    local msg=$1
    echo -e "\e[31m++++++++++++++++++++++++++++++++++++\e[0m"
    echo -e "\e[31m$msg\e[0m"
    echo -e "\e[31m++++++++++++++++++++++++++++++++++++\e[0m"
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

install_tools_el() {
    if [[ "$DISTRO_NAME" = "rocky" ]]; then
        # Rocky Linux - use cpio and diffutils instead of rpmdevtools
        if rpm -q cpio > /dev/null 2>&1; then
            echo "cpio already installed"
        else
            echo "Installing cpio"
            $SUDO dnf install -y cpio
        fi

        if rpm -q diffutils > /dev/null 2>&1; then
            echo "diffutils already installed"
        else
            echo "Installing diffutils"
            $SUDO dnf install -y diffutils
        fi
    else
        # RHEL, Oracle, AlmaLinux, Amazon - use rpmdevtools
        if rpm -q rpmdevtools > /dev/null 2>&1; then
            echo "rpmdevtools already installed"
        else
            echo "Installing rpmdevtools"
            $SUDO dnf install -y rpmdevtools
        fi
    fi
}

install_tools_sle() {
    # SLES - use rpmdevtools
    if rpm -q rpmdevtools > /dev/null 2>&1; then
        echo "rpmdevtools already installed"
    else
        echo "Installing rpmdevtools"
        $SUDO zypper install -y rpmdevtools
    fi
}

install_tools() {
    echo ++++++++++++++++++++++++++++++++
    echo Installing tools...

    # Install rpmdevtools for dep version
    if [ $EXTRACT_DISTRO_TYPE == "el" ]; then
        install_tools_el
    elif [ $EXTRACT_DISTRO_TYPE == "sle" ]; then
        install_tools_sle
    else
        echo Unsupported extract type.
        exit 1
    fi

    echo Installing tools...Complete.
}

dump_extract_stats() {
    echo +++++++++++++++++++++++++++++++++++++++++++++
    echo STATS
    echo -----

    local stat_dir=$1

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

init_stats() {
    echo Initialize package information.

    PACKAGES=

    AMD_PACKAGES=
    OTHER_PACKAGES=

    GLOBAL_DEPS=

    SCRIPLET_PREINST_COUNT=0
    SCRIPLET_POSTINST_COUNT=0
    SCRIPLET_PRERM_COUNT=0
    SCRIPLET_POSTRM_COUNT=0
    SCRIPTLET_OPT_COUNT=0
    SCRIPTLET_OPT=
}

scriptlet_stats() {
    echo +++++++++++++++++++++++++++++++++++++++++++++
    echo Extracted Scriptlets:
    echo ---------------------
    echo "SCRIPLET_PREINST_COUNT  = $SCRIPLET_PREINST_COUNT"
    echo "SCRIPLET_POSTINST_COUNT = $SCRIPLET_POSTINST_COUNT"
    echo "SCRIPLET_PRERM_COUNT    = $SCRIPLET_PRERM_COUNT"
    echo "SCRIPLET_POSTRM_COUNT   = $SCRIPLET_POSTRM_COUNT"
    echo "SCRIPTLET_OPT_COUNT     = $SCRIPTLET_OPT_COUNT"
    echo ----------------------
    echo "Scriptlets (/opt/rocm):"
    echo ----------------------
    echo "$SCRIPTLET_OPT" | tr ' ' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u
}

move_opt_contents() {
    local content_dir="$1"
    local dir="$2"

    # Move all contents of the 'opt' directory to the root content directory
    mv "$dir/"* "$content_dir/"

    # Remove the empty 'opt' directory
    rmdir "$dir"
    echo "Moved contents of '$dir' to '$content_dir'."
}

move_etc_contents_rocm() {
    local content_etc_dir="$PACKAGE_DIR/content-etc"

    echo Creating content-etc directory: "$content_etc_dir"
    mkdir "$content_etc_dir"

    # Move all contents of the 'etc' directory to the content-etc directory
    mv "$dir/"* "$content_etc_dir/"

    # Remove the empty 'etc' directory
    rmdir "$dir"

    echo "Moved contents of '$dir' to '$content_etc_dir'."
}

move_usr_contents_rocm() {
    local dir="$1"

    # workaround for extra /usr content for RHEL
    if [[ -d "$dir/lib/.build-id" ]]; then
        echo -e "\e[31m$dir/lib/.build-id delete\e[0m"
        $SUDO rm -r "$dir/lib/.build-id"
        rmdir "$dir/lib"
        rmdir "$dir"
    fi
}

move_data() {
    echo -e "\e[36mMoving data...\e[0m"

    local content_dir="$1"
    echo "Content root: $content_dir"

    # Loop through the content directory
    for dir in "$content_dir"/*; do
        local dirname
        dirname=$(basename "$dir")

        # Check if the current directory is the opt / etc / or usr directories
        if [[ -d "$dir" && "$dirname" == "opt" ]]; then
            echo -e "\e[93m'opt' directory detected: $dir\e[0m"
            move_opt_contents "$content_dir" "$dir"

        elif [[ -d "$dir" && "$dirname" == "etc" ]]; then
            echo -e "\e[93m'etc' directory detected: $dir\e[0m"
            if [[ $content_dir =~ "component-rocm" ]]; then
                move_etc_contents_rocm
            fi

        elif [[ -d "$dir" && "$dirname" == "usr" ]]; then
            echo -e "\e[93m'usr' directory detected: $dir\e[0m"
            if [[ $content_dir =~ "component-rocm" ]]; then
                move_usr_contents_rocm "$dir"
            fi

        else
            echo -e "\e[93m$dir not moved.\e[0m"
        fi
    done

    echo Moving data...Complete.
}

extract_data() {
    echo --------------------------------
    echo Extracting all data/content
    echo --------------------------------

    # Use top-level content directory with component type subdirectory
    # For AMDGPU, COMP_TYPE is already the package name, so don't add PACKAGE_DIR_NAME again
    local package_dir_content
    if [[ "$COMP_TYPE" == "$PACKAGE_DIR_NAME" ]]; then
        package_dir_content="$EXTRACT_CONTENT_DIR/$COMP_TYPE/content"
    else
        package_dir_content="$EXTRACT_CONTENT_DIR/$COMP_TYPE/$PACKAGE_DIR_NAME"
    fi

    echo Creating content directory: "$package_dir_content"
    mkdir -p "$package_dir_content"

    echo "Extracting Data..."

    # Extract the rpm package file content
    pushd "$package_dir_content" || exit

        if ! rpm2cpio "$PACKAGE" | cpio -idmv > /dev/null 2>&1; then
            print_err "Failed rpm2cpio"
            exit 1
        fi

    popd || exit

    # List extracted content files if requested
    if [ $CONTENT_LIST -eq 1 ]; then
        echo "Content files extracted:"
        find "$package_dir_content" -type f | sort
        echo "---"
    fi

    # Move data content to the correct directories for the installer
    move_data "$package_dir_content"

    echo Extracting Data...Complete.
    echo ---------------------------
}

extract_version() {
    local pkg="$1"

    # Extract the build ci/version info from "core" packages
    if echo "$pkg" | grep -q 'amdrocm-base'; then
        echo "--------------------------------"
        echo "Extract rocm versioning..."

        # Extract version from package filename
        local pkg_basename
        pkg_basename=$(basename "$pkg")

        local pattern='amdrocm-base([0-9]+\.[0-9]+)-'

        if [[ $pkg_basename =~ $pattern ]]; then
            ROCM_VER="${BASH_REMATCH[1]}"
        else
            VERSION_INFO=$(rpm -qi --nosignature "$pkg" | grep -E 'Version' | awk '{print $3}')
            echo VERSION_INFO = "$VERSION_INFO"
            ROCM_VER=$(echo "$VERSION_INFO" | cut -d '.' -f 1-2)
        fi

        echo "ROCM_VER = $ROCM_VER"
    fi
}

extract_info() {
    echo --------------------------------
    echo Extracting package info
    echo --------------------------------

    rpm -qi --nosignature "$PACKAGE"

    VERSION_INFO=$(rpm -qi --nosignature "$PACKAGE" | grep -E 'Version' | awk '{print $3}')

    # Write metadata files to deps/{comp_type}/ directory
    # Check for amdgpu-based packages pulled with rocm packages
    if echo "$PACKAGE_DIR_NAME" | grep -q 'amdgpu'; then
        # write out the package/component version
        echo "$PACKAGE_DIR_NAME" >> "$metadata_dir/$EXTRACT_AMDGPU_PKG_CONFIG_FILE"
    else
        echo "$PACKAGE_DIR_NAME" >> "$metadata_dir/$EXTRACT_ROCM_PKG_CONFIG_FILE"

        # write out the package/component version
        printf "%-25s = %s\n" "$PACKAGE_DIR_NAME" "$VERSION_INFO" >> "$metadata_dir/$EXTRACT_COMPO_LIST_FILE"
        printf "%-25s = %s\n" "$PACKAGE_DIR_NAME" "$VERSION_INFO"
    fi

    echo "VERSION_INFO = $VERSION_INFO"
    echo "PACKAGE      = $PACKAGE_DIR_NAME"

    extract_version "$PACKAGE"
}

should_skip_dep() {
    local dep="$1"

    # Skip patterns for dependencies that don't need resolution
    local skip_patterns=(
        "^rpmlib"              # RPM internal dependencies
        "^config\("            # Config dependencies
        "^/usr/bin/"           # System binaries
        "^/bin/"
        "^/usr/sbin/"
        "^/sbin/"
        "^rtld"                # Runtime linker (with or without parens)
        "^amdrocm-"            # AMD ROCm packages (manual dependencies)
        "^rocm-"               # AMD ROCm packages (manual dependencies)
        "^libamdhip"           # AMD ROCm libraries (automatic dependencies)
        "^libamd_comgr"
        "^libamd_smi"
        "^libhsa"
        "^libroc"
        "^libhip"
        "^librocm"
        "^python[0-9]"         # Python version-specific (python3 generic covers these)
        "^python3\.[0-9]"
    )

    for pattern in "${skip_patterns[@]}"; do
        [[ "$dep" =~ $pattern ]] && return 0
    done
    return 1
}

build_local_provides_cache() {
    local local_rpm_dir="$PACKAGE_ROCM_DIR"

    # Check if directory exists and contains RPM files
    if [[ ! -d "$local_rpm_dir" ]] || ! compgen -G "$local_rpm_dir"/*.rpm > /dev/null; then
        echo "[INFO] No local ROCm RPM files found in $local_rpm_dir - skipping provides cache" >&2
        return 0
    fi

    echo "Building local ROCm provides cache from RPM files..." >&2

    # Build provides cache from local ROCm RPMs
    # Store in associative array: capability -> package_name
    for rpm_file in "$local_rpm_dir"/*.rpm; do
        local pkg_name
        pkg_name=$(rpm -qp --nosignature --queryformat '%{NAME}' "$rpm_file" 2>/dev/null)
        [[ -z "$pkg_name" ]] && continue

        # Get all provides from this package
        while IFS= read -r provide; do
            # Strip version info and operators
            local capability
            capability=$(echo "$provide" | sed 's/[<>=].*//' | sed 's/(.*//' | tr -d ' ')
            [[ -z "$capability" ]] && continue

            # Store first provider (don't overwrite if multiple packages provide same capability)
            if [[ -z "${LOCAL_PROVIDES_CACHE[$capability]}" ]]; then
                LOCAL_PROVIDES_CACHE[$capability]="$pkg_name"
            fi
        done < <(rpm -qp --nosignature --provides "$rpm_file" 2>/dev/null)
    done

    echo "Built local provides cache with ${#LOCAL_PROVIDES_CACHE[@]} capabilities from local ROCm RPMs" >&2
}

# Extract dependencies from an RPM package
# Returns: dependency list (one per line), stripped of version info
extract_rpm_dependencies() {
    local package="$1"

    # Get all automatic dependencies (libraries, interpreters, etc.)
    # Strip version specifiers like (GLIBC_2.17) and operators like >= to deduplicate
    rpm -qpR --nosignature "$package" | grep -v '^rpmlib' | sed 's/(.*//' | sed 's/[<>=].*//' | sort -u
}

# Filter dependencies and check cache
# Writes uncached dependencies to temp file (path in $1)
# Sets globals: FILTER_RESOLVED_PKGS, FILTER_DEP_COUNT, FILTER_CACHED_COUNT
filter_and_check_cache() {
    local auto_deps="$1"
    local uncached_file="$2"

    FILTER_RESOLVED_PKGS=""
    FILTER_DEP_COUNT=0
    FILTER_CACHED_COUNT=0

    # Clear/create uncached file
    : > "$uncached_file"

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        should_skip_dep "$dep" && continue

        # Check global cache first
        if [[ -n "${AUTO_DEPS_CACHE[$dep]+isset}" ]]; then
            local cached_pkg="${AUTO_DEPS_CACHE[$dep]}"
            if [[ -n "$cached_pkg" ]]; then
                [[ -n "$FILTER_RESOLVED_PKGS" ]] && FILTER_RESOLVED_PKGS+=", "
                FILTER_RESOLVED_PKGS+="$cached_pkg"
                FILTER_DEP_COUNT=$((FILTER_DEP_COUNT + 1))
                FILTER_CACHED_COUNT=$((FILTER_CACHED_COUNT + 1))
            fi
            continue
        fi

        # Not in cache - write to uncached file for batch resolution
        echo "$dep" >> "$uncached_file"
    done <<< "$auto_deps"
}

# Batch resolve dependencies using local provides cache and system repos
# Input: dependencies from stdin (one per line)
# Sets globals: BATCH_RESOLVED_PKGS, BATCH_DEP_COUNT, BATCH_QUERIED_COUNT
batch_resolve_dependencies() {
    local repo_baseurl="$1"

    BATCH_RESOLVED_PKGS=""
    BATCH_DEP_COUNT=0
    BATCH_QUERIED_COUNT=0

    # Read all dependencies from stdin into array
    local deps_to_resolve=()
    while IFS= read -r dep; do
        deps_to_resolve+=("$dep")
    done

    if [[ ${#deps_to_resolve[@]} -eq 0 ]]; then
        return 0
    fi

    echo "Batch resolving ${#deps_to_resolve[@]} uncached dependencies..." >&2

    # Create temp file with all dependencies
    local deps_input
    deps_input=$(mktemp)
    printf '%s\n' "${deps_to_resolve[@]}" > "$deps_input"

    # Create temporary repo config file for system repos fallback
    local temp_repo_conf
    temp_repo_conf=$(mktemp)
    cat > "$temp_repo_conf" << EOF
[main]
keepcache=1
debuglevel=2
logfile=/dev/null
errorlevel=0

[rocm-extract-repo]
name=ROCm Extract Repository
baseurl=$repo_baseurl
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF

    local dnf_output
    dnf_output=$(mktemp)

    # Resolve dependencies: Check local ROCm provides cache first, then fall back to system repos
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue

        # First check local ROCm provides cache
        local rocm_pkg="${LOCAL_PROVIDES_CACHE[$dep]}"

        if [[ -n "$rocm_pkg" ]]; then
            echo "${dep}=${rocm_pkg}"
        else
            # Fall back to system repos
            local sys_pkg
            sys_pkg=$(dnf repoquery --quiet --config="$temp_repo_conf" --qf "%{name}" --whatprovides "$dep" 2>/dev/null | head -1)
            echo "${dep}=${sys_pkg}"
        fi
    done < "$deps_input" > "$dnf_output"

    # Clean up temp repo config
    rm -f "$temp_repo_conf"

    # Parse results and update cache
    while IFS='=' read -r dep pkg; do
        [[ -z "$dep" ]] && continue

        if [[ -n "$pkg" ]]; then
            # Filter out AMD ROCm packages (if present)
            if [[ "$pkg" =~ ^amdrocm- ]] || [[ "$pkg" =~ ^rocm- ]]; then
                echo "  skip: $dep -> $pkg (AMD ROCm package)" >&2
                AUTO_DEPS_CACHE[$dep]=""  # Cache as empty to avoid re-querying
                continue
            fi

            # Cache system package and add to results
            AUTO_DEPS_CACHE[$dep]="$pkg"
            echo "  auto: $dep -> $pkg" >&2

            [[ -n "$BATCH_RESOLVED_PKGS" ]] && BATCH_RESOLVED_PKGS+=", "
            BATCH_RESOLVED_PKGS+="$pkg"
            BATCH_DEP_COUNT=$((BATCH_DEP_COUNT + 1))
            BATCH_QUERIED_COUNT=$((BATCH_QUERIED_COUNT + 1))
        else
            # Cache empty result to avoid re-querying
            AUTO_DEPS_CACHE[$dep]=""
        fi
    done < "$dnf_output"

    rm -f "$deps_input" "$dnf_output"
}

resolve_auto_deps() {
    local package="$1"

    echo "=========================================" >&2
    echo "Resolving auto dependencies..." >&2
    echo "Package: $(basename "$package")" >&2
    echo "=========================================" >&2

    # Read build config file to get repo information
    local repo_baseurl=""
    if [[ -n "$BUILD_CONFIG_FILE" ]] && [[ -f "$BUILD_CONFIG_FILE" ]]; then
        # Source the config file to get ROCM_REPO variable
        # shellcheck source=/dev/null
        source "$BUILD_CONFIG_FILE"

        # Extract baseurl from ROCM_REPO variable
        repo_baseurl=$(echo "$ROCM_REPO" | grep '^baseurl=' | sed 's/baseurl=//')

        if [[ -z "$repo_baseurl" ]]; then
            echo "[WARNING] Could not extract baseurl from build config: $BUILD_CONFIG_FILE" >&2
            return
        fi
        echo "Using repository: $repo_baseurl" >&2
    else
        echo "[WARNING] Build config file not available for dependency resolution." >&2
        echo "" >&2
        return
    fi

    # Extract dependencies from RPM
    local auto_deps
    auto_deps=$(extract_rpm_dependencies "$package")

    local total_deps
    total_deps=$(echo "$auto_deps" | wc -l)
    echo "Found $total_deps unique library dependencies to resolve" >&2

    # Filter dependencies and check cache (writes uncached deps to temp file)
    local uncached_file
    uncached_file=$(mktemp)
    filter_and_check_cache "$auto_deps" "$uncached_file"

    # Start with cached results
    local resolved_pkgs="$FILTER_RESOLVED_PKGS"
    local dep_count=$FILTER_DEP_COUNT
    local cached_count=$FILTER_CACHED_COUNT

    # Batch resolve uncached dependencies (reads from temp file)
    if [[ -s "$uncached_file" ]]; then
        batch_resolve_dependencies "$repo_baseurl" < "$uncached_file"

        # Append batch results
        if [[ -n "$BATCH_RESOLVED_PKGS" ]]; then
            [[ -n "$resolved_pkgs" ]] && resolved_pkgs+=", "
            resolved_pkgs+="$BATCH_RESOLVED_PKGS"
        fi
        dep_count=$((dep_count + BATCH_DEP_COUNT))
    fi

    # Clean up temp file
    rm -f "$uncached_file"

    local queried_count=${BATCH_QUERIED_COUNT:-0}

    echo "-----------------------------------------" >&2
    echo "Resolved $dep_count system package dependencies ($cached_count cached, $queried_count queried)" >&2
    echo "=========================================" >&2

    # Store resolved packages in global variable
    RESOLVED_AUTO_DEPS="$resolved_pkgs"
}

extract_deps() {
    echo --------------------------------
    echo Extracting all dependencies
    echo --------------------------------

    # Use top-level deps directory with component type subdirectory
    # For AMDGPU, COMP_TYPE is already the package name, so don't add PACKAGE_DIR_NAME again
    local package_dir_deps
    if [[ "$COMP_TYPE" == "$PACKAGE_DIR_NAME" ]]; then
        package_dir_deps="$EXTRACT_DEPS_DIR/$COMP_TYPE/deps"
    else
        package_dir_deps="$EXTRACT_DEPS_DIR/$COMP_TYPE/$PACKAGE_DIR_NAME"
    fi

    echo "Extracting Dependencies...: $PACKAGE to $package_dir_deps"

    if [ ! -d "$package_dir_deps" ]; then
        echo Creating deps directory: "$package_dir_deps"
        mkdir -p "$package_dir_deps"
    fi

    echo --------------------------------
    rpm -qpRv --nosignature "$PACKAGE"
    echo --------------------------------

    # Extract manual dependencies (AMD ROCm packages)
    DEPS=$(rpm -qpRv --nosignature "$PACKAGE" | grep -E 'manual' | sed 's/manual: /,/')

    # Resolve automatic dependencies to package names
    if [[ $RESOLVE_AUTO_DEPS -eq 1 ]]; then
        # Call directly (no subshell) so AUTO_DEPS_CACHE persists across packages
        RESOLVED_AUTO_DEPS=""
        resolve_auto_deps "$PACKAGE"

        # Combine manual and resolved automatic dependencies
        if [[ -n "$RESOLVED_AUTO_DEPS" ]]; then
            # Add comma separator if DEPS is not empty
            if [[ -n "$DEPS" ]]; then
                DEPS+=", $RESOLVED_AUTO_DEPS"
            else
                DEPS="$RESOLVED_AUTO_DEPS"
            fi
        fi
    fi

    # Process the depends
    if [[ -n $DEPS ]]; then
        echo "-------------"
        echo "Dependencies:"
        echo "-------------"
        echo "$DEPS" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u

        # write out the dependencies
        echo "$DEPS" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u > "$package_dir_deps/deps.txt"

        # Add to global deps with comma separator
        if [[ -n "$GLOBAL_DEPS" ]]; then
            GLOBAL_DEPS+=", $DEPS"
        else
            GLOBAL_DEPS="$DEPS"
        fi
        echo "-------------"
    fi

    echo Extracting Dependencies...Complete.
    echo -----------------------------------
}

extract_scriptlets() {
    echo --------------------------------
    echo Extracting all scriptlets
    echo --------------------------------

    # Use top-level scriptlets directory with component type subdirectory
    # For AMDGPU, COMP_TYPE is already the package name, so don't add PACKAGE_DIR_NAME again
    local package_dir_scriptlet
    if [[ "$COMP_TYPE" == "$PACKAGE_DIR_NAME" ]]; then
        package_dir_scriptlet="$EXTRACT_SCRIPTLETS_DIR/$COMP_TYPE/scriptlets"
    else
        package_dir_scriptlet="$EXTRACT_SCRIPTLETS_DIR/$COMP_TYPE/$PACKAGE_DIR_NAME"
    fi

    echo "Extracting Scriptlets...: $PACKAGE to $package_dir_scriptlet"

    if [ ! -d "$package_dir_scriptlet" ]; then
        echo Creating scriptlet directory: "$package_dir_scriptlet"
        mkdir -p "$package_dir_scriptlet"
    fi

    local scriptlets
    scriptlets=$(rpm -qp --scripts --nosignature "$PACKAGE")
    echo +++++++++++
    echo "$scriptlets"
    echo +++++++++++

    echo "$scriptlets" | awk -v output_dir="$package_dir_scriptlet" '
    /scriptlet \(using/ {
        if (section) {
            # Remove unwanted lines from the section
            section = gensub(/postinstall program:.*|preuninstall program:.*|postuninstall program:.*|posttrans program:.*/, "", "g", section)
            print section > (output_dir "/" section_name ".sh")
            section = ""
        }
        section_name = $1
        next
    }
    {
        section = section $0 "\n"
    }
    END {
        if (section) {
            # Remove unwanted lines from the section
            section = gensub(/postinstall program:.*|preuninstall program:.*|postuninstall program:.*|posttrans program:.*/, "", "g", section)
            print section > (output_dir "/" section_name ".sh")
        }
    }
    '

    # Make the output scripts executable
    for scriptlet in "$package_dir_scriptlet"/*; do
       if [[ -s "$scriptlet" ]]; then
           echo ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
           echo Making scriptlet "$scriptlet" executable.
           chmod +x "$scriptlet"

           # Check the script content for /opt
           if grep -q '/opt' "$scriptlet"; then
               echo "Scriptlet contains /opt"
               SCRIPTLET_OPT_COUNT=$((SCRIPTLET_OPT_COUNT+1))
               SCRIPTLET_OPT+="$base_name "
           fi

           echo ++++++++++++++++++++++++++++
           basename "$scriptlet"
           echo ++++++++++++++++++++++++++++
           cat "$scriptlet"
           echo ++++++++++++++++++++++++++++

           if [[ $(basename "$scriptlet") == "preinstall.sh" ]]; then
               SCRIPLET_PREINST_COUNT=$((SCRIPLET_PREINST_COUNT+1))

               # Rename for rocm-installer
               mv "$scriptlet" "$(dirname "$scriptlet")/preinst"

           elif [[ $(basename "$scriptlet") == "postinstall.sh" ]]; then
               SCRIPLET_POSTINST_COUNT=$((SCRIPLET_POSTINST_COUNT+1))

               # Rename for rocm-installer
               mv "$scriptlet" "$(dirname "$scriptlet")/postinst"

           elif [[ $(basename "$scriptlet") == "preuninstall.sh" ]]; then
               SCRIPLET_PRERM_COUNT=$((SCRIPLET_PRERM_COUNT+1))

               # Rename for rocm-installer
               mv "$scriptlet" "$(dirname "$scriptlet")/prerm"

           elif [[ $(basename "$scriptlet") == "postuninstall.sh" ]]; then
               SCRIPLET_POSTRM_COUNT=$((SCRIPLET_POSTRM_COUNT+1))

               # Rename for rocm-installer
               mv "$scriptlet" "$(dirname "$scriptlet")/postrm"

           fi

       else
           if [[ -f "$scriptlet" ]]; then
               #echo Removing empty scriptlet $(basename $scriptlet).
               rm "$scriptlet"
           fi
       fi
    done

    echo Extracting Scriptlets...Complete.
    echo ---------------------------------
}

extract_package() {
    echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    echo "Extracting Package...: $PACKAGE"

    local base_name
    base_name=$(basename "$PACKAGE")

    # shellcheck disable=SC2001
    PACKAGE_DIR_NAME=$(echo "$base_name" | sed 's/-[0-9].*$//')

    echo "Package Directory Name = $PACKAGE_DIR_NAME"
    echo "Component Type         = $COMP_TYPE"

    # Extract the content from data
    if [[ $EXTRACT_CONTENT == 1 ]]; then
        extract_data
    fi

    # Extract package info
    extract_info

    # Extract the dependencies
    extract_deps

    # Extract the scriptlets
    extract_scriptlets

    # write the package list
    PACKAGE_LIST+="$PACKAGE_DIR_NAME, "

    echo Extracting Package...Complete.
    echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
}

add_extra_deps() {
    echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    echo Additional Dependencies...

    echo "Adding Extra Dependencies."
    for pkg in "${EXTRA_DEPS[@]}"; do
        echo "    $pkg"
        GLOBAL_DEPS+=", $pkg"
    done

    echo "Adding Installer Dependencies."
    for pkg in "${INSTALLER_DEPS[@]}"; do
        echo "    $pkg"
        GLOBAL_DEPS+=", $pkg"
    done

    echo Additional Dependencies...Complete.
    echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
}

check_package_owner() {
    AMDPKG=0

    local package
    local vendor
    package=$(rpm -q --queryformat "%{NAME}" --nosignature "$PACKAGE")
    vendor=$(rpm -qi --nosignature "$PACKAGE" | grep Vendor)

    if [[ $package =~ "amdgpu" || $package =~ "rocm" ]]; then
        AMDPKG=1
    else
       if [[ -n $vendor ]]; then
           if [[ $vendor =~ "Advanced Micro Devices" || $vendor =~ "AMD ROCm" ]]; then
               AMDPKG=1
           fi
       fi
    fi

    if [[ $AMDPKG == 1 ]] ; then
        print_no_err "AMD PACKAGE"
        AMD_COUNT=$((AMD_COUNT+1))
        AMD_PACKAGES+="$(basename "$PACKAGE") "
    else
        print_err "3rd Party PACKAGE"
        NON_AMD_COUNT=$((NON_AMD_COUNT+1))
        OTHER_PACKAGES+="$(basename "$PACKAGE") "
    fi
}

write_package_list() {
    echo ^^^^^^^^^^^^^^^^^^^^
    echo Extracted Packages:
    echo ^^^^^^^^^^^^^^^^^^^^
    echo PKG_COUNT = "$PKG_COUNT"
    echo --------------------
    echo "$PACKAGE_LIST" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u

    # Write to deps/{comp_type}/ directory
    echo "$PACKAGE_LIST" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u > "$EXTRACT_DEPS_DIR/$COMP_TYPE/$EXTRACT_PACKAGE_LIST_FILE"
}

filter_deps_version() {
    echo -----------------------------
    echo Dependency Version Filter...

    # Read from deps/{comp_type}/ directory
    local metadata_dir="$EXTRACT_DEPS_DIR/$COMP_TYPE"

    local packages_file="$metadata_dir/$EXTRACT_PACKAGE_LIST_FILE"
    local deps_file="$metadata_dir/$EXTRACT_GLOBAL_DEPS_FILE"

    local deps_file_filtered="$metadata_dir/global_deps_filtered.txt"
    local reqs_file="$metadata_dir/$EXTRACT_REQUIRED_DEPS_FILE"

    local prev_package=""
    local prev_version=""
    local prev_line=

    # Read config file from metadata_dir
    local config_file="$metadata_dir/$EXTRACT_PKG_CONFIG_FILE"
    CONFIG_PKGS=$(<"$config_file")

    if [ -f "$deps_file_filtered" ]; then
        rm "$deps_file_filtered"
    fi

    # read the global deps file and filter to new file base on package versions
    while IFS= read -r line; do
        echo "<><><><><><><><><><><><><><><><><><><><><><>"
        echo -e "dep : \e[96m$line\e[0m"

        # Remove (x86-64) substrings
        line="${line//(x86-64)/}"

        # Remove open bracket from the start and close bracket from the end and replace " or " with "|"
        line=$(echo "$line" | sed 's/^[(]//; s/[)]$//' | sed 's/ or /|/g')
        echo "line: $line"

        # filter the versioning within brackets
        current_package=$(echo "$line" | awk -F '[()]' '{print $1}' | awk '{print $1}')

        # extract the current version number only
        current_version=$(echo "$line" | sed -n 's/.*[>=]\s*\(.*\)/\1/p')

        # init a null version to 0 (for rpmdev-vercmp)
        if [[ -z "$current_version" ]]; then
            current_version="0"
        fi

        echo ++++++
        echo "current  : $current_package : $current_version"
        echo "prev     : $prev_package : $prev_version"
        echo "prev_line: $prev_line"
        echo ++++++

        if [[ -n $prev_package ]]; then
            # check if the current and previous dep are equal.  If equal, compare the version
            if [ "$current_package" = "$prev_package" ]; then
                echo "Same package (cur = prev): comparing versions"
                if rpmdev-vercmp "$current_version" "$prev_version" | grep -q '>' ; then
                    echo "current_version > prev_version"
                    prev_version="$current_version"
                    prev_package="$current_package"
                    prev_line=$line
                else
                    echo "current_version <= prev_version"
                fi
            else
                # the packages are different, so write out the previous dep to the filter deps file
                echo "Diff package (cur != prev)"

                # before writing out, check for "tags" or if the dep is in the extracted package list
                if echo "$CONFIG_PKGS" | grep -qw "$prev_package"; then
                    echo -e "\e[32mConfig package: write prev_package: $prev_package\e[0m"
                    echo "$prev_package" >> "$deps_file_filtered"
                else
                    echo -e "\e[32mNon-Tag package: write prev_line: $prev_line\e[0m"
                    echo "$prev_line" >> "$deps_file_filtered"
                fi

                prev_package="$current_package"
                prev_line=$line
                prev_version="$current_version"
            fi
       else
            prev_line=$line
            prev_package="$current_package"
            prev_version="$current_version"
        fi
    done < "$deps_file"

    # write out the last line
    echo "$prev_line" >> "$deps_file_filtered"

    sort -u "$deps_file_filtered" -o "$deps_file_filtered"

    # diff the package list against the deps and write out deps that are not installed
    diff "$packages_file" "$deps_file_filtered" | grep '^>' | sed 's/^> //' > "$reqs_file"

    # remove the filtered global list
    rm "$deps_file_filtered"

    echo "<><><><><><><><><><><><><><><><><><><><><><>"
    echo "Required Dependencies:"
    while IFS= read -r dep; do
        echo "$dep"
    done < "$reqs_file"

    echo Dependency Version Filter...Complete.
}

write_global_deps() {
    echo ^^^^^^^^^^^^^^^^^^^^
    echo Global Dependencies:
    echo ^^^^^^^^^^^^^^^^^^^^

    echo -------------
    echo Dependencies:
    echo -------------
    echo "$GLOBAL_DEPS" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u

    # Write to deps/{comp_type}/ directory
    echo "$GLOBAL_DEPS" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u > "$EXTRACT_DEPS_DIR/$COMP_TYPE/$EXTRACT_GLOBAL_DEPS_FILE"
}

extract_rpms() {
    echo ===================================================
    echo Extracting RPMs...

    PKG_COUNT=0

    # COMP_TYPE should already be set by caller (extract_rocm_rpms or extract_amdgpu_rpms)
    # Directories should already be created by caller
    if [[ -z "$COMP_TYPE" ]]; then
        echo "ERROR: COMP_TYPE not set before calling extract_rpms"
        return 1
    fi

    echo Extracting RPM...

    for pkg in $PACKAGES; do

        PKG_COUNT=$((PKG_COUNT+1))

        echo -------------------------------------------------------------------------------
        echo -e "\e[93mpkg $PKG_COUNT = $(basename "$pkg")\e[0m"

        PACKAGE=$pkg

        check_package_owner
        if [[ $AMDPKG == 1 ]]; then
            extract_package
        fi

    done

    echo Extracting RPMs...Complete.
}

combine_rocm_deps() {
    echo ===================================================
    echo Combining dependencies from all component-rocm subdirectories...

    # Use the new deps/ directory structure
    local deps_root_dir="$EXTRACT_DEPS_DIR"
    if [ ! -d "$deps_root_dir" ]; then
        echo "ERROR: $deps_root_dir directory does not exist!"
        return 1
    fi

    # Put the combined deps file in EXTRACT_ROCM_DIR root
    local deps_dir="$EXTRACT_ROCM_DIR"

    local combined_deps_file="$deps_dir/rocm_required_deps_rpm.txt"
    local gfx_deps_file="$deps_dir/rocm_required_deps_rpm_gfx.tmp"
    local gfx_deps_sorted="$deps_dir/rocm_required_deps_rpm_gfx_sorted.tmp"
    local gfx_deps_filtered="$deps_dir/rocm_required_deps_rpm_gfx_filtered.tmp"
    local temp_deps_file="$deps_dir/rocm_required_deps_rpm.tmp"

    # Remove only the output file and temporary files
    echo "Removing previous rocm_required_deps_rpm.txt if it exists..."
    rm -f "$combined_deps_file" "$gfx_deps_file" "$gfx_deps_sorted" "$gfx_deps_filtered" "$temp_deps_file"

    # First pass: Process all gfx-specific subdirectories inside deps/
    local gfx_component_count=0
    for component_dir in "${deps_root_dir}"/gfx*; do
        if [ -d "$component_dir" ]; then
            local required_deps_file="$component_dir/$EXTRACT_REQUIRED_DEPS_FILE"
            if [ -f "$required_deps_file" ]; then
                echo "Processing gfx dependencies from: $component_dir"
                cat "$required_deps_file" >> "$gfx_deps_file"
                gfx_component_count=$((gfx_component_count + 1))
            fi
        fi
    done

    # Collect all packages.txt files from all subdirectories in deps/ to create comprehensive filter list
    local all_packages_file="$deps_dir/all_packages.tmp"
    rm -f "$all_packages_file"

    echo "Collecting all package names from all subdirectories for filtering..."
    for component_dir in "${deps_root_dir}"/*/; do
        if [ -d "$component_dir" ]; then
            local packages_file="$component_dir/$EXTRACT_PACKAGE_LIST_FILE"
            if [ -f "$packages_file" ]; then
                cat "$packages_file" >> "$all_packages_file"
            fi
        fi
    done

    # Combine, sort and remove duplicates from gfx dependencies
    if [ -f "$gfx_deps_file" ]; then
        echo "Combining, sorting, and removing duplicates from $gfx_component_count gfx component subdirectories..."
        sort -u "$gfx_deps_file" > "$gfx_deps_sorted"
        rm -f "$gfx_deps_file"

        # Filter out AMD ROCm packages using the comprehensive package list
        if [ -f "$all_packages_file" ]; then
            echo "Filtering out AMD ROCm packages from gfx dependencies..."
            # Extract package name and filter against AMD packages list
            while IFS= read -r dep_line; do
                pkg_name=$(echo "$dep_line" | awk '{print $1}' | sed 's/[<>=()].*//')
                if ! grep -qxF "$pkg_name" "$all_packages_file"; then
                    echo "$dep_line"
                fi
            done < "$gfx_deps_sorted" > "$gfx_deps_filtered"

            local filtered_count
            local remaining_count
            filtered_count=$(wc -l < "$gfx_deps_sorted")
            remaining_count=$(wc -l < "$gfx_deps_filtered")

            local removed_count=$((filtered_count - remaining_count))

            echo "Filtered out $removed_count AMD ROCm package dependencies"
            echo "Remaining external dependencies: $remaining_count"

            # Use filtered file as temp
            cp "$gfx_deps_filtered" "$temp_deps_file"
            rm -f "$gfx_deps_sorted" "$gfx_deps_filtered"
        else
            echo "WARNING: No packages.txt files found, skipping filter"
            cp "$gfx_deps_sorted" "$temp_deps_file"
            rm -f "$gfx_deps_sorted"
        fi
    fi

    # Second pass: Combine with base component subdirectory from deps/
    local base_component_dir="${deps_root_dir}/base"
    if [ -d "$base_component_dir" ]; then
        local required_deps_file="$base_component_dir/$EXTRACT_REQUIRED_DEPS_FILE"
        if [ -f "$required_deps_file" ]; then
            echo "Processing base component dependencies from: $base_component_dir"
            cat "$required_deps_file" >> "$temp_deps_file"
        fi
    fi

    # Final sort and remove duplicates, then filter against all AMD packages
    if [ ! -f "$temp_deps_file" ]; then
        echo "WARNING: No component-rocm subdirectories with required_deps.txt found"
        rm -f "$all_packages_file"
        return 1
    fi

    echo "Final combining, sorting, and filtering out AMD packages..."
    local temp_cleaned="$deps_dir/rocm_required_deps_cleaned.tmp"

    if [ -f "$all_packages_file" ]; then
        # Filter out any AMD packages from the combined dependencies
        # Extract package name (before space or comparison operator) and check against packages list
        sort -u "$temp_deps_file" | while IFS= read -r dep_line; do
            # Extract package name (everything before first space, =, <, >, or () for checking
            pkg_name=$(echo "$dep_line" | awk '{print $1}' | sed 's/[<>=()].*//')

            # Check if package name is in the AMD packages list
            if ! grep -qxF "$pkg_name" "$all_packages_file"; then
                # Keep the full line with version specifiers and OR alternatives
                # These are used by deps_installer.sh
                echo "$dep_line"
            fi
        done > "$temp_cleaned"
    else
        sort -u "$temp_deps_file" > "$temp_cleaned"
    fi

    # Second pass: Remove individual packages if they're already part of an OR alternative
    # For example, if we have "ocl-icd|ocl-icd-devel", remove individual "ocl-icd" and "ocl-icd-devel"
    # The OR alternative is more flexible (installer can choose either one)
    declare -A or_alternatives

    # First, collect all OR alternatives and their component packages
    while IFS= read -r dep_line; do
        [[ -z "$dep_line" ]] && continue
        if [[ "$dep_line" =~ \| ]]; then
            # This is an OR alternative (e.g., "ocl-icd|ocl-icd-devel")
            # Store the alternative itself
            or_alternatives[$dep_line]=1
            # Extract and store each component package name
            IFS='|' read -ra parts <<< "$dep_line"
            for part in "${parts[@]}"; do
                # Extract just the package name (strip version constraints)
                part=$(echo "$part" | xargs | awk '{print $1}')
                or_alternatives[$part]="COVERED_BY_OR"
            done
        fi
    done < "$temp_cleaned"

    # Now output: keep OR alternatives and individual packages NOT covered by OR alternatives
    while IFS= read -r dep_line; do
        [[ -z "$dep_line" ]] && continue

        if [[ "$dep_line" =~ \| ]]; then
            # This is an OR alternative - always keep it
            echo "$dep_line"
        else
            # Individual package - only keep if NOT covered by an OR alternative
            pkg_name=$(echo "$dep_line" | awk '{print $1}')
            if [[ "${or_alternatives[$pkg_name]}" != "COVERED_BY_OR" ]]; then
                echo "$dep_line"
            fi
        fi
    done < "$temp_cleaned" | sort -u > "$combined_deps_file"

    rm -f "$temp_cleaned"

    rm -f "$temp_deps_file" "$all_packages_file"

    local total_deps
    total_deps=$(wc -l < "$combined_deps_file")
    echo "Combined dependencies from $gfx_component_count gfx component subdirectories + base component"
    echo "Total unique required dependencies: $total_deps"
    echo "Output file: $combined_deps_file"

    echo Combining dependencies...Complete.
}

extract_meta_package_deps() {
    local meta_package="$1"
    local gfx_tag="$2"
    local output_file="$3"

    echo "=========================================="
    echo "Extracting dependencies for meta package: $meta_package"
    echo "GFX tag: $gfx_tag"
    echo "=========================================="

    # Determine deps directory for this gfx tag
    local deps_base_dir="../rocm-installer/component-rocm/deps/$gfx_tag"

    # Check if meta package deps directory exists
    local meta_pkg_dir="$deps_base_dir/$meta_package"
    if [ ! -d "$meta_pkg_dir" ]; then
        echo "ERROR: Meta package deps directory not found: $meta_pkg_dir"
        return 1
    fi

    # Check if deps.txt exists for the meta package
    local meta_deps_file="$meta_pkg_dir/deps.txt"
    if [ ! -f "$meta_deps_file" ]; then
        echo "ERROR: deps.txt not found for meta package: $meta_deps_file"
        return 1
    fi

    # Use associative array to track processed packages and avoid duplicates
    declare -A processed_packages
    declare -A all_dependencies

    # Add the meta package itself to the dependencies list
    all_dependencies["$meta_package"]=1

    # Queue for processing - start with meta package dependencies
    local -a process_queue=()

    # Read initial dependencies from meta package
    echo "Reading initial dependencies from: $meta_deps_file"
    while IFS= read -r dep_line; do
        # Skip empty lines and comments
        [[ -z "$dep_line" || "$dep_line" =~ ^# ]] && continue

        # Extract package name (remove version info after "=")
        local pkg_name
        # shellcheck disable=SC2001
        pkg_name=$(echo "$dep_line" | sed 's/[[:space:]]*=.*//')

        # Trim whitespace using bash parameter expansion
        pkg_name="${pkg_name#"${pkg_name%%[![:space:]]*}"}"
        pkg_name="${pkg_name%"${pkg_name##*[![:space:]]}"}"

        # Only process amdrocm packages
        if [[ "$pkg_name" =~ ^amdrocm- ]]; then
            process_queue+=("$pkg_name")
            all_dependencies["$pkg_name"]=1
        fi
    done < "$meta_deps_file"

    echo "Initial dependencies found: ${#process_queue[@]} (plus meta package itself)"

    # Recursively process dependencies
    local queue_index=0
    while [ $queue_index -lt ${#process_queue[@]} ]; do
        local current_pkg="${process_queue[$queue_index]}"
        queue_index=$((queue_index + 1))

        # Skip if already processed
        if [[ -n "${processed_packages[$current_pkg]}" ]]; then
            continue
        fi

        # Mark as processed
        processed_packages["$current_pkg"]=1

        echo "Processing dependencies for: $current_pkg"

        # Determine which directory to check (base or gfxXYZ)
        # Updated for new structure where deps are in component-rocm/deps/{gfx_tag}/{pkg}/deps.txt
        local pkg_deps_file=""

        # First check in the current gfx/base deps directory
        if [ -f "$deps_base_dir/$current_pkg/deps.txt" ]; then
            pkg_deps_file="$deps_base_dir/$current_pkg/deps.txt"
        # Then check in base directory (for packages like amdrocm-base, amdrocm-runtime, etc.)
        elif [ -f "../rocm-installer/component-rocm/deps/base/$current_pkg/deps.txt" ]; then
            pkg_deps_file="../rocm-installer/component-rocm/deps/base/$current_pkg/deps.txt"
        else
            # Check in all gfx directories (for gfx-specific packages when processing base meta packages)
            local found_in_gfx=0
            for gfx_check_dir in ../rocm-installer/component-rocm/deps/gfx*; do
                if [ -f "$gfx_check_dir/$current_pkg/deps.txt" ]; then
                    pkg_deps_file="$gfx_check_dir/$current_pkg/deps.txt"
                    found_in_gfx=1
                    echo "  Found in gfx directory: $(basename "$gfx_check_dir")"
                    break
                fi
            done

            if [ $found_in_gfx -eq 0 ]; then
                echo "  Warning: deps.txt not found for $current_pkg, skipping"
                continue
            fi
        fi

        # Read dependencies for this package
        while IFS= read -r dep_line; do
            # Skip empty lines and comments
            [[ -z "$dep_line" || "$dep_line" =~ ^# ]] && continue

            # Extract package name (remove version info after "=")
            local dep_pkg_name
            # shellcheck disable=SC2001
            dep_pkg_name=$(echo "$dep_line" | sed 's/[[:space:]]*=.*//')

            # Trim whitespace using bash parameter expansion
            dep_pkg_name="${dep_pkg_name#"${dep_pkg_name%%[![:space:]]*}"}"
            dep_pkg_name="${dep_pkg_name%"${dep_pkg_name##*[![:space:]]}"}"

            # Only process amdrocm packages
            if [[ "$dep_pkg_name" =~ ^amdrocm- ]]; then
                # Add to dependencies if not already present
                if [[ -z "${all_dependencies[$dep_pkg_name]}" ]]; then
                    all_dependencies["$dep_pkg_name"]=1
                    process_queue+=("$dep_pkg_name")
                    echo "  Found dependency: $dep_pkg_name"
                fi
            fi
        done < "$pkg_deps_file"
    done

    echo "Total unique amdrocm dependencies found: ${#all_dependencies[@]}"

    # Write sorted dependencies to output file
    echo "Writing dependencies to: $output_file"
    printf "%s\n" "${!all_dependencies[@]}" | sort > "$output_file"

    echo "Dependency extraction complete for $meta_package"
    echo "Output: $output_file"
    echo ""

    return 0
}

extract_meta_packages() {
    echo "=========================================="
    echo "Extracting meta package configurations..."
    echo "=========================================="

    echo "Using ROCM_VER: $ROCM_VER"

    # Create meta directory under deps/
    local meta_dir="../rocm-installer/component-rocm/deps/meta"
    if [ ! -d "$meta_dir" ]; then
        echo "Creating meta directory: $meta_dir"
        mkdir -p "$meta_dir"
    fi

    # Process each gfxXYZ directory from content/
    for gfx_dir in ../rocm-installer/component-rocm/content/gfx*; do
        if [ ! -d "$gfx_dir" ]; then
            continue
        fi

        local gfx_tag
        gfx_tag=$(basename "$gfx_dir")
        echo ""
        echo "Processing $gfx_tag directory..."

        # Process each specific meta package
        for meta_pkg_base in "${GFX_META_PACKAGES[@]}"; do
            # Construct the full meta package name: e.g., amdrocm-core7.12-gfx94x
            local meta_pkg_name="${meta_pkg_base}${ROCM_VER}-${gfx_tag}"
            local meta_pkg_dir="$gfx_dir/$meta_pkg_name"

            if [ ! -d "$meta_pkg_dir" ]; then
                echo "  Meta package not found: $meta_pkg_name (skipping)"
                continue
            fi

            echo "  Found meta package: $meta_pkg_name"

            # Output file will be in the meta directory with -meta.config suffix
            local output_file="$meta_dir/${meta_pkg_name}-meta.config"

            # Extract dependencies for this meta package
            extract_meta_package_deps "$meta_pkg_name" "$gfx_tag" "$output_file"
        done
    done

    # Process base directory for non-gfx meta packages from content/
    local base_dir="../rocm-installer/component-rocm/content/base"
    if [ -d "$base_dir" ]; then
        echo ""
        echo "Processing base directory for non-gfx meta packages..."

        # Process each specific meta package
        for meta_pkg_base in "${BASE_META_PACKAGES[@]}"; do
            # Construct the full meta package name: e.g., amdrocm-developer-tools7.12
            local meta_pkg_name="${meta_pkg_base}${ROCM_VER}"
            local meta_pkg_dir="$base_dir/$meta_pkg_name"

            if [ ! -d "$meta_pkg_dir" ]; then
                echo "  Meta package not found: $meta_pkg_name (skipping)"
                continue
            fi

            echo "  Found base meta package: $meta_pkg_name"

            # Output file will be in the meta directory with -meta.config suffix
            local output_file="$meta_dir/${meta_pkg_name}-meta.config"

            # Extract dependencies for this meta package
            extract_meta_package_deps "$meta_pkg_name" "base" "$output_file"
        done
    fi

    echo ""
    echo "Meta package configuration extraction complete."
}

extract_test_packages() {
    echo "=========================================="
    echo "Extracting test package configurations..."
    echo "=========================================="

    # Create test directory under deps/
    local test_dir="../rocm-installer/component-rocm/deps/test"
    if [ ! -d "$test_dir" ]; then
        echo "Creating test directory: $test_dir"
        mkdir -p "$test_dir"
    fi

    # Process each gfxXYZ directory to find test packages from content/
    for gfx_dir in ../rocm-installer/component-rocm/content/gfx*; do
        if [ ! -d "$gfx_dir" ]; then
            continue
        fi

        local gfx_tag
        gfx_tag=$(basename "$gfx_dir")
        echo ""
        echo "Processing $gfx_tag directory for test packages..."

        # Use associative array to track all packages (test + dependencies) and avoid duplicates
        # Must unset before declare to ensure array is cleared for each architecture
        unset all_test_packages
        declare -A all_test_packages

        # Find all test packages (packages with -test in the name)
        local test_pkg_list=()
        for pkg_dir in "$gfx_dir"/*-test*; do
            if [ -d "$pkg_dir" ]; then
                local pkg_name
                pkg_name=$(basename "$pkg_dir")
                test_pkg_list+=("$pkg_name")
                echo "  Found test package: $pkg_name"
            fi
        done

        # For each test package, resolve dependencies recursively
        for test_pkg in "${test_pkg_list[@]}"; do
            # Add the test package itself
            all_test_packages["$test_pkg"]=1

            # Queue for processing dependencies
            local -a dep_queue=("$test_pkg")
            unset processed_deps
            declare -A processed_deps

            while [ ${#dep_queue[@]} -gt 0 ]; do
                local current_pkg="${dep_queue[0]}"
                dep_queue=("${dep_queue[@]:1}")  # Remove first element

                # Skip if already processed
                [[ -n "${processed_deps[$current_pkg]}" ]] && continue
                processed_deps["$current_pkg"]=1

                # Find deps.txt for this package from deps/ structure
                local gfx_tag
                gfx_tag=$(basename "$gfx_dir")

                local deps_file=""
                if [ -f "../rocm-installer/component-rocm/deps/$gfx_tag/$current_pkg/deps.txt" ]; then
                    deps_file="../rocm-installer/component-rocm/deps/$gfx_tag/$current_pkg/deps.txt"
                elif [ -f "../rocm-installer/component-rocm/deps/base/$current_pkg/deps.txt" ]; then
                    deps_file="../rocm-installer/component-rocm/deps/base/$current_pkg/deps.txt"
                fi

                if [ -n "$deps_file" ]; then
                    # Read dependencies
                    while IFS= read -r dep_line; do
                        # Skip empty lines and comments
                        [[ -z "$dep_line" || "$dep_line" =~ ^# ]] && continue

                        # Extract package name (remove version info after "=")
                        local dep_pkg
                        # shellcheck disable=SC2001
                        dep_pkg=$(echo "$dep_line" | sed 's/[[:space:]]*=.*//')

                        # Trim whitespace using bash parameter expansion
                        dep_pkg="${dep_pkg#"${dep_pkg%%[![:space:]]*}"}"
                        dep_pkg="${dep_pkg%"${dep_pkg##*[![:space:]]}"}"

                        # Only process amdrocm packages
                        if [[ "$dep_pkg" =~ ^amdrocm- ]]; then
                            all_test_packages["$dep_pkg"]=1
                            dep_queue+=("$dep_pkg")
                        fi
                    done < "$deps_file"
                fi
            done
        done

        # If we found test packages for this architecture, create a config file
        if [ ${#all_test_packages[@]} -gt 0 ]; then
            local output_file="$test_dir/${gfx_tag}.config"
            echo "  Creating test config with dependencies: $output_file"

            # Write all packages (test + dependencies) to config file, sorted
            printf "%s\n" "${!all_test_packages[@]}" | sort > "$output_file"
            echo "  Wrote ${#all_test_packages[@]} packages (test + deps) to $output_file"
        else
            echo "  No test packages found for $gfx_tag"
        fi
    done

    # Also check base directory for non-gfx test packages (if any)
    local base_dir="../rocm-installer/component-rocm/base"
    if [ -d "$base_dir" ]; then
        echo ""
        echo "Processing base directory for test packages..."

        unset all_base_test_packages
        declare -A all_base_test_packages
        local base_test_pkg_list=()

        for pkg_dir in "$base_dir"/*-test*; do
            if [ -d "$pkg_dir" ]; then
                local pkg_name
                pkg_name=$(basename "$pkg_dir")
                base_test_pkg_list+=("$pkg_name")
                echo "  Found base test package: $pkg_name"
            fi
        done

        # Resolve dependencies for base test packages
        for test_pkg in "${base_test_pkg_list[@]}"; do
            all_base_test_packages["$test_pkg"]=1

            local -a dep_queue=("$test_pkg")
            unset processed_deps
            declare -A processed_deps

            while [ ${#dep_queue[@]} -gt 0 ]; do
                local current_pkg="${dep_queue[0]}"
                dep_queue=("${dep_queue[@]:1}")

                [[ -n "${processed_deps[$current_pkg]}" ]] && continue
                processed_deps["$current_pkg"]=1

                local deps_file="$base_dir/$current_pkg/deps/deps.txt"
                if [ -f "$deps_file" ]; then
                    while IFS= read -r dep_line; do
                        [[ -z "$dep_line" || "$dep_line" =~ ^# ]] && continue

                        local dep_pkg
                        # shellcheck disable=SC2001
                        dep_pkg=$(echo "$dep_line" | sed 's/[[:space:]]*=.*//')

                        # Trim whitespace using bash parameter expansion
                        dep_pkg="${dep_pkg#"${dep_pkg%%[![:space:]]*}"}"
                        dep_pkg="${dep_pkg%"${dep_pkg##*[![:space:]]}"}"

                        if [[ "$dep_pkg" =~ ^amdrocm- ]]; then
                            all_base_test_packages["$dep_pkg"]=1
                            dep_queue+=("$dep_pkg")
                        fi
                    done < "$deps_file"
                fi
            done
        done

        if [ ${#all_base_test_packages[@]} -gt 0 ]; then
            local output_file="$test_dir/base.config"
            echo "  Creating base test config with dependencies: $output_file"
            printf "%s\n" "${!all_base_test_packages[@]}" | sort > "$output_file"
            echo "  Wrote ${#all_base_test_packages[@]} packages (test + deps) to $output_file"
        else
            echo "  No base test packages found"
        fi
    fi

    echo ""
    echo "Test package configuration extraction complete."
}

combine_rocm_deps_meta() {
    echo "=========================================="
    echo "Combining ROCm dependencies metadata..."
    echo "=========================================="

    # This function is a wrapper that calls extract_meta_packages
    # It can be extended in the future to perform additional metadata operations

    extract_meta_packages
    extract_test_packages

    echo "ROCm dependencies metadata combination complete."
}

generate_package_signatures() {
    # Helper function to generate signature file for a single package
    local pkg_content_dir="$1"
    local signature_file="$2"

    # Clear existing signature file
    : > "$signature_file"

    local sig_count=0
    local max_sigs=10

    # Priority 1: Binaries (up to 5)
    while IFS= read -r file && [ $sig_count -lt $max_sigs ]; do
        local rel_path="${file#"$pkg_content_dir"/}"
        echo "$rel_path" >> "$signature_file"
        sig_count=$((sig_count + 1))
    done < <(find "$pkg_content_dir" -type f -path "*/bin/*" ! -name "*.txt" ! -name "*.md" 2>/dev/null | head -5)

    # Priority 2: Shared libraries (up to 3 more)
    while IFS= read -r file && [ $sig_count -lt $max_sigs ]; do
        local rel_path="${file#"$pkg_content_dir"/}"
        echo "$rel_path" >> "$signature_file"
        sig_count=$((sig_count + 1))
    done < <(find "$pkg_content_dir" -type f -path "*/lib/*" \( -name "*.so*" -o -name "*.a" \) 2>/dev/null | head -3)

    # Priority 3: Headers (up to 2 more)
    while IFS= read -r file && [ $sig_count -lt $max_sigs ]; do
        local rel_path="${file#"$pkg_content_dir"/}"
        echo "$rel_path" >> "$signature_file"
        sig_count=$((sig_count + 1))
    done < <(find "$pkg_content_dir" -type f -path "*/include/*" -name "*.h*" 2>/dev/null | head -2)

    # Fill remaining slots with any other files (skip docs)
    while IFS= read -r file && [ $sig_count -lt $max_sigs ]; do
        local rel_path="${file#"$pkg_content_dir"/}"
        if [[ ! "$rel_path" =~ \.(txt|md|rst|html|pdf)$ ]] && [[ ! "$rel_path" =~ /doc/ ]] && [[ ! "$rel_path" =~ /man/ ]]; then
            echo "$rel_path" >> "$signature_file"
            sig_count=$((sig_count + 1))
        fi
    done < <(find "$pkg_content_dir" -type f 2>/dev/null)

    if [ -s "$signature_file" ]; then
        local pkg_name
        pkg_name=$(basename "$(dirname "$signature_file")")
        echo "  Generated $sig_count signatures for $pkg_name"
    fi
}

generate_rocm_signature_files() {
    # Generate signature files for all ROCm components for uninstall auto-detection
    # This runs after all packages are extracted

    echo ===================================================
    echo "Generating signature files for uninstall detection..."
    echo ===================================================

    local content_base_dir="$EXTRACT_CONTENT_DIR/base"
    local deps_base_dir="$EXTRACT_DEPS_DIR/base"

    # Process base components
    if [ -d "$content_base_dir" ]; then
        for pkg_dir in "$content_base_dir"/*; do
            if [ -d "$pkg_dir" ]; then
                local pkg_name
                pkg_name=$(basename "$pkg_dir")

                local signature_file="$deps_base_dir/$pkg_name/signature.txt"
                mkdir -p "$(dirname "$signature_file")"

                generate_package_signatures "$pkg_dir" "$signature_file"
            fi
        done
    fi

    # Process gfx-specific components
    for gfx_dir in "$EXTRACT_CONTENT_DIR"/gfx*/; do
        if [ -d "$gfx_dir" ]; then
            local gfx_tag
            gfx_tag=$(basename "$gfx_dir")

            local deps_gfx_dir="$EXTRACT_DEPS_DIR/$gfx_tag"

            for pkg_dir in "$gfx_dir"/*; do
                if [ -d "$pkg_dir" ]; then
                    local pkg_name
                    pkg_name=$(basename "$pkg_dir")

                    local signature_file="$deps_gfx_dir/$pkg_name/signature.txt"
                    mkdir -p "$(dirname "$signature_file")"

                    generate_package_signatures "$pkg_dir" "$signature_file"
                fi
            done
        fi
    done

    echo "Generating signature files...Complete."
    echo ===================================================
}

extract_rocm_rpms() {
    echo ===================================================
    echo Extracting ROCm RPMs...

    PACKAGE_DIR="$PACKAGE_ROCM_DIR"
    EXTRACT_PKG_CONFIG_FILE="$EXTRACT_ROCM_PKG_CONFIG_FILE"

    # Check if package directory exists
    if [[ ! -d "$PACKAGE_DIR" ]]; then
        echo "ERROR: Package directory not found: $PACKAGE_DIR"
        return 1
    fi

    # Clean component-rocm directory before extraction to ensure fresh build
    if [ -d "$EXTRACT_ROCM_DIR" ]; then
        echo -e "\e[93mROCm component directory exists. Removing: $EXTRACT_ROCM_DIR\e[0m"
        $SUDO rm -rf "$EXTRACT_ROCM_DIR"
    fi
    echo "Creating ROCm component directory: $EXTRACT_ROCM_DIR"
    mkdir -p "$EXTRACT_ROCM_DIR"

    # Set up directory variables (directories created per gfx_tag in loop below)
    EXTRACT_CONTENT_DIR="${EXTRACT_ROCM_DIR}/content"
    EXTRACT_DEPS_DIR="${EXTRACT_ROCM_DIR}/deps"
    EXTRACT_SCRIPTLETS_DIR="${EXTRACT_ROCM_DIR}/scriptlets"

    echo "Processing packages from: $PACKAGE_DIR"
    echo "Organizing by gfx tag into component-rocm subdirectories..."

    PACKAGE_LIST=

    # Collect all package files and group by gfx/base tag
    declare -A GFX_PACKAGES
    GFX_PACKAGES["base"]=""

    for pkg_file in "$PACKAGE_DIR"/*.rpm; do
        if [[ -f "$pkg_file" ]]; then
            pkg_name=$(basename "$pkg_file")

            # Detect gfx tag from package name (e.g., amdrocm-blas7.11-gfx94x-*.rpm)
            if [[ "$pkg_name" =~ -gfx([0-9a-z]+)- ]]; then
                gfx_tag="gfx${BASH_REMATCH[1]}"
                GFX_PACKAGES["$gfx_tag"]+="$pkg_file "
            else
                # Non-gfx package goes to base
                GFX_PACKAGES["base"]+="$pkg_file "
            fi
        fi
    done

    # Process each gfx/base group
    for gfx_tag in "${!GFX_PACKAGES[@]}"; do
        pkg_list="${GFX_PACKAGES[$gfx_tag]}"

        # Skip if no packages for this tag
        if [[ -z "$pkg_list" ]]; then
            continue
        fi

        echo ""
        echo "=========================================="
        echo "Processing $gfx_tag packages"
        echo "=========================================="

        # Set component type and create directory hierarchy
        COMP_TYPE="$gfx_tag"

        echo "COMP_TYPE = $COMP_TYPE"
        echo "Creating extraction directories for $COMP_TYPE:"
        echo "  $EXTRACT_CONTENT_DIR/$COMP_TYPE"
        echo "  $EXTRACT_DEPS_DIR/$COMP_TYPE"
        echo "  $EXTRACT_SCRIPTLETS_DIR/$COMP_TYPE"
        mkdir -p "$EXTRACT_CONTENT_DIR/$COMP_TYPE" "$EXTRACT_DEPS_DIR/$COMP_TYPE" "$EXTRACT_SCRIPTLETS_DIR/$COMP_TYPE"
        echo -----------------------------------------

        init_stats

        # Set PKG_LIST and PACKAGES for this gfx group
        read -r -a PKG_LIST <<< "$pkg_list"
        PACKAGES="$pkg_list"
        PKG_COUNT=${#PKG_LIST[@]}

        extract_rpms

        add_extra_deps

        write_extract_info
        filter_deps_version

        echo -e "\e[93m========================================\e[0m"
        echo -e "\e[93mExtracted: $PKG_COUNT $gfx_tag packages\e[0m"
        echo -e "\e[93m========================================\e[0m"
    done

    # Combine dependencies from all component-rocm subdirectories
    echo ""
    combine_rocm_deps

    # Extract meta package configurations
    echo ""
    combine_rocm_deps_meta

    # Generate signature files for uninstall auto-detection
    echo ""
    generate_rocm_signature_files

    echo ""
    echo Extracting ROCm RPMs...Complete.
}

extract_amdgpu_rpms() {
    echo ===================================================
    echo Extracting AMDGPU RPMs...

    PACKAGE_DIR="$PACKAGE_AMDGPU_DIR"
    EXTRACT_PKG_CONFIG_FILE="$EXTRACT_AMDGPU_PKG_CONFIG_FILE"

    # Check if package directory exists
    if [[ ! -d "$PACKAGE_DIR" ]]; then
        echo "ERROR: Package directory not found: $PACKAGE_DIR"
        return 1
    fi

    # Extract distro name from EXTRACT_AMDGPU_DIR path to use as COMP_TYPE
    # e.g., ../rocm-installer/component-amdgpu/el9 → COMP_TYPE=el9
    local amdgpu_base_dir
    amdgpu_base_dir=$(dirname "$EXTRACT_AMDGPU_DIR")
    COMP_TYPE=$(basename "$EXTRACT_AMDGPU_DIR")

    # Clean this distro's subdirectory before extraction
    if [ -d "$EXTRACT_AMDGPU_DIR" ]; then
        echo -e "\e[93mAMDGPU distro directory exists. Removing: $EXTRACT_AMDGPU_DIR\e[0m"
        $SUDO rm -rf "$EXTRACT_AMDGPU_DIR"
    fi

    # Set up directory variables
    EXTRACT_CONTENT_DIR="${amdgpu_base_dir}/content"
    EXTRACT_DEPS_DIR="${amdgpu_base_dir}/deps"
    EXTRACT_SCRIPTLETS_DIR="${amdgpu_base_dir}/scriptlets"

    echo "Processing packages from: $PACKAGE_DIR"
    echo "Organizing by distro: $COMP_TYPE"

    # Create directory hierarchy for this distro
    echo "Creating extraction directories for $COMP_TYPE:"
    echo "  $EXTRACT_CONTENT_DIR/$COMP_TYPE"
    echo "  $EXTRACT_DEPS_DIR/$COMP_TYPE"
    echo "  $EXTRACT_SCRIPTLETS_DIR/$COMP_TYPE"
    mkdir -p "$EXTRACT_CONTENT_DIR/$COMP_TYPE" "$EXTRACT_DEPS_DIR/$COMP_TYPE" "$EXTRACT_SCRIPTLETS_DIR/$COMP_TYPE"

    init_stats

    echo "Getting package list..."
    PACKAGE_LIST=

    for pkg in "$PACKAGE_DIR"/*; do
        if [[ $pkg == *.rpm ]]; then
            PACKAGES+="$pkg "
        fi
    done

    # Extract the amdgpu rpms
    extract_rpms

    echo Extracting AMDGPU RPMs...Complete.

    echo -e "\e[93m========================================\e[0m"
    echo -e "\e[93m$PKG_COUNT AMDGPU packages extracted\e[0m"
    echo -e "\e[93m========================================\e[0m"

    # extract the amdgpu-dkms build version
    # content/{distro}/amdgpu-dkms/usr/src
    local amdgpu_dkms_path="$EXTRACT_CONTENT_DIR/$COMP_TYPE/amdgpu-dkms/usr/src"

    if [ -d "$amdgpu_dkms_path" ]; then
        AMDGPU_DKMS_BUILD_VER=$(ls "$amdgpu_dkms_path")
        AMDGPU_DKMS_BUILD_VER=${AMDGPU_DKMS_BUILD_VER#amdgpu-}

        echo AMDGPU_DKMS_BUILD_VER = "$AMDGPU_DKMS_BUILD_VER"

        # Create root-level amdgpu-dkms-ver.txt with distro suffix removed
        local root_amdgpu_dkms_file="$amdgpu_base_dir/$EXTRACT_AMDGPU_DKMS_VER_FILE"
        # Strip distro suffix using sed to match known patterns
        # e.g., 6.16.13-2278356.24.04 -> 6.16.13-2278356
        # e.g., 6.16.13-2278356.el8 -> 6.16.13-2278356
        # e.g., 6.16.13-2278356.amzn2023 -> 6.16.13-2278356
        local clean_ver
        clean_ver=$(echo "$AMDGPU_DKMS_BUILD_VER" | sed -E 's/\.(el[0-9]+|amzn[0-9]+|[0-9]+\.[0-9]+)$//')

        echo "Writing root AMDGPU_DKMS_VER (distro suffix removed) = $clean_ver"
        mkdir -p "$(dirname "$root_amdgpu_dkms_file")"
        echo "$clean_ver" > "$root_amdgpu_dkms_file"
    fi

    # reorder the amdgpu package config to ensure the order
    # deps/{distro}/amdgpu-packages.config
    local config_file="$EXTRACT_DEPS_DIR/$COMP_TYPE/$EXTRACT_AMDGPU_PKG_CONFIG_FILE"

    local packages
    packages=$(cat "$config_file")

    local reordered_packages=""

    # Ensure "amdgpu-dkms-firmware" is the first package
    if echo "$packages" | grep -q "^amdgpu-dkms-firmware$"; then
        reordered_packages+="amdgpu-dkms-firmware"$'\n'
        packages=$(echo "$packages" | grep -v "^amdgpu-dkms-firmware$")
    fi

    # Ensure "amdgpu-dkms" is the second package
    if echo "$packages" | grep -q "^amdgpu-dkms$"; then
        reordered_packages+="amdgpu-dkms"$'\n'
        packages=$(echo "$packages" | grep -v "^amdgpu-dkms$")
    fi

    # Append the remaining packages
    reordered_packages+="$packages"

    # Write the reordered packages back to the config file
    echo "$reordered_packages" > "$config_file"
    echo "Reordered packages written to '$config_file'."
}

write_extract_info() {
    # Dump stats for the new structure directories
    echo "Extraction statistics for: $COMP_TYPE"
    dump_extract_stats "$EXTRACT_CONTENT_DIR/$COMP_TYPE"

    write_global_deps
    write_package_list

    scriptlet_stats
}


####### Main script ###############################################################

# Create the extraction log directory
if [ ! -d "$EXTRACT_LOGS_DIR" ]; then
    mkdir -p "$EXTRACT_LOGS_DIR"
fi

exec > >(tee -a "$EXTRACT_CURRENT_LOG") 2>&1

echo ===============================
echo PACKAGE EXTRACTOR - RPM
echo ===============================

PROG=${0##*/}
SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO="sudo"

os_release

if [ "$#" -lt 1 ]; then
   echo Missing argument
   exit 1
fi

# parse args
while (($#))
do
    case "$1" in
    help)
        usage
        exit 0
        ;;
    prompt)
        echo "Enabling user prompts."
        PROMPT_USER=1
        shift
        ;;
    amdgpu)
        echo "Enabling amdgpu extract."
        AMDGPU_EXTRACT=1
        shift
        ;;
    rocm)
        echo "Enabling rocm extract."
        ROCM_EXTRACT=1
        shift
        ;;
    nocontent)
        echo "Disabling content/data extraction."
        EXTRACT_CONTENT=0
        shift
        ;;
    contentlist)
        echo "Enabling content file listing during extraction."
        CONTENT_LIST=1
        shift
        ;;
    resolveautodeps)
        echo "Enabling automatic dependency resolution."
        RESOLVE_AUTO_DEPS=1
        shift
        ;;
    build-config=*)
        BUILD_CONFIG_FILE="${1#*=}"
        echo "Using build config file: $BUILD_CONFIG_FILE"
        shift
        ;;
    pkgs-rocm=*)
        PACKAGE_ROCM_DIR="${1#*=}"
        echo "Using ROCm Packages source: $PACKAGE_ROCM_DIR"
        shift
        ;;
    pkgs-amdgpu=*)
        PACKAGE_AMDGPU_DIR="${1#*=}"
        echo "Using AMDGPU Packages source: $PACKAGE_AMDGPU_DIR"
        shift
        ;;
    ext-rocm=*)
        EXTRACT_ROCM_DIR="${1#*=}"
        EXTRACT_ROCM_DIR+="/component-rocm"
        echo "Extract ROCm output: $EXTRACT_ROCM_DIR"
        shift
        ;;
    ext-amdgpu=*)
        EXTRACT_AMDGPU_DIR="${1#*=}"
        echo "Extract AMDGPU output: $EXTRACT_AMDGPU_DIR"
        shift
        ;;
    *)
        shift
        ;;
    esac
done

# Validate resolveautodeps configuration
if [[ $RESOLVE_AUTO_DEPS -eq 1 ]]; then
    if [[ -z "$BUILD_CONFIG_FILE" ]]; then
        echo "[WARNING] resolveautodeps enabled but required build-config not provided."
        echo "[WARNING] Use: build-config=<path-to-config-file>"
        echo "[WARNING] Disabling automatic dependency resolution."
        RESOLVE_AUTO_DEPS=0
    elif [[ ! -f "$BUILD_CONFIG_FILE" ]]; then
        echo "[WARNING] Build config file not found: $BUILD_CONFIG_FILE"
        echo "[WARNING] Disabling automatic dependency resolution."
        RESOLVE_AUTO_DEPS=0
    else
        echo "Automatic dependency resolution enabled with build config: $BUILD_CONFIG_FILE"
        build_local_provides_cache
    fi
fi

prompt_user "Extract packages (y/n): "
if [[ $option == "N" || $option == "n" ]]; then
    echo "Exiting extractor."
    exit 1
fi

install_tools

if [[ $ROCM_EXTRACT == 1 ]]; then
    extract_rocm_rpms
fi

if [[ $AMDGPU_EXTRACT == 1 ]]; then
    extract_amdgpu_rpms
    write_extract_info

    filter_deps_version
fi

if [[ -n $EXTRACT_CURRENT_LOG ]]; then
    echo -e "\e[32mExtract log stored in: $EXTRACT_CURRENT_LOG\e[0m"
fi

