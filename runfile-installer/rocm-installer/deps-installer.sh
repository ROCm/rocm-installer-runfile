#!/bin/bash
# shellcheck disable=SC2086  # Package lists intentionally use word splitting (except where specifically quoted)

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

# Colour text
YELLOW="\033[0;93m"
GREEN='\033[0;32m'
NC='\033[0m' # No Color

DEPS_COUNT=0

DEPS=

USE_ROCM=0
USE_AMDGPU=0
USE_GRAPHICS=0      # Flag for graphics use case (amdgpu-lib)

# GFX-specific and graphics dependencies
INSTALL_GFX=""      # GFX architecture for kernel deps (e.g., gfx1150)

MISSING_DEPS=
MISSING_DEPS_COUNT=0
INSTALL_DEPS_COUNT=0

DEPS_LIST_ONLY=0
PROMPT_USER=0
VERBOSE=0

INSTALLABLE_PKG_CACHE=

NO_CMD_OUTPUT="> /dev/null 2>&1"

WGET_RETRY_COUNT=5

GCC_TOOLSET_PACKAGES_OL=(gcc-toolset-11-gcc gcc-toolset-11-gcc-c++ gcc-toolset-11-gcc-gfortran gcc-toolset-11-libquadmath-devel gcc-toolset-11-libstdc++-devel gcc-toolset-11-gcc-gdb-plugin)

declare -A SLES_PKG_CACHE
declare -A CAPABILITY_MAP_CACHE  # Maps RHEL package names to capabilities for SLES resolution

# Debian kernel package URLs from snapshot.debian.org (package -> URL)
declare -A DEBIAN_KERNEL_PKG_INFO

EPEL_SETUP=1

###### Functions ###############################################################

usage() {
cat <<END_USAGE
The dependencies installer reads in the required_deps.txt file for extracted component-<name>
and lists or installs missing dependencies based on the required deps list.

Usage: $PROG [options]

[options}:
    help         = Display this help information.
    prompt       = Prompts user prior to installing dependencies.
    amdgpu       = Check dependencies for extracted AMDGPU packages.
    rocm         = Check dependencies for extracted ROCm packages.
    list         = List the dependencies (amdgpu, rocm, amdgpu and rocm)
    install      = Install dependencies for selected packages (amdgpu, rocm, amdgpu and rocm)
    install-file = Install dependencies from a file.
    verbose      = Enable verbose logging

    Example:

    ./deps-installer.sh list amdgpu rocm    = list dependencies for both amdgpu and rocm
    ./deps-installer.sh install rocm        = install rocm dependencies

END_USAGE
}

os_release() {
    if [[ -r  /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release

        DISTRO_NAME=$ID

        case "$ID" in
        ubuntu|debian)
            DISTRO_PACKAGE_MGR="apt"
            DISTRO_CACHE_CHK="apt-cache show"
            DISTRO_VIRTUAL_CHK="apt-cache showpkg"
            PACKAGE_TYPE="deb"
            ;;
        rhel|centos|ol|rocky|almalinux|anolis|tencentos|alinux|amzn)
            DISTRO_PACKAGE_MGR="dnf"
            DISTRO_CACHE_CHK="$SUDO dnf --cacheonly info"
            DISTRO_VIRTUAL_CHK="dnf provides"
            PACKAGE_TYPE="rpm"
            ;;
        sles)
            DISTRO_PACKAGE_MGR="zypper"
            DISTRO_CACHE_CHK="zypper search --type package --match-exact"
            DISTRO_VIRTUAL_CHK="zypper search --provides --match-exact"
            PACKAGE_TYPE="rpm"

            # install awk if required
            if ! rpm -qa | grep -q "awk"; then
                echo "Package: awk missing. Installing..."
                $SUDO zypper install -y awk > /dev/null 2>&1
                echo "Package: awk installed."
            fi

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

    DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
    DISTRO_MAJOR_VER=${DISTRO_VER%.*}
}

get_os_codename() {
    # Get Ubuntu codename for graphics repo
    # Supported: Ubuntu 24.04 (noble), Ubuntu 26.04 (resolute)

    case "$DISTRO_NAME" in
        ubuntu)
            # For Ubuntu, use the actual codename
            if [[ -r /etc/os-release ]]; then
                local codename
                codename=$(awk -F= '/^VERSION_CODENAME=/{print $2}' /etc/os-release | tr -d '"')
                if [[ -n "$codename" ]]; then
                    echo "$codename"
                    return 0
                fi
            fi
            # Fallback for Ubuntu based on version
            case "$DISTRO_VER" in
                26.04) echo "resolute" ;;
                24.04) echo "noble" ;;
                *) echo "unknown" ;;
            esac
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

os_checks() {
    # Rocky 9 support only
    if [[ $DISTRO_VER != 9* ]] && [[ "$DISTRO_NAME" = "rocky" ]]; then
        echo "$DISTRO_NAME $DISTRO_VER is not a supported OS"
        exit 1
    fi

    # Map EPEL version for distros that use different versioning
    EPEL_VER="$DISTRO_MAJOR_VER"

    # Handle EPEL setup for distros with special versioning or repo requirements
    if [[ "$DISTRO_NAME" = "amzn" ]]; then
        # Amazon Linux has its own complete repos, doesn't need EPEL
        echo "Disable EPEL/CRB for Amazon Linux."
        EPEL_SETUP=0
    elif [[ "$DISTRO_NAME" = "tencentos" ]]; then
        # TencentOS: version 3 needs EPEL, version 4 has complete repos
        # Map version: 3 -> EPEL 8, 4 -> EPEL 9 (disabled)
        if [[ "$DISTRO_MAJOR_VER" = "3" ]]; then
            echo "Enable EPEL 8 for TencentOS 3 (needed for packages like dkms)."
            EPEL_VER="8"
            EPEL_SETUP=1
        elif [[ "$DISTRO_MAJOR_VER" = "4" ]]; then
            echo "Disable EPEL/CRB for TencentOS 4 (has complete repos)."
            EPEL_VER="9"
            EPEL_SETUP=0
        fi
    elif [[ "$DISTRO_NAME" = "alinux" ]]; then
        # Alibaba Cloud Linux: version 3 needs EPEL, version 4 has complete repos
        # Map version: 3 -> EPEL 8, 4 -> EPEL 9 (disabled)
        if [[ "$DISTRO_MAJOR_VER" = "3" ]]; then
            echo "Enable EPEL 8 for Alibaba Cloud Linux 3 (needed for packages like dkms)."
            EPEL_VER="8"
            EPEL_SETUP=1
        elif [[ "$DISTRO_MAJOR_VER" = "4" ]]; then
            echo "Disable EPEL/CRB for Alibaba Cloud Linux 4 (has complete repos)."
            EPEL_VER="9"
            EPEL_SETUP=0
        fi
    fi

    echo "Dependency install on $DISTRO_NAME $DISTRO_VER."
}

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
            # SLES: 15.6 -> sle15, 15.5 -> sle15
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

remove_rocky_kernel_repo() {
    if [ -f /etc/yum.repos.d/appstream-amdgpu.repo ]; then
        echo Removing Rocky AppStream repos...

        echo "-=-=-= Removing appstream-amdgpu.repo -=-=-="
        $SUDO rm /etc/yum.repos.d/appstream-amdgpu.repo

         # Cleanup the dnf caches
        sudo dnf clean all
        sudo rm -rf /var/cache/dnf/*
        sudo dnf makecache

        echo Removing Rocky AppStream repos...Complete.
    fi
}

cleanup() {
    echo "------------------------------------"
    echo Cleaning up...

    if [[ "$DISTRO_NAME" = "rocky" ]]; then
        remove_rocky_kernel_repo
    elif [[ "$DISTRO_NAME" = "debian" ]]; then
        # delete block-headers file which may be added during debian 12 dependency install
        if [[ -f /etc/apt/preferences.d/block-headers ]]; then
            $SUDO rm /etc/apt/preferences.d/block-headers
        fi
    fi

    echo Cleaning up...Complete.
}

check_virtual_package_deb() {
    local package_name=$1
    local installable_package=""
    local install_result=1

    # Check if the package is a virtual package
    if apt-cache showpkg "$package_name" | grep -q "Reverse Provides:"; then
        # Find the package that provides the virtual package
        installable_package=$($DISTRO_VIRTUAL_CHK "$package_name" | awk '
            /Reverse Provides:/ {
                getline;
                if ($1 != "" && $1 != "Reverse") {
                    print $1;
                }
            }'
        )

        if [[ -n $installable_package ]]; then
            echo "Package $package_name can be installed via $installable_package."
            install_result=0
        else
            echo "No providing package found for $package_name."
        fi
    fi

    # set the virtual package name
    VIRTUAL_PACKAGE="$installable_package"

    return $install_result
}

is_pkg_installable_deb() {
    local dep="$1"
    local install_result=0

    eval "$DISTRO_CACHE_CHK $dep $NO_CMD_OUTPUT"
    install_result=$?

    # if the dep is a virtual package - check for the virtual package
    if [[ $install_result -eq 0 ]]; then
        print_str "Checking for virtual package."

        if ! $DISTRO_CACHE_CHK "$dep" 2>&1 | grep -q "Package"; then
            echo Virtual package.
            check_virtual_package_deb "$dep"
            install_result=$?
        fi
    fi

    # get the version of the installable package
    if [[ $install_result -eq 0 ]]; then
        INSTALL_VER=$(apt-cache show "$dep" 2>/dev/null | grep -m1 "^Version:" | awk '{print $2}' | cut -d'-' -f1)
    fi

    return $install_result
}

is_pkg_available_to_download_deb() {
    local pkg="$1"
    apt-cache policy "$pkg" | sed -n "/Version/,\$p" | grep -q http
    return $?
}

get_dep_from_cache() {
    local dep="$1"

    if [[ -z "$dep" ]]; then
        return 1
    fi

    local entry
    entry=$(echo "$INSTALLABLE_PKG_CACHE" | grep "^$dep,")

    if [[ -n "$entry" ]]; then
        DEPS_INTS_NAME=$(echo "$entry" | cut -d',' -f1)
        DEPS_INST_VER=$(echo "$entry" | cut -d',' -f2)
        return 0
    else
        DEPS_INTS_NAME=""
        DEPS_INST_VER=""
        return 1
    fi
}

check_pkg_cache() {
    print_str "Checking: package cache for $1" 1

    local pkg=$1
    local pkg_cached=1

    if [[ -z $INSTALLABLE_PKG_CACHE ]]; then
        # No cache available
        return 1
    fi

    if get_dep_from_cache "$pkg"; then
        print_str "Package : $DEPS_INTS_NAME | $DEPS_INST_VER (cache)" 2
        pkg_cached=0
    else
        print_str "Package : $pkg not found in cache."
    fi

    return $pkg_cached
}

build_installable_pkg_cache_dnf() {
    echo "------------------------------------"
    echo "Building dnf installable cache..."

    PACKAGE_DEP_LIST=""

    if [[ -n $MISSING_DEPS ]]; then
        # Build a list of all the potential deps that are missing, removing all versioning/multiple deps etc.
        IFS=',' read -ra package_array <<< "$MISSING_DEPS"

        for pkg in "${package_array[@]}"; do
           # shellcheck disable=SC2001
           testdep=$(echo "$pkg" | sed 's/^ *//')

           # check for a multi-option dependency
            if echo "$testdep" | grep -q '|'; then

                # build the list of packages removing all spaces and replacing "|" with spaces
                deplist=$(echo "$testdep" | tr -d ' ' | tr '|' ' ')

                for dep_pkg in $deplist; do
                    print_str "+++++++++++++++++++++"
                    print_str "Checking: $dep_pkg"

                    # remove versioning
                    if [ $PACKAGE_TYPE == "deb" ]; then
                        dep=$(echo "$dep_pkg" | sed -E 's/\([><!=]*[0-9.]*\)//g')
                        dep_version=$(echo "$dep_pkg" | grep -oE '[0-9.]+')
                    else
                        dep=$(echo "$dep_pkg" | sed -E 's/[><=!]=?[0-9.]+//g')
                        dep_version=$(echo "$dep_pkg" | grep -oE '[0-9.]+')
                    fi
                    print_str "Name/Ver: $dep | $dep_version"
                    PACKAGE_DEP_LIST+="$dep "
                done

            else
                VIRTUAL_PACKAGE=""

                # single dependency check
                dep=$(echo "$testdep" | awk '{print $1}')
                PACKAGE_DEP_LIST+="$dep "
            fi
        done

        # query the dnf cache for the list of packages available for install using the full missing deps list
        INSTALLABLE_PKG_CACHE=$($DISTRO_CACHE_CHK $PACKAGE_DEP_LIST | grep -E "^(Name|Version)" | sed 'N;s/Name *: *\(.*\)\nVersion *: *\(.*\)/\1,\2/' | sort -u)

        echo ----------------------
        echo "$INSTALLABLE_PKG_CACHE"
        echo ----------------------
    fi

    echo "Building dnf installable cache...Complete."
}

# Extract actual package name from dnf provides output
get_package_from_provides_dnf() {
    local capability="$1"
    local providing_package=""

    # dnf provides output format:
    # package-name-version.arch : Summary
    # Repo        : repo-name
    # Matched from:
    # Provide    : capability

    # Filter out status messages (Updating, Last metadata, etc.) then look for package lines
    # Status messages to exclude: "Updating...", "Last metadata...", etc.
    providing_package=$(dnf provides "$capability" 2>/dev/null | \
        grep -vE "^(Updating|Last metadata|Repo|Matched from|Provide)" | \
        grep -E "^[a-zA-Z0-9]" | \
        head -1 | \
        awk '{print $1}' | \
        sed 's/-[0-9].*//')

    if [[ -n $providing_package ]]; then
        print_str "Capability '$capability' provided by package: $providing_package" 1
        VIRTUAL_PACKAGE="$providing_package"
        return 0
    fi

    return 1
}

get_package_from_provides_zypper() {
    local capability="$1"
    local providing_package=""

    print_str "Searching for provider of capability: $capability" 1

    # Use zypper search --provides to find packages that provide this capability
    local search_output
    search_output=$(zypper search --provides "$capability" 2>&1)

    # Parse the table output: S  | Name | Summary | Type
    # Extract the Name column (field 2) from data rows
    local all_packages
    all_packages=$(echo "$search_output" | \
        grep "^[[:space:]]*|" | \
        grep -v "^S[[:space:]]*|" | \
        grep -v "^[-]*$" | \
        awk -F'|' 'NF>=3 {
            gsub(/^[ \t]+|[ \t]+$/, "", $2);
            if ($2 != "" && $2 != "Name") {
                print $2;
            }
        }')

    if [[ -z "$all_packages" ]]; then
        print_str "No providers found for capability: $capability" 3
        return 1
    fi

    print_str "Found providers: $(echo "$all_packages" | tr '\n' ' ')" 1

    # First, exclude obvious non-runtime packages
    local runtime_packages
    runtime_packages=$(echo "$all_packages" | grep -v -E -- '-(devel|devel-static|doc|debuginfo|debugsource|static|32bit)$')

    # Exclude texlive unless explicitly searching for it
    if [[ "$capability" != *"tex"* && "$capability" != *"latex"* ]]; then
        runtime_packages=$(echo "$runtime_packages" | grep -v "^texlive-")
    fi

    print_str "After filtering: $(echo "$runtime_packages" | tr '\n' ' ')" 1

    # If we filtered everything out, the package might legitimately be a -devel package
    # In that case, use all_packages but still exclude texlive
    if [[ -z "$runtime_packages" ]]; then
        if [[ "$capability" != *"tex"* && "$capability" != *"latex"* ]]; then
            runtime_packages=$(echo "$all_packages" | grep -v "^texlive-")
        else
            runtime_packages="$all_packages"
        fi
        print_str "No runtime packages found, using all providers (excluding texlive)" 1
    fi

    # Priority selection:
    # 1. Exact match
    providing_package=$(echo "$runtime_packages" | grep -x "${capability}" | head -1)

    # 2. Package name starts with capability (e.g., libomp5 for libomp)
    if [[ -z $providing_package ]]; then
        providing_package=$(echo "$runtime_packages" | grep "^${capability}" | head -1)
    fi

    # 3. Package name contains capability
    if [[ -z $providing_package ]]; then
        providing_package=$(echo "$runtime_packages" | grep "${capability}" | head -1)
    fi

    # 4. First available package from filtered list
    if [[ -z $providing_package ]]; then
        providing_package=$(echo "$runtime_packages" | head -1)
    fi

    # Validate the selected package exists
    if [[ -n $providing_package ]]; then
        if zypper info "$providing_package" &>/dev/null; then
            print_str "Selected provider: $providing_package for capability: $capability" 2
            VIRTUAL_PACKAGE="$providing_package"
            return 0
        else
            print_str "Selected package $providing_package does not exist" 3
            return 1
        fi
    fi

    print_str "No suitable provider found for capability: $capability" 3
    return 1
}

# Apply SLES package name translation if needed
# Load capability mapping file for SLES runtime resolution
# Format: capability|rhel-package (e.g., "libnuma.so.1()(64bit)|numactl-libs")
load_capability_mapping() {
    local capability_map_file="$COMPONENT_DIR/component-rocm/deps/rocm_capability_map.txt"

    # Only load once
    if [[ ${#CAPABILITY_MAP_CACHE[@]} -gt 0 ]]; then
        return 0
    fi

    if [[ ! -f "$capability_map_file" ]]; then
        print_str "Capability mapping file not found: $capability_map_file" 2
        print_str "Cross-distro resolution may be limited" 2
        return 1
    fi

    print_str "Loading capability mapping for cross-distro resolution..." 1

    local count=0
    while IFS='|' read -r capability package; do
        [[ -z "$capability" || -z "$package" ]] && continue

        # Store mapping: package -> capability
        CAPABILITY_MAP_CACHE[$package]="$capability"
        count=$((count + 1))
    done < "$capability_map_file"

    print_str "Loaded $count capability mappings" 1
    return 0
}

# Resolve a capability to SLES package using zypper
# Args: $1 = capability (e.g., "libnuma.so.1()(64bit)")
# Returns: Package name or empty if not found
resolve_capability_sles() {
    local capability="$1"
    local resolved_pkg=""

    # Try exact match first
    resolved_pkg=$(zypper --quiet what-provides "$capability" 2>/dev/null | \
                   grep -E '^\s*[a-zA-Z]' | \
                   grep -v '^Searching' | \
                   head -n 1 | \
                   awk '{print $2}')

    if [[ -n "$resolved_pkg" ]]; then
        echo "$resolved_pkg"
        return 0
    fi

    # Try with ()(64bit) suffix - RPM capabilities are stripped during extraction
    # but zypper may need the full form
    if [[ ! "$capability" =~ \( ]]; then
        resolved_pkg=$(zypper --quiet what-provides "${capability}()(64bit)" 2>/dev/null | \
                       grep -E '^\s*[a-zA-Z]' | \
                       grep -v '^Searching' | \
                       head -n 1 | \
                       awk '{print $2}')

        if [[ -n "$resolved_pkg" ]]; then
            echo "$resolved_pkg"
            return 0
        fi
    fi

    # Try with wildcard path (e.g., "libltdl.so.7" -> "*/libltdl.so.7")
    resolved_pkg=$(zypper --quiet what-provides "*/$capability" 2>/dev/null | \
                   grep -E '^\s*[a-zA-Z]' | \
                   grep -v '^Searching' | \
                   head -n 1 | \
                   awk '{print $2}')

    if [[ -n "$resolved_pkg" ]]; then
        echo "$resolved_pkg"
        return 0
    fi

    # Try search --provides as fallback
    resolved_pkg=$(zypper search --provides --match-exact "$capability" 2>/dev/null | \
                   grep '^i\|^v' | \
                   awk '{print $2}' | \
                   head -n 1)

    if [[ -n "$resolved_pkg" ]]; then
        echo "$resolved_pkg"
        return 0
    fi

    # Try with glob pattern
    resolved_pkg=$(zypper search --provides "$capability" 2>/dev/null | \
                   grep '^i\|^v' | \
                   awk '{print $2}' | \
                   head -n 1)

    if [[ -n "$resolved_pkg" ]]; then
        echo "$resolved_pkg"
        return 0
    fi

    return 1
}

# Returns: 0 if package should be processed, 1 if should be skipped
# Sets PKG_TRANSLATED to the translated package name
apply_sles_translation() {
    local pkg="$1"
    PKG_TRANSLATED="$pkg"

    if [ "$DISTRO_PACKAGE_MGR" != "zypper" ]; then
        return 0
    fi

    local translated
    translated=$(translate_package_name_sles "$pkg")

    # Skip dependencies that return empty (bundled with ROCm or not needed)
    if [[ -z "$translated" ]]; then
        print_str "Skipping dependency (bundled or not needed): $pkg" 2
        return 1
    fi

    if [[ "$translated" != "$pkg" ]]; then
        print_str "Translating package name for SLES: $pkg -> $translated" 1
    fi

    PKG_TRANSLATED="$translated"
    return 0
}

# Translate RHEL/EL package names to SLES equivalents
translate_package_name_sles() {
    local pkg="$1"

    # Check cache first
    if [[ -n "${SLES_PKG_CACHE[$pkg]+isset}" ]]; then
        echo "${SLES_PKG_CACHE[$pkg]}"
        return 0
    fi

    # Try capability-based resolution first (if mapping available)
    local translated=""
    if [[ -n "${CAPABILITY_MAP_CACHE[$pkg]+isset}" ]]; then
        local capability="${CAPABILITY_MAP_CACHE[$pkg]}"
        print_str "Found capability for $pkg: $capability" 2

        # Resolve capability to SLES package
        translated=$(resolve_capability_sles "$capability")

        if [[ -n "$translated" ]]; then
            print_str "Resolved via capability: $pkg -> $translated (from $capability)" 1
            SLES_PKG_CACHE[$pkg]="$translated"
            echo "$translated"
            return 0
        else
            print_str "Warning: Could not resolve capability '$capability' for package '$pkg'" 2
            print_str "Falling back to manual mapping..." 2
        fi
    fi

    # Fallback to manual mapping
    case "$pkg" in
        # Packages that are part of base system on SLES
        libxcrypt)
            # Part of base system (glibc) on SLES - no separate package needed
            print_str "Skipping '$pkg': part of base system on SLES" 1
            translated=""
            ;;

        # GCC Runtime Libraries (actively used in required_deps.txt)
        libatomic)
            translated="libatomic1"
            ;;
        libgcc)
            translated="libgcc_s1"
            ;;
        libstdc++)
            translated="libstdc++6"
            ;;
        libgfortran)
            translated="libgfortran5"
            ;;
        libquadmath)
            translated="libquadmath0"
            ;;
        libgomp)
            translated="libgomp1"
            ;;

        # System Libraries (actively used in required_deps.txt)
        zlib)
            translated="libz1"
            ;;
        expat)
            translated="libexpat1"
            ;;

        # ELF utilities (added for ROCm 7.13 profiler)
        elfutils-libelf)
            translated="libelf1"
            ;;
        elfutils-libs)
            translated="libdw1"
            ;;

        # NUMA library
        numactl-libs)
            translated="libnuma1"
            ;;

        # Libtool
        libtool-ltdl)
            translated="libtool"
            ;;

        # OpenCL ICD Loader
        ocl-icd)
            translated="ocl-icd"
            ;;
        ocl-icd-devel)
            translated="ocl-icd-devel"
            ;;

        # Common utilities (same name on both distros)
        glibc|perl|python3|rsync|wget|numactl|pciutils)
            translated="$pkg"
            ;;

        *)
            # For unknown packages, return original name
            # Let is_pkg_installable_rpm() handle validation
            translated="$pkg"
            ;;
    esac

    # Cache and return the result (empty string is valid - means skip)
    SLES_PKG_CACHE[$pkg]="$translated"
    echo "$translated"
    return 0
}

is_pkg_installable_rpm() {
    local dep="$1"
    local install_result=0

    # first check for the dep in the installable package cache
    check_pkg_cache "$dep"
    install_result=$?

    # if not in the installable package cache, check the for dep directly again
    if [[ $install_result -ne 0 ]]; then
        eval "$DISTRO_CACHE_CHK $dep $NO_CMD_OUTPUT"
        install_result=$?
    fi

    # if the dep is a virtual package/capability - check for the providing package
    if [[ $install_result -ne 0 ]]; then
        if [[ -n $DISTRO_VIRTUAL_CHK ]]; then
            print_str "Base package not found.  Checking for providing package via capability."
            print_str "$DISTRO_VIRTUAL_CHK: $dep" 1

            # Use distro-specific function to extract the providing package name
            if [ $DISTRO_PACKAGE_MGR == "dnf" ]; then
                get_package_from_provides_dnf "$dep"
                install_result=$?
            else
                get_package_from_provides_zypper "$dep"
                install_result=$?
            fi
        fi
    fi

    # get the version of the installable package
    if [[ $install_result -eq 0 ]]; then
        if [ $DISTRO_PACKAGE_MGR == "dnf" ]; then
            if [[ -n $VIRTUAL_PACKAGE ]]; then
                INSTALL_VER=$(dnf info "$VIRTUAL_PACKAGE" 2>/dev/null | grep -m1 "^Version" | awk '{print $3}')
            else
                INSTALL_VER=$DEPS_INST_VER
            fi
        else
            if [[ -n $VIRTUAL_PACKAGE ]]; then
                INSTALL_VER=$(zypper info "$VIRTUAL_PACKAGE" 2>/dev/null | grep -m1 "^Version" | awk '{print $3}')
            else
                INSTALL_VER=$(zypper info "$dep" 2>/dev/null | grep -m1 "^Version" | awk '{print $3}')
            fi
        fi
    fi

    return $install_result
}

is_pkg_installable() {
    local dep="$1"
    local install_result=0

    if [ $DISTRO_PACKAGE_MGR == "apt" ]; then
        is_pkg_installable_deb "$dep"
    else
        is_pkg_installable_rpm "$dep"
    fi

    install_result=$?

    return $install_result
}

is_pkg_deb_installed() {
    local dep="$1"
    local install_result=0

    print_str "is_pkg_deb_installed: dep = $dep" 4

    local status
    status=$(dpkg-query -W -f'${Package}:${Architecture} ${Status}\n' "$dep" 2>/dev/null | grep -E ':amd64|:all' | awk '{print $4}')
    if [[ $status != "installed" ]]; then

        # if the package is not installed, check if it's installed via a virtual package
        dpkg-query -W -f='${Package} ${Provides}\n' '*' | grep "$dep" | grep -v "^$dep " > /dev/null 2>&1
        install_result=$?

        if [[ $install_result -eq 0 ]]; then
           echo "Virtual packages may be installed for $dep."

           check_virtual_package_deb "$dep"
           install_result=$?
        fi

    fi

    return $install_result
}

is_pkg_rpm_installed() {
    local dep="$1"
    local install_result=0

    print_str "is_pkg_rpm_installed : dep = $dep" 4

    # All RPM-based systems: use rpm --whatprovides for checking
    # This works reliably across RHEL, Rocky, AlmaLinux, and SLES
    local rpm_output
    rpm_output=$(rpm -q --whatprovides "$dep" 2>&1)

    local rpm_result=$?

    # Check if the output indicates "no package provides"
    # On SLES, rpm can return exit code 0 even when no package provides the capability
    if echo "$rpm_output" | grep -qi "no package provides"; then
        print_str "rpm --whatprovides: no package provides $dep" 4
        install_result=1
    elif [[ $rpm_result -eq 0 ]] && [[ -n "$rpm_output" ]]; then
        print_str "Package found via rpm --whatprovides: $rpm_output" 2
        install_result=0
    else
        print_str "rpm --whatprovides failed or returned empty" 4
        install_result=1
    fi

    # If not found via whatprovides, try direct package name
    if [[ $install_result -ne 0 ]]; then
        print_str "Trying direct package name: rpm -q $dep" 4
        rpm -q "$dep" > /dev/null 2>&1
        install_result=$?

        if [[ $install_result -eq 0 ]]; then
            print_str "Package found via direct name" 2
        else
            # On SLES, try common naming variations for known libraries
            if [[ "$DISTRO_NAME" == "sles" ]]; then
                # Try appending '1' for library packages (libatomic -> libatomic1)
                if [[ "$dep" =~ ^lib ]]; then
                    local variant="${dep}1"
                    print_str "Trying SLES common variation: $variant" 4
                    rpm -q "$variant" > /dev/null 2>&1
                    install_result=$?

                    if [[ $install_result -eq 0 ]]; then
                        print_str "Package found via variation: $variant" 2
                    fi
                fi
            fi
        fi
    fi

    return $install_result
}

check_dep_installable() {
    echo --------------------------------------------------------------
    local testdep="$1"

    local installable=""
    local dep=""
    local dep_version=""
    local result=1

    # remove any leading space
    # shellcheck disable=SC2001
    testdep=$(echo "$testdep" | sed 's/^ *//')
    echo -e "($INSTALL_DEPS_COUNT/$MISSING_DEPS_COUNT): Checking for available packages:\e[36m $testdep\e[0m"

    # check if the package is available for install using local cache
    if [[ -n $testdep ]]; then

        # check for a multi-option dependency
        if echo "$testdep" | grep -q '|'; then
            print_str "Processing multi-option dep..."

            # build the list of packages removing all spaces and replacing "|" with spaces
            deplist=$(echo "$testdep" | tr -d ' ' | tr '|' ' ')

            for pkg in $deplist; do
                print_str "+++++++++++++++++++++"
                print_str "Checking: $pkg"

                VIRTUAL_PACKAGE=""

                # remove versioning
                if [ $PACKAGE_TYPE == "deb" ]; then
                    dep=$(echo "$pkg" | sed -E 's/\([><!=]*[0-9.]*\)//g')
                    dep_version=$(echo "$pkg" | grep -oE '[0-9.]+')
                else
                    dep=$(echo "$pkg" | sed -E 's/[><=!]=?[0-9.]+//g')
                    dep_version=$(echo "$pkg" | grep -oE '[0-9.]+')
                fi
                print_str "Name/Ver: $dep | $dep_version"

                is_pkg_installable "$dep"
                result=$?

                if [[ $result -eq 0 ]]; then
                    echo -e "\e[32m$pkg installable : $INSTALL_VER\e[0m"
                    installable="$dep"
                    break;    # may want to select an amd package if available over any other
                else
                    echo "$pkg" cannot be installed.
                fi
            done

        else
            VIRTUAL_PACKAGE=""

            # single dependency check
            dep=$(echo "$testdep" | awk '{print $1}')

            is_pkg_installable "$dep"
            result=$?

            if [[ $result -eq 0 ]]; then
                echo -e "\e[32m$dep installable : $INSTALL_VER\e[0m"
                installable="$dep"
            else
                echo "$pkg" cannot be installed.
            fi
        fi

        # if any dependency is not installable, fail since the package will not be resolved
        if [[ $result -ne 0 ]]; then
            print_err "Dependency list cannot be installed."
            cleanup
            exit 1
        fi

        # check if a dep can be install via the virtual package/providing package
        if [[ -z $VIRTUAL_PACKAGE ]]; then
            INSTALL_LIST+="$installable "
        else
            echo Capability is provided by package: "$VIRTUAL_PACKAGE". Adding.
            INSTALL_LIST+="$VIRTUAL_PACKAGE "
        fi
    else
        echo empty dep
    fi
}

compare_versions_deb() {
    local version1=$1
    local version2=$2

    if dpkg --compare-versions "$version1" eq "$version2"; then
        return 0  # Equal
    elif dpkg --compare-versions "$version1" gt "$version2"; then
        return 1  # Greater
    else
        return 2  # Less
    fi
}

compare_versions_rpm() {
    local version1=$1
    local version2=$2

    # Split the versions into arrays
    IFS='.' read -r -a ver1 <<< "$version1"
    IFS='.' read -r -a ver2 <<< "$version2"

    # Compare each part of the version numbers
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            # If ver2 is shorter and all previous parts are equal, ver1 is greater
            return 1
        elif ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1  # Greater
        elif ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2  # Less
        fi
    done

    # If ver1 is shorter and all previous parts are equal, ver1 is less
    if [[ ${#ver1[@]} -lt ${#ver2[@]} ]]; then
        return 2
    fi

    return 0  # Equal
}

check_dep_version_installed() {
    local dep="$1"
    local dep_status=1

    print_str "check_dep_version_installed: dep = $dep" 0

    if echo "$dep" | grep -q ' (>= [0-9]\+\.[0-9]\+\.[0-9]\+' || \
       echo "$dep" | grep -q ' (>= [0-9]\+\.[0-9]\+' || \
       echo "$dep" | grep -q ' (>= [0-9]\+' || \
       echo "$dep" | grep -q '>= [0-9]\+\.[0-9]\+\.[0-9]\+' || \
       echo "$dep" | grep -q '>= [0-9]\+\.[0-9]\+' || \
       echo "$dep" | grep -q '>= [0-9]\+'; then

        # check if the version dep installed
        dep_name=$(echo "$dep" | awk '{print $1}')
        dep_ver=$(echo "$dep" | awk '{print $3}' | sed 's/)//')

        # first query if the dep is installed
        if [ $PACKAGE_TYPE == "deb" ]; then
            is_pkg_deb_installed "$dep_name"
        else
            # check what package provides the dep on the system
            is_pkg_rpm_installed "$dep_name"
        fi
        dep_status=$?

        if [ $dep_status -eq 0 ]; then
            # the dep is currently installed, get the version
            if [ $PACKAGE_TYPE == "deb" ]; then
                current_version=$(dpkg-query -W "$dep_name" | head -1 | awk '{print $2}' | cut -d '-' -f 1 | sed 's/[.+][^.+]*$//')
            else
                current_version=$(rpm -q --queryformat '%{VERSION}' "$dep_name")
            fi
            dep_status=$?

            # check for an error on rpm -q : an error may be due a virtual package
            if [[ $dep_status -ne 0 ]] && [[ $PACKAGE_TYPE == "rpm" ]]; then
                dep_name_v=$(rpm -q --whatprovides "$dep_name")
                echo "$dep_name -> $dep_name_v <v>"

                # update the name to the virtual name and get the version
                dep_name=$(echo "$dep_name_v" | awk '{print $1}')
                current_version=$(rpm -q --queryformat '%{VERSION}' "$dep_name")
                dep_status=$?
            fi

            print_str "$dep_name is currently installed : version = $current_version" 2
            print_str "dep_name        = $dep_name" 1
            print_str "dep_status      = $dep_status" 1
            print_str "dep version     = $dep_ver " 1
            print_str "current version = $current_version " 1

            # Compare the current version with the required version
            if [ $PACKAGE_TYPE == "deb" ]; then
                compare_versions_deb  "$current_version" "$dep_ver"
            else
                compare_versions_rpm "$current_version" "$dep_ver"
            fi
            comparison_result=$?

            if [[ $comparison_result -eq 0 ]]; then
                print_str "    current_version $current_version is equal"
            elif [[ $comparison_result -eq 1 ]]; then
                print_str "    current_version $current_version is greater"
            else
                 echo -e "\e[31m$dep_name current_version $current_version is less\e[0m"
                dep_status=1
            fi
        else
            print_str "$dep is not installed" 3
        fi

    else
        # check if non-version dep installed
        if [[ -n $dep ]]; then
            if [ $PACKAGE_TYPE == "deb" ]; then
                is_pkg_deb_installed "$dep"
            else
                is_pkg_rpm_installed "$dep"
            fi
            dep_status=$?

            if [ $dep_status -eq 0 ]; then
                print_str "$dep is installed" 2
            else
                print_str "$dep is not installed" 3
            fi
        fi
    fi

    return $dep_status
}

check_installed_kernel_packages() {
    echo "------------------------------------"
    echo Checking Kernel Packages...

    for pkg in $KERNEL_PACKAGES; do
        if [[ -n "$pkg" ]]; then
            check_dep_version_installed "$pkg"
            status=$?

            if [ $status -eq 0 ]; then
                echo -e "$pkg : \e[32mINSTALLED\e[0m"
            else
                if [[ "$MISSING_DEPS" != *"$pkg"* ]]; then
                    echo -e "$pkg : \e[31mNOT INSTALLED\e[0m"
                    MISSING_DEPS+="$pkg, "
                    MISSING_DEPS_COUNT=$((MISSING_DEPS_COUNT+1))
                fi
            fi
            DEPS_COUNT=$((DEPS_COUNT+1))
        fi
    done

    echo Checking Kernel Packages...Complete.
}

check_installed_graphics_packages() {
    local graphics_deps_file="$1"

    echo "------------------------------------"
    echo Checking Graphics Packages...

    while IFS= read -r pkg; do
        if [[ -n "$pkg" ]]; then
            check_dep_version_installed "$pkg"
            status=$?

            if [ $status -eq 0 ]; then
                echo -e "$pkg : \e[32mINSTALLED\e[0m"
            else
                if [[ "$MISSING_DEPS" != *"$pkg"* ]]; then
                    echo -e "$pkg : \e[31mNOT INSTALLED\e[0m"
                    MISSING_DEPS+="$pkg, "
                    MISSING_DEPS_COUNT=$((MISSING_DEPS_COUNT+1))
                fi
            fi
            DEPS_COUNT=$((DEPS_COUNT+1))
        fi
    done < "$graphics_deps_file"

    echo Checking Graphics Packages...Complete.
}

check_installed_dep_packages() {
    # Check if each package dep in dependency file is installed on the system
    while IFS= read -r pkg; do
        # Skip ocl-icd packages for Alibaba Cloud Linux 4 (not available in repos)
        if [[ "$DISTRO_NAME" = "alinux" && "$DISTRO_MAJOR_VER" = "4" ]]; then
            if [[ "$pkg" =~ ^ocl-icd ]]; then
                print_str "Skipping $pkg for Alibaba Cloud Linux 4 (not available in repos)" 1
                continue
            fi
        fi

        # Apply SLES translation if needed
        if ! apply_sles_translation "$pkg"; then
            continue
        fi
        pkg="$PKG_TRANSLATED"

        print_str "+++++++++++++++++++++++++++++++++++++++++++++++++++++++"
        print_str "$pkg : ..." 1

        DEPS_COUNT=$((DEPS_COUNT+1))
        DEPS+="$pkg "

        if [[ "$pkg" == *'|'* ]]; then
            status=1
            IFS='|' read -ra deps <<< "$pkg"
            for dep in "${deps[@]}"; do
                dep_trimmed=$(echo "$dep" | sed 's/^ *//;s/ *$//')
                if check_dep_version_installed "$dep_trimmed"; then
                    status=0
                    break
                fi
            done

        else
            # check a single dep
            check_dep_version_installed "$pkg"
            status=$?
        fi

        # Check the dep install status and add any missing deps not installed on the system to the "missing" list
        if [ $status -eq 0 ]; then
            echo -e "$pkg : \e[32mINSTALLED\e[0m"
        else
            echo -e "$pkg : \e[31mNOT INSTALLED\e[0m"
            MISSING_DEPS+="$pkg, "
            MISSING_DEPS_COUNT=$((MISSING_DEPS_COUNT+1))
        fi
    done < "$DEPS_FILE"
}

remove_deps_duplicates() {
    echo Removing duplicate deps...

    if [[ -n $FILTER_PACKAGES ]]; then
        for dep in $FILTER_PACKAGES; do
            # Remove any dependency in MISSING_DEPS that matches
            if [[ "$MISSING_DEPS" == *"$dep"* ]]; then
                echo Removing: "$dep"
                MISSING_DEPS=$(echo "$MISSING_DEPS" | sed -E "s/(^|, )$dep(, |$)/\1/g")
                MISSING_DEPS_COUNT=$((MISSING_DEPS_COUNT-1))
                DEPS_COUNT=$((DEPS_COUNT-1))
            fi
        done
    fi

    echo Removing duplicate deps...Complete.
}

remove_deps() {
    echo Removing deps...

    if [[ -n $REMOVE_PACKAGES ]]; then
        for dep in $REMOVE_PACKAGES; do
            # Remove any dependency in MISSING_DEPS that contains the match
            if [[ "$MISSING_DEPS" == *"$dep"* ]]; then
                echo Removing: "$dep"
                MISSING_DEPS=$(echo "$MISSING_DEPS" | tr ',' '\n' | grep -v "$dep" | tr '\n' ',' | sed 's/,$//')
                MISSING_DEPS_COUNT=$((MISSING_DEPS_COUNT-1))
                DEPS_COUNT=$((DEPS_COUNT-1))
            fi
        done
    fi

    echo Removing deps...Complete.
}

install_rocky_kernel_packages() {
    echo Downloading Rocky kernel packages...

    # Set base url to rocky vault/kickstart repo and attempt to download the kernel packages
    local base_url="$1"

    # Set the kernel packages to download
    local packages=(
        "$base_url/Packages/k/kernel-headers-$KERNEL_VER.rpm"
        "$base_url/Packages/k/kernel-devel-$KERNEL_VER.rpm"
        "$base_url/Packages/k/kernel-devel-matched-$KERNEL_VER.rpm"
    )

    local failed=0
    local package_name=
    local package_list=

    echo --------------------------
    echo "URL: $base_url"
    echo --------------------------

    # Loop through the list of packages and attempt to download each

    for package in "${packages[@]}"; do
        package_name=$(basename "${package}")
        echo "Downloading: $package_name"
        if ! wget -q "$package" -O "$package_name"; then
            echo -e "\e[31mFailed to download kernel package: $package\e[0m"
            failed=1
            break
        fi
    done

    # If any download failed, return failure
    if [[ $failed -eq 1 ]]; then
        echo -e "\e[31mOne or more kernel packages failed to download. Exiting.\e[0m"
        return 1
    fi

    # Loop through the downloaded packages and install them
    echo "Installing downloaded packages..."

    for package in "${packages[@]}"; do
        package_list+="./$(basename "${package}") "
    done

    echo "Installing: $package_list"

    if ! $SUDO dnf install -y $package_list; then
        echo -e "\e[31mFailed to install kernel packages: $package_list\e[0m"
        $SUDO rm $package_list
        return 1
    fi

    # Clean up any downloaded packages
    $SUDO rm $package_list

    echo Downloading Rocky kernel packages...Complete.
    return 0
}

add_rocky_repo() {
    local rocky_repo_url="$1"
    local rocky_repo_name="$2"
    local rocky_repo_desc="$3"

    echo "Adding URL: $rocky_repo_url"

     # Check if the repo is accessible
    if wget --spider "$rocky_repo_url/repodata" > /dev/null 2>&1; then
        echo -e "\e[32mRepo $rocky_repo_desc accessible\e[0m"
cat <<EOF | $SUDO tee -a /etc/yum.repos.d/appstream-amdgpu.repo
[$rocky_repo_name]
name=Rocky Linux $DISTRO_VER - $rocky_repo_desc
baseurl=$rocky_repo_url
gpgcheck=1
enabled=1
countme=1
metadata_expire=6h
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-$DISTRO_MAJOR_VER
EOF
    else
        echo -e "\e[31mRepo $rocky_repo_desc not accessible\e[0m"
        return 1
    fi

    # Cleanup the dnf caches
    $SUDO dnf clean all
    $SUDO rm -rf /var/cache/dnf/*
    $SUDO dnf makecache

    return 0
}

get_kernel_packages_repo_rocky() {
    local package="kernel-headers-$KERNEL_VER.rpm"

    # Repo URL list for kernel packages
    local base_urls=(
        "https://dl.rockylinux.org/pub/rocky/$DISTRO_VER/AppStream/x86_64/kickstart"
        "https://dl.rockylinux.org/vault/rocky/$DISTRO_VER/AppStream/x86_64/kickstart"
        "https://dl.rockylinux.org/vault/rocky/$DISTRO_VER/AppStream/x86_64/os"
    )

    local pkg_avail=0

    # Check each repo for the required kernel packages
    for url in "${base_urls[@]}"; do
        if wget --spider "$url/Packages/k/$package" > /dev/null 2>&1; then
            echo -e "Packages in $url : \e[32mAvailable.\e[0m"
            pkg_avail=1
            break
        else
            echo -e "Packages in $url : \e[93mNot Available.\e[0m"
        fi
    done

    if [[ $pkg_avail == 0 ]]; then
        print_err "Kernel packages not found in repos."
        return 1
    fi

    local dir_subtype=appstream
    local dir_type=
    local dir_package=

    if [[ $url =~ "vault" ]]; then
        dir_type=vault
    elif [[ $url =~ "pub" ]]; then
        dir_type=pub
    fi

    if [[ $url =~ "x86_64/kickstart" ]]; then
        dir_package=kickstart
    elif [[ $url =~ "x86_64/os" ]]; then
        dir_package=os
    fi

    # Attempt to add the repo for the kernel packages
    if add_rocky_repo "$url" "$dir_subtype-$dir_type-$dir_package" "$dir_subtype $dir_type $dir_package"; then
        KERNEL_PACKAGES_VER="-$KERNEL_VER"
    else
        echo "Repo not available. Downloading package."

        # The repo may not be accessible, so manually download and install from the repo
        if ! install_rocky_kernel_packages "$url"; then
            print_err "Unable to download and install kernel packages."
            return 1
        fi
    fi

    return 0
}

get_kernel_packages_rocky() {
    echo Rocky kernel packages...

    remove_rocky_kernel_repo

    if dnf repoquery --available --queryformat "%{name}-%{version}-%{release}.%{arch}" | grep "kernel-headers-$(uname -r)"; then
        echo "Kernel Packages for $KERNEL_VER are available in the AppStream repositories."
        KERNEL_PACKAGES_VER="-$KERNEL_VER"
    else
        echo -e "\e[93mKernel Packages not available in the AppStream repositories.\e[0m"

        # check for legacy kernel headers
    	if ! get_kernel_packages_repo_rocky; then
    	    echo -e "\e[93mKernel Packages not available in the repositories.  Using defaults.\e[0m"
    	fi
    fi

    echo Rocky kernel packages...Complete.
}

get_kernel_packages_tencentos() {
    echo TencentOS kernel packages...

    # TencentOS appends .tl3 or .tl4 suffix to kernel package names
    local tl_suffix=".tl${DISTRO_MAJOR_VER}"
    local kernel_with_suffix="${KERNEL_VER}${tl_suffix}"

    if dnf list "kernel-headers-$kernel_with_suffix" &> /dev/null; then
        echo "Kernel Packages for $kernel_with_suffix are available in the repositories."
        KERNEL_PACKAGES_VER="-$kernel_with_suffix"
    else
        echo -e "\e[93mKernel Packages not available in the repositories.  Using defaults.\e[0m"
        KERNEL_PACKAGES_VER="-$kernel_with_suffix"
    fi

    echo TencentOS kernel packages...Complete.
}

get_kernel_packages_alinux() {
    echo Alibaba Cloud Linux kernel packages...

    # Alibaba Cloud Linux appends .al3 or .al4 suffix to kernel package names
    local al_suffix=".al${DISTRO_MAJOR_VER}"
    local kernel_with_suffix="${KERNEL_VER}${al_suffix}"

    if dnf list "kernel-headers-$kernel_with_suffix" &> /dev/null; then
        echo "Kernel Packages for $kernel_with_suffix are available in the repositories."
        KERNEL_PACKAGES_VER="-$kernel_with_suffix"
    else
        echo -e "\e[93mKernel Packages not available in the repositories.  Using defaults.\e[0m"
        KERNEL_PACKAGES_VER="-$kernel_with_suffix"
    fi

    echo Alibaba Cloud Linux kernel packages...Complete.
}

get_kernel_packages_el() {
    echo EL kernel packages...

    if [[ $DEPS_LIST_ONLY == 0 ]]; then
        if dnf list "kernel-headers-$KERNEL_VER" &> /dev/null; then
            echo "Kernel Packages for $KERNEL_VER are available in the repositories."
            KERNEL_PACKAGES_VER="-$KERNEL_VER"
        else
            if [[ "$DISTRO_NAME" = "rocky" ]]; then
                get_kernel_packages_rocky
            elif [[ "$DISTRO_NAME" = "tencentos" ]]; then
                get_kernel_packages_tencentos
            elif [[ "$DISTRO_NAME" = "alinux" ]]; then
                get_kernel_packages_alinux
            else
                echo -e "\e[93mKernel Packages not available in the repositories.  Using defaults.\e[0m"
                KERNEL_PACKAGES_VER="-$KERNEL_VER"
            fi
        fi
    else
        KERNEL_PACKAGES_VER="-$KERNEL_VER"
    fi

    KERNEL_PACKAGES="kernel-headers$KERNEL_PACKAGES_VER kernel-devel$KERNEL_PACKAGES_VER "

    if [[ $DISTRO_VER == 9* ]]; then
        echo Adding EL9 amdgpu packages
        KERNEL_PACKAGES+="kernel-devel-matched$KERNEL_PACKAGES_VER "
    elif [[ $DISTRO_VER == 10* ]]; then
        echo Adding EL10 amdgpu packages
        KERNEL_PACKAGES+="kernel-devel-matched$KERNEL_PACKAGES_VER "
    fi

    FILTER_PACKAGES="kernel-devel"
    REMOVE_PACKAGES="kernel-headers"
}

get_kernel_type_ol() {
    local kernel_version
    kernel_version=$(uname -r)

    if [[ $kernel_version == *"uek"* ]]; then
        echo "UEK"
    elif [[ $kernel_version == *"el8"* || $kernel_version == *"el9"* || $kernel_version == *"el10"* ]]; then
        echo "RHCK"
    else
        echo "UNKNOWN"
    fi
}

get_kernel_packages_ol() {
    echo OL kernel packages...

    kernel_type=$(get_kernel_type_ol)
    echo "Current kernel type: $kernel_type"

    if [[ $kernel_type == "UEK" ]]; then

        # check for the uek kernel packages
        if dnf list "kernel-uek-devel-$KERNEL_VER" &> /dev/null; then
            echo "Kernel Packages for UEK $KERNEL_VER are available in the repositories."
            KERNEL_PACKAGES+="kernel-uek-devel-$KERNEL_VER "
        else
            echo -e "\e[93mKernel Packages for UEK not available in the repositories.  Using defaults.\e[0m"
        fi
    elif [[ $kernel_type == "RHCK" ]]; then
        # check for the rhck kernel packages
        if dnf list "kernel-headers-$KERNEL_VER" &> /dev/null; then
            echo "Kernel Packages for RHCK $KERNEL_VER are available in the repositories."
            KERNEL_PACKAGES+="kernel-headers-$KERNEL_VER kernel-devel-$KERNEL_VER "
            if [[ $DISTRO_VER == 9* ]]; then
                echo Adding EL9 amdgpu packages
                KERNEL_PACKAGES+="kernel-devel-matched-$KERNEL_VER "
            elif [[ $DISTRO_VER == 10* ]]; then
                echo Adding EL10 amdgpu packages
                KERNEL_PACKAGES+="kernel-devel-matched-$KERNEL_VER "
            fi
        else
            echo -e "\e[93mKernel Packages for RHCK not available in the repositories.  Using defaults.\e[0m"
        fi
    else
            echo -e "\e[93mUnknown kernel type. Using defaults.\e[0m"
            KERNEL_PACKAGES+="kernel-uek-devel-$KERNEL_VER "
    fi

    FILTER_PACKAGES="kernel-devel"
    REMOVE_PACKAGES="kernel-headers"

    if [ -f "/boot/config-$(uname -r)" ]; then
        echo "Find the value of TARGET_GCC_VERSION using CONFIG_CC_VERSION_TEXT from /boot/config-$(uname -r)"
        TARGET_GCC_VERSION=$($SUDO cat "/boot/config-$(uname -r)" | grep CONFIG_CC_VERSION_TEXT | cut -d '=' -f2 | awk -F " " '{print $NF}' | tr -d ')' | tr -d '"')
        for gcc_package in "${GCC_TOOLSET_PACKAGES_OL[@]}"; do
            # Expect full package name we want to install
            # Example: gcc-toolset-11-gcc-11.4.1-3.0.1.el8_6
            if [[ $DISTRO_VER == 8* ]]; then
                gcc_package_ver=$(sudo dnf --disablerepo="*" --enablerepo="ol8_appstream" repoquery --all --nvr | grep "$gcc_package-$TARGET_GCC_VERSION" | awk '{print $NF}' | sort | uniq | tail -1)
            elif [[ $DISTRO_VER == 9* ]]; then
                gcc_package_ver=$(sudo dnf --disablerepo="*" --enablerepo="ol9_appstream" repoquery --all --nvr | grep "$gcc_package-$TARGET_GCC_VERSION" | awk '{print $NF}' | sort | uniq | tail -1)
            elif [[ $DISTRO_VER == 10* ]]; then
                gcc_package_ver=$(sudo dnf --disablerepo="*" --enablerepo="ol10_appstream" repoquery --all --nvr | grep "$gcc_package-$TARGET_GCC_VERSION" | awk '{print $NF}' | sort | uniq | tail -1)
            fi

            if [ -n "$gcc_package_ver" ]; then
                echo "Install $gcc_package version $gcc_package_ver"
                KERNEL_PACKAGES+="$gcc_package_ver "
            else
                echo "Unable to gcc version $TARGET_GCC_VERSION for package $gcc_package in repo ol${DISTRO_VER_MAJ}_appstream"
            fi
        done
    fi
}

get_kernel_packages_amzn() {
    echo Amazon kernel packages...

    # Extract version major.minor version (x.y)
    KERNEL_MAJ_MIN=$(echo "$KERNEL_VER" | cut -d'.' -f1,2)

    # Extract version up to .x86_64
    KERNEL_VER_AMZN="${KERNEL_VER%.x86_64}"

    echo "KERNEL_MAJ_MIN : $KERNEL_MAJ_MIN"
    echo "KERNEL_VER_AMZN: $KERNEL_VER_AMZN"

    if [[ $DEPS_LIST_ONLY == 0 ]]; then
        # Check if base kernel package is available (without specific version)
        # Amazon Linux 2023 uses package names like: kernel6.1-headers, kernel6.1-devel
        echo "Checking for kernel$KERNEL_MAJ_MIN-headers package..."
        if dnf list "kernel$KERNEL_MAJ_MIN-headers" &>/dev/null; then
            echo "Found versioned package: kernel$KERNEL_MAJ_MIN-headers"
            # Use versioned packages
            KERNEL_PACKAGES="kernel$KERNEL_MAJ_MIN-headers kernel$KERNEL_MAJ_MIN-devel "
        else
            # Try without version prefix (Amazon Linux 2023 uses generic kernel-headers)
            echo "kernel$KERNEL_MAJ_MIN-headers not found, checking for generic kernel-headers..."

            # Query the available or installed kernel-headers version
            local available_version
            available_version=$(dnf list kernel-headers 2>/dev/null | grep "^kernel-headers" | awk '{print $2}' | sed 's/^[0-9]*://')

            if [[ -z "$available_version" ]]; then
                print_err "Kernel Packages not available in the repositories."
                echo "Searched for: kernel$KERNEL_MAJ_MIN-headers and kernel-headers"
                exit 1
            fi

            echo "Found generic kernel-headers package version: $available_version"

            # Verify the available version matches the running kernel
            if [[ "$available_version" == "$KERNEL_VER_AMZN" ]]; then
                echo "✓ Kernel headers version matches running kernel: $KERNEL_VER_AMZN"
                # Use generic packages with specific version
                KERNEL_PACKAGES="kernel-headers-$KERNEL_VER_AMZN kernel-devel-$KERNEL_VER_AMZN "
            else
                print_err "Kernel headers version mismatch!"
                echo "  Running kernel: $KERNEL_VER_AMZN"
                echo "  Available headers: $available_version"
                echo ""
                echo "The available kernel-headers package does not match your running kernel."
                echo "This may cause AMDGPU DKMS build failures."
                echo ""
                echo "Options:"
                echo "  1. Update your system and reboot to kernel $available_version"
                echo "  2. Install matching kernel-headers manually"
                echo "  3. Continue anyway (may fail during DKMS build)"
                read -p "Continue anyway? [y/N]: " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    exit 1
                fi
                # Use generic packages (dnf will install best available)
                KERNEL_PACKAGES="kernel-headers kernel-devel "
            fi
        fi
    else
        # List-only mode: use generic package names
        if dnf list "kernel$KERNEL_MAJ_MIN-headers" &>/dev/null; then
            KERNEL_PACKAGES="kernel$KERNEL_MAJ_MIN-headers kernel$KERNEL_MAJ_MIN-devel "
        else
            KERNEL_PACKAGES="kernel-headers kernel-devel "
        fi
    fi

    FILTER_PACKAGES="kernel-devel"
    REMOVE_PACKAGES="kernel-headers"
}

get_kernel_package_for_kernel_version() {
    print_str "--------------------------------"
    print_str "Find kernel package $1 for kernel version $KERNEL_PACKAGE_VER..."

    kernel_package="$1"

    local output
    output=$($SUDO zypper search -s "$kernel_package" | grep "$KERNEL_PACKAGE_VER")

    for col_value in ${output}; do
        if grep -q "$KERNEL_PACKAGE_VER" <<< "$col_value"; then
            NEW_KERNEL_PACKAGE_VER="$col_value"
            echo "Using $NEW_KERNEL_PACKAGE_VER for $kernel_package"
            KERNEL_PACKAGES+="$kernel_package-$NEW_KERNEL_PACKAGE_VER "
            break;
        fi
    done
}

get_kernel_packages_debian() {
    echo Debian kernel packages...

    local kernel_ver_sans_arch

    kernel_ver_sans_arch="${KERNEL_VER/-amd64}"

    # Associative array mapping package names to their expected architecture
    # Example deb 12: linux-headers-6.1.0-29-amd64, linux-headers-6.1.0-29-common
    # Example deb 13: linux-headers-6.12.38+deb13-amd64, linux-headers-6.12.38+deb13-common
    declare -A linux_headers_to_download=(
        ["linux-headers-$KERNEL_VER"]="amd64"
        ["linux-headers-$kernel_ver_sans_arch-common"]="all"
    )

    if [[ $DISTRO_MAJOR_VER -eq 13 ]]; then
        # Example deb13: linux-kbuild-6.12.38+deb13
        linux_headers_to_download["linux-kbuild-$kernel_ver_sans_arch"]="amd64"
    fi

    # Clear any previous info
    DEBIAN_KERNEL_PKG_INFO=()

    for package in "${!linux_headers_to_download[@]}"; do
        local expected_arch="${linux_headers_to_download[$package]}"
        # Example URL: https://snapshot.debian.org/mr/binary/linux-headers-6.1.0-29-common/

        if linux_headers_info=$(wget --quiet --tries $WGET_RETRY_COUNT -qO- "https://snapshot.debian.org/mr/binary/$package"); then
            linux_headers_binary_version=$(jq -r '.result[0].binary_version' <<< "$linux_headers_info")

            # Example URL: https://snapshot.debian.org/mr/binary/linux-headers-6.1.0-29-amd64/6.1.123-1/binfiles

            if linux_headers_file_info=$(wget --quiet --tries $WGET_RETRY_COUNT -qO- "https://snapshot.debian.org/mr/binary/$package/$linux_headers_binary_version/binfiles"); then
                # Find the hash for the expected architecture
                linux_headers_hash_value=$(jq -r --arg arch "$expected_arch" '.result[] | select(.architecture == $arch) | .hash' <<< "$linux_headers_file_info")

                # If expected architecture not found, skip this package
                if [[ -z "$linux_headers_hash_value" ]]; then
                    echo -e "${YELLOW}Architecture $expected_arch not found for $package, skipping${NC}"
                    continue
                fi

                # Build and store the full download URL
                local deb_filename="${package}_${linux_headers_binary_version}_${expected_arch}.deb"
                DEBIAN_KERNEL_PKG_INFO["$package"]="https://snapshot.debian.org/file/${linux_headers_hash_value}/${deb_filename}"
                echo "Found $package on snapshot.debian.org"
            else
                echo -e "${YELLOW}Failed to download metadata on kernel package $package from https://snapshot.debian.org ${NC}"
                return 1
            fi
        else
            echo -e "${YELLOW}Failed to find kernel package $package on https://snapshot.debian.org ${NC}"
            return 1
        fi
    done

    if [[ ${#DEBIAN_KERNEL_PKG_INFO[@]} -gt 0 ]]; then
        for pkg in "${!DEBIAN_KERNEL_PKG_INFO[@]}"; do
            KERNEL_PACKAGES+="$pkg "
        done
    fi

    echo "Debian kernel packages discovery...Complete."
    return 0
}

# Download and install Debian kernel packages from snapshot.debian.org
# Called from install_dependencies() - uses info stored in DEBIAN_KERNEL_PKG_INFO
install_kernel_packages_debian() {
    print_str "--------------------------------"
    print_str "Installing Debian kernel packages from snapshot.debian.org..."

    local linux_headers_package_list=()

    for package in "${!DEBIAN_KERNEL_PKG_INFO[@]}"; do
        # Only install packages that are in DIRECT_DOWNLOAD_LIST (i.e., missing packages)
        if [[ " $DIRECT_DOWNLOAD_LIST " != *" $package "* ]]; then
            echo "Skipping $package (already installed or not needed)"
            continue
        fi

        local url="${DEBIAN_KERNEL_PKG_INFO[$package]}"
        local filename
        filename=$(basename "$url")

        echo "--------------------------"
        echo "URL: $url"
        echo "--------------------------"

        echo "Downloading: $package"

        if ! wget --quiet --tries $WGET_RETRY_COUNT "$url"; then
            print_err "Failed to download $package from https://snapshot.debian.org"
            exit 1
        else
            linux_headers_package_list+=("$(pwd)/$filename")
        fi
    done

    if [[ ${#linux_headers_package_list[@]} -gt 0 ]]; then
        echo "Installing downloaded packages: ${linux_headers_package_list[*]}"
        if ! $SUDO apt-get install -qq -y "${linux_headers_package_list[@]}"; then
            print_err "Failed to install kernel headers: ${linux_headers_package_list[*]}"
            $SUDO rm -f "${linux_headers_package_list[@]}"
            exit 1
        fi
        echo -e "${GREEN}Successfully installed kernel headers ${linux_headers_package_list[*]}${NC}"

        # Clean up downloaded files
        $SUDO rm -f "${linux_headers_package_list[@]}"
    fi
}

get_kernel_packages() {
    echo "------------------------------------"

    # set the kernel headers
    KERNEL_VER=$(uname -r)
    echo "Kernel: ${KERNEL_VER}"

    echo "Availaible kernels:"
    ls -1 /boot/vmlinuz*

    # set the kernel packages
    if [ $DISTRO_PACKAGE_MGR == "apt" ]; then
        if is_pkg_available_to_download_deb "linux-headers-$KERNEL_VER"; then
            echo "Package linux-headers-$KERNEL_VER available in repository"
            KERNEL_PACKAGES="linux-headers-$KERNEL_VER "
        elif [[ $DISTRO_NAME = "debian" ]]; then
            get_kernel_packages_debian
        fi

    elif [ $DISTRO_PACKAGE_MGR == "dnf" ]; then

        if [[ "$DISTRO_NAME" = "rhel" || "$DISTRO_NAME" = "rocky" || "$DISTRO_NAME" = "anolis" || "$DISTRO_NAME" = "tencentos" || "$DISTRO_NAME" = "alinux" ]]; then
            get_kernel_packages_el
        elif [ "$DISTRO_NAME" = "ol" ]; then
            get_kernel_packages_ol
        elif [ "$DISTRO_NAME" = "amzn" ]; then
            get_kernel_packages_amzn
        else
            get_kernel_packages_el
        fi

    elif [ $DISTRO_PACKAGE_MGR == "zypper" ]; then
        if [[ $DEPS_LIST_ONLY == 0 ]]; then
            KERNEL_PACKAGE_VER="$(uname -r | sed "s/-default//")"
            if $SUDO zypper search -s kernel-default-devel | grep "$KERNEL_PACKAGE_VER" &> /dev/null; then
                echo "Kernel Packages for $KERNEL_PACKAGE_VER are available in the repositories."

                get_kernel_package_for_kernel_version "kernel-default-devel"
                get_kernel_package_for_kernel_version "kernel-syms"
                get_kernel_package_for_kernel_version "kernel-macros"
            else
                echo -e "\e[93mKernel Packages not available in the repositories.  Using defaults.\e[0m"
                KERNEL_PACKAGES="kernel-default-devel"
            fi
        else
            KERNEL_PACKAGES="kernel-default-devel"
        fi

        FILTER_PACKAGES="kernel-devel"

    else
        print_err "Unsupported OS."
        exit 1
    fi

    echo "KERNEL_PACKAGES = $KERNEL_PACKAGES"
}

print_deps() {
    if [ -f deps_list.txt ]; then
        echo Removing old missing dependency list.
        rm deps_list.txt
    fi

    if [[ -n $MISSING_DEPS ]]; then
        echo ==============================================================
        echo "Dependencies: $MISSING_DEPS_COUNT of $DEPS_COUNT packages require install:"
        echo "$MISSING_DEPS" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u
        echo "$MISSING_DEPS" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u > deps_list.txt
    fi
}

read_deps() {
    print_str "--------------------------------"
    print_str "Read Dependency Configuration: $DEPS_FILE ..."

    if [ ! -f "$DEPS_FILE" ]; then
        print_err "$DEPS_FILE does not exist."
        exit 1
    fi

    while IFS= read -r dep; do
        # Skip ocl-icd packages for Alibaba Cloud Linux 4 (not available in repos)
        if [[ "$DISTRO_NAME" = "alinux" && "$DISTRO_MAJOR_VER" = "4" ]]; then
            if [[ "$dep" =~ ^ocl-icd ]]; then
                print_str "Skipping $dep for Alibaba Cloud Linux 4 (not available in repos)" 1
                continue
            fi
        fi

        # Apply SLES translation if needed
        if ! apply_sles_translation "$dep"; then
            continue
        fi
        dep="$PKG_TRANSLATED"
        MISSING_DEPS="$MISSING_DEPS $dep,"
        DEPS_COUNT=$((DEPS_COUNT+1))
    done < "$DEPS_FILE"

    # add any kernel packages to the deps list
    if [[ -n "$KERNEL_PACKAGES" ]]; then
        for dep in $KERNEL_PACKAGES; do
             MISSING_DEPS="$MISSING_DEPS $dep,"
             DEPS_COUNT=$((DEPS_COUNT+1))
        done
    fi

    MISSING_DEPS_COUNT=$DEPS_COUNT

    print_str "Read Dependency Configuration...Complete."
}

setup_graphics_repo() {
    echo "------------------------------------"
    echo "Setting up Graphics repo..."

    # Read graphics version from file created by package extractor
    local graphics_version_file="$PWD/component-rocm${CHROOT_SUFFIX}/deps/graphics/graphics_version.txt"

    if [[ ! -f "$graphics_version_file" ]]; then
        print_err "Graphics version file not found: $graphics_version_file"
        return 1
    fi

    local graphics_version
    graphics_version=$(cat "$graphics_version_file")
    echo "Graphics version: $graphics_version"

    if [[ $PACKAGE_TYPE == "deb" ]]; then
        # Ubuntu setup
        # Supported: Ubuntu 24.04 (noble), Ubuntu 26.04 (resolute)

        # Check for unsupported distros
        if [[ "$DISTRO_NAME" != "ubuntu" ]]; then
            print_err "Graphics support is not available for ${DISTRO_NAME}"
            return 1
        fi

        # Check for unsupported Ubuntu versions
        case "$DISTRO_VER" in
            24.04|26.04)
                # Supported versions
                ;;
            *)
                print_err "Graphics support is not available for Ubuntu ${DISTRO_VER}"
                print_err "Graphics is only supported for Ubuntu 24.04 and 26.04"
                return 1
                ;;
        esac

        # Get codename (noble, jammy, etc.)
        local distro_codename
        distro_codename=$(get_os_codename)

        echo "Installing GPG key..."
        $SUDO mkdir -p --mode=0755 /etc/apt/keyrings
        wget https://repo.radeon.com/rocm/rocm.gpg.key -O - 2>/dev/null | gpg --dearmor | $SUDO tee /etc/apt/keyrings/rocm.gpg > /dev/null

        echo "Creating graphics repository file..."
        $SUDO tee /etc/apt/sources.list.d/amdgpu-graphics.list > /dev/null <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/${graphics_version}/ubuntu ${distro_codename} main
EOF

        echo "Updating package lists..."
        $SUDO apt-get update > /dev/null 2>&1

    elif [[ $PACKAGE_TYPE == "rpm" ]]; then
        # RPM-based setup (RHEL, Rocky, AlmaLinux, SLES, Amazon Linux)
        local distro_type
        local distro_path

        # Check for unsupported distros
        if [[ "$DISTRO_NAME" != "rhel" ]]; then
            print_err "Graphics support is not available for ${DISTRO_NAME}"
            return 1
        fi

        # RHEL-specific version checks
        # Graphics support only for RHEL 9.8 and 10.2
        distro_type="el"
        case "$DISTRO_VER" in
            9.8)
                # RHEL 9.8 supported
                distro_path="${distro_type}/${DISTRO_VER}"
                ;;
            10.2)
                # RHEL 10.2 supported
                distro_path="${distro_type}/${DISTRO_VER}"
                ;;
            *)
                print_err "Graphics support is not available for RHEL ${DISTRO_VER}"
                print_err "Graphics is only supported for RHEL 9.8 and 10.2"
                return 1
                ;;
        esac

        # Setup repo based on package manager (dnf vs zypper)
        if [ "$DISTRO_PACKAGE_MGR" == "dnf" ]; then
            # DNF-based (RHEL, Rocky, Oracle, Amazon Linux) use /etc/yum.repos.d/
            echo "Creating graphics repository file..."
            $SUDO tee /etc/yum.repos.d/amdgpu-graphics.repo > /dev/null <<EOF
[amdgraphics]
name=AMD Graphics ${graphics_version} repository
baseurl=https://repo.radeon.com/graphics/${graphics_version}/${distro_path}/main/x86_64/
enabled=1
priority=50
gpgcheck=1
gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key
EOF

            echo "Cleaning package cache..."
            $SUDO dnf clean all > /dev/null 2>&1
        else
            # SLES uses zypper with repos in /etc/zypp/repos.d/
            echo "Creating graphics repository file..."
            $SUDO tee /etc/zypp/repos.d/amdgpu-graphics.repo > /dev/null <<EOF
[amdgraphics]
name=AMD Graphics ${graphics_version} repository
baseurl=https://repo.radeon.com/graphics/${graphics_version}/${distro_path}/main/x86_64/
enabled=1
priority=50
gpgcheck=1
gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key
type=rpm-md
EOF

            echo "Cleaning package cache..."
            $SUDO zypper --gpg-auto-import-keys refresh > /dev/null 2>&1
        fi
    fi

    echo "Graphics repo setup complete."
    echo "------------------------------------"
}

cleanup_graphics_repo() {
    echo "------------------------------------"
    echo "Cleaning up Graphics repo..."

    if [[ $PACKAGE_TYPE == "deb" ]]; then
        # Remove repo list file
        if [[ -f /etc/apt/sources.list.d/amdgpu-graphics.list ]]; then
            echo "Removing graphics repo list..."
            $SUDO rm /etc/apt/sources.list.d/amdgpu-graphics.list
        fi

        # Note: We don't remove the GPG key as it might be used by other ROCm repos

        echo "Updating package lists..."
        $SUDO apt-get update > /dev/null 2>&1

    elif [[ $PACKAGE_TYPE == "rpm" ]]; then
        # Remove repo file based on package manager
        if [ "$DISTRO_PACKAGE_MGR" == "dnf" ]; then
            # DNF-based (RHEL, Rocky, Oracle, Amazon Linux)
            if [[ -f /etc/yum.repos.d/amdgpu-graphics.repo ]]; then
                echo "Removing graphics repo file..."
                $SUDO rm /etc/yum.repos.d/amdgpu-graphics.repo
            fi

            echo "Cleaning package cache..."
            $SUDO dnf clean all > /dev/null 2>&1
        else
            # SLES uses zypper with repos in /etc/zypp/repos.d/
            if [[ -f /etc/zypp/repos.d/amdgpu-graphics.repo ]]; then
                echo "Removing graphics repo file..."
                $SUDO rm /etc/zypp/repos.d/amdgpu-graphics.repo
            fi

            echo "Cleaning package cache..."
            $SUDO zypper refresh > /dev/null 2>&1
        fi
    fi

    echo "Graphics repo cleanup complete."
    echo "------------------------------------"
}

build_dependencies_list_for_compo() {
    local compo_type=$1
    echo "------------------------------------"
    print_str "Building Dependency List for: $compo_type"

    # Set the dependency file based on component type
    if [[ "$compo_type" == "rocm" ]]; then
        # For ROCm, use the combined dependency file from appropriate component directory
        # Select the appropriate directory and dependency file based on package type
        if [ "$PACKAGE_TYPE" == "rpm" ]; then
            local deps_dir="$PWD/component-rocm"
            DEPS_FILE="$deps_dir/deps/rocm_required_deps_rpm.txt"
        else
            # For DEB packages, check if component-rocm-deb exists (chroot mode)
            # Otherwise fall back to component-rocm (native DEB system)
            if [ -d "$PWD/component-rocm-deb" ]; then
                local deps_dir="$PWD/component-rocm-deb"
            else
                local deps_dir="$PWD/component-rocm"
            fi
            DEPS_FILE="$deps_dir/deps/rocm_required_deps_deb.txt"
        fi

        if [ ! -d "$deps_dir" ]; then
            print_err "ROCm component directory does not exist: $deps_dir"
            exit 1
        fi

        # Load capability mapping for SLES cross-distro resolution
        if [ "$DISTRO_PACKAGE_MGR" == "zypper" ]; then
            load_capability_mapping
        fi

    elif [[ "$compo_type" == "amdgpu" ]]; then
        # For AMDGPU, use the distro-specific dependency file
        local amdgpu_base_dir="$PWD/component-amdgpu"

        if [ ! -d "$amdgpu_base_dir" ]; then
            print_err "component-amdgpu directory does not exist: $amdgpu_base_dir"
            exit 1
        fi

        # Get the distro tag for the current running distro
        if ! AMDGPU_DISTRO_TAG=$(get_amdgpu_distro_tag); then
            print_err "Failed to determine AMDGPU distro tag"
            exit 1
        fi

        print_str "AMDGPU_DISTRO_TAG = $AMDGPU_DISTRO_TAG"

        DEPS_FILE="$amdgpu_base_dir/deps/$AMDGPU_DISTRO_TAG/required_deps.txt"

    else
        print_err "Unknown component type: $compo_type"
        exit 1
    fi

    print_str "DEPS_FILE = $DEPS_FILE"

    if [ ! -f "$DEPS_FILE" ]; then
       print_err "Dependency file does not exist: $DEPS_FILE"
       exit 1
    fi

    # Read base dependencies
    if [[ $DEPS_LIST_ONLY == 1 ]]; then
        read_deps
    else
        # Build the the list of dependencies that are missing and require install
        check_installed_dep_packages
    fi

    # Add GFX-specific kernel dependencies if gfx= parameter was provided
    # Note: OEM kernel (for APU GFX architectures) is only supported on Ubuntu 24.04
    if [[ -n "$INSTALL_GFX" && "$compo_type" == "rocm" ]]; then
        local gfx_deps_file="$deps_dir/deps/$INSTALL_GFX/required_deps_${INSTALL_GFX}.txt"

        if [[ -f "$gfx_deps_file" ]]; then
            # Check if this is Ubuntu 24.04 for OEM kernel support
            if [[ "$DISTRO_NAME" == "ubuntu" && "$DISTRO_VER" == "24.04" ]]; then
                print_str "GFX_DEPS_FILE = $gfx_deps_file"
                DEPS_FILE="$gfx_deps_file"

                if [[ $DEPS_LIST_ONLY == 1 ]]; then
                    read_deps
                else
                    check_installed_dep_packages
                fi
            else
                # OEM kernel only supported on Ubuntu 24.04 - show message to user
                echo "GFX-specific kernel dependencies (OEM kernel) only supported on Ubuntu 24.04"
                echo "Current OS: $DISTRO_NAME $DISTRO_VER - skipping kernel dependencies"
            fi
        else
            # No GFX-specific deps for this architecture - this is normal
            print_str "No GFX-specific dependencies for $INSTALL_GFX (file not found: $gfx_deps_file)"
        fi
    fi

    # Check kernel packages only for AMDGPU component (not ROCm)
    if [[ $DEPS_LIST_ONLY == 0 && "$compo_type" == "amdgpu" ]]; then
        check_installed_kernel_packages
    fi
}

build_dependencies_list() {

     # build the list of missing deps for all rocm-based components
    if [[ $USE_ROCM == 1 ]]; then
        build_dependencies_list_for_compo "rocm"
    fi

    # build the list of missing deps for all amdgpu-based components
    if [[ $USE_AMDGPU == 1 ]]; then

        # get the list of kernel packages required by amdgpu
        get_kernel_packages

        # remove any kernel packages from the current deps list that are not required
        remove_deps

        build_dependencies_list_for_compo "amdgpu"

        # filter out any duplicate packages
        remove_deps_duplicates
    fi

    # build the list of missing deps for graphics packages
    if [[ $USE_GRAPHICS -eq 1 ]]; then
        echo "------------------------------------"
        print_str "Building Dependency List for: graphics"

        # Determine the graphics deps directory and file using same logic as ROCm components
        local graphics_deps_dir
        local graphics_deps_suffix
        local graphics_deps_file

        if [ "$PACKAGE_TYPE" == "rpm" ]; then
            # For RPM packages, always use component-rocm
            graphics_deps_dir="$PWD/component-rocm"
            graphics_deps_suffix="rpm"
        else
            # For DEB packages, check if component-rocm-deb exists (chroot mode)
            # Otherwise fall back to component-rocm (native DEB system)
            if [ -d "$PWD/component-rocm-deb" ]; then
                graphics_deps_dir="$PWD/component-rocm-deb"
            else
                graphics_deps_dir="$PWD/component-rocm"
            fi
            graphics_deps_suffix="deb"
        fi

        graphics_deps_file="$graphics_deps_dir/deps/graphics/graphics_required_deps_${graphics_deps_suffix}.txt"

        if [[ -f "$graphics_deps_file" ]]; then
            print_str "GRAPHICS_DEPS_FILE = $graphics_deps_file"

            # Setup graphics repository only when actually installing (not for list/validate)
            if [[ $INSTALL_DEPS -eq 1 ]]; then
                setup_graphics_repo
            fi

            if [[ $DEPS_LIST_ONLY == 1 ]]; then
                # Just read and display graphics deps for list mode
                DEPS_FILE="$graphics_deps_file"
                read_deps
            else
                # Check graphics package installation status
                check_installed_graphics_packages "$graphics_deps_file"
            fi
        else
            print_err "Graphics dependencies file not found: $graphics_deps_file"
            exit 1
        fi
    fi

    print_deps
}

setup_epel_crb() {
   # Setup for installing EL repos
    local epel_pkg="epel-release-latest-$EPEL_VER.noarch.rpm"
    local codeready_repo="codeready-builder-for-rhel-$EPEL_VER-x86_64-rpms"

    # Setup EPEL/crb if required
    if [ -f /etc/yum.repos.d/epel.repo ]; then
        echo "EPEL repo exists."

    else
        echo "EPEL repo setup for EL $EPEL_VER."

        if ! wget --tries 5 https://dl.fedoraproject.org/pub/epel/"$epel_pkg"; then
            print_err "Unsupported version for EPEL."
            exit 1
        fi
        $SUDO rpm -ivh "$epel_pkg"

        echo "EPEL repo setup...Complete."
    fi

    # Enable the codeready-builder repo (RHEL only)
    if [[ "$DISTRO_NAME" = "rhel" ]]; then
        if ! $SUDO dnf repolist all | grep -q "^$codeready_repo"; then
            print_err "$codeready_repo repo not configured."
            exit 1
        fi

        local repo_status
        repo_status=$(dnf repolist all | grep "^$codeready_repo" | awk '{print $NF}')
        if [[ "$repo_status" == "disabled" ]]; then
            echo "Enabling $codeready_repo."
            $SUDO dnf config-manager --enable "$codeready_repo"
        fi
    else
        $SUDO crb enable
    fi
}

install_repos_el() {
    echo "------------------------------------"
    echo "Setting up Repos..."

    # Install wget if required
    if ! rpm -q "wget" > /dev/null 2>&1; then
        echo "Package: wget Installing..."
        $SUDO dnf install -y wget > /dev/null 2>&1
        echo "Package: wget installed."
    fi

    # Install dnf-plugins-core if required
    if ! rpm -q "dnf-plugins-core" > /dev/null 2>&1; then
        echo "Package: dnf-plugins-core Installing..."
        $SUDO dnf install -y dnf-plugins-core > /dev/null 2>&1
        echo "Package: dnf-plugins-core installed."
    fi

    $SUDO dnf install -y dnf-plugin-config-manager

    if [[ $EPEL_SETUP == 1 ]]; then
        setup_epel_crb
    fi

    echo "Setting up Repos...Complete."
    echo "------------------------------------"
}

# Check if a SUSE module/extension is already registered
suse_module_registered() {
    local module_name=$1

    # Use SUSEConnect --status to check if module is registered
    # Returns 0 (true) if registered, 1 (false) if not
    if $SUDO SUSEConnect --status 2>/dev/null | grep -q "\"identifier\":\"${module_name}\".*\"status\":\"Registered\""; then
        return 0  # Module is registered
    else
        return 1  # Module is not registered
    fi
}

# Register a SUSE module if not already registered
register_suse_module() {
    local module_name=$1
    local module_version=$2
    local arch=${3:-x86_64}
    local module_path="${module_name}/${module_version}/${arch}"

    if suse_module_registered "$module_name"; then
        echo "  ✓ ${module_name} already registered, skipping"
        return 0
    else
        echo "  → Activating ${module_name}..."
        if $SUDO SUSEConnect -p "$module_path"; then
            echo "  ✓ ${module_name} activated"
            return 0
        else
            echo "  ✗ Failed to activate ${module_name}"
            return 1
        fi
    fi
}

install_repos_sle() {
    echo "------------------------------------"
    echo "Setting up SLES Repos..."

    if [[ $DISTRO_NAME == "sles" ]]; then
        if [[ $DISTRO_MAJOR_VER -eq 15 ]]; then
            echo "Activating required SLES modules for version ${DISTRO_VER}..."

            # Register the 5 required modules for SLES 15.x
            register_suse_module "sle-module-python3" "${DISTRO_VER}"
            register_suse_module "sle-module-systems-management" "${DISTRO_VER}"
            register_suse_module "sle-module-desktop-applications" "${DISTRO_VER}"
            register_suse_module "sle-module-development-tools" "${DISTRO_VER}"
            register_suse_module "PackageHub" "${DISTRO_VER}"

            echo "Module activation complete."
        elif [[ $DISTRO_MAJOR_VER -eq 16 ]]; then
            echo "Activating required SLES modules for version ${DISTRO_VER}..."

            # Register PackageHub for SLES 16.x
            register_suse_module "PackageHub" "16.0"

            echo "Module activation complete."
        fi
    fi

    echo "Setting up SLES Repos...Complete."
    echo "------------------------------------"
}

block_kernel_meta_packages_debian12() {
    # On Debian 12, installing dkms triggers installation of kernel meta-packages
    # (linux-headers-amd64, linux-headers-686-pae, linux-headers-generic), which can
    # upgrade the running kernel. To prevent unwanted kernel upgrades during DKMS install,
    # block these meta-packages from installing if kernel headers for current kernel
    # are already installed or if they will be installed.
    if [[ $DISTRO_NAME == "debian" ]] && [[ $DISTRO_MAJOR_VER -eq 12 ]]; then
        if [[ " $INSTALL_LIST " == *" dkms "* ]]; then
            if [[ -n $KERNEL_PACKAGES ]]; then
                if is_pkg_deb_installed "linux-headers-$KERNEL_VER" || grep "$KERNEL_PACKAGES" <<< "$INSTALL_LIST"; then
                    echo "Add a temporary block to meta packages linux-headers-amd64, linux-headers-686-pae and linux-headers-generic to prevent kernel upgrades during DKMS install."
cat <<EOF | $SUDO tee /etc/apt/preferences.d/block-headers
Package: linux-headers-amd64 linux-headers-686-pae linux-headers-generic
Pin: release *
Pin-Priority: -1
EOF
                fi
            fi
        fi
    fi

}

install_dependencies() {
    echo ==============================================================
    echo Installing Dependencies...

    INSTALL_LIST=
    # Packages that are downloaded directly via wget.
    DIRECT_DOWNLOAD_LIST=

    # remove trailing space
    MISSING_DEPS="${MISSING_DEPS% }"

    if [ $DISTRO_PACKAGE_MGR == "apt" ]; then
        echo Updating apt cache.
        $SUDO apt-get update > /dev/null 2>&1

    elif [ $DISTRO_PACKAGE_MGR == "dnf" ]; then
        # cleanup the dnf cache
        echo Clean dnf cache.
        $SUDO dnf clean all
        $SUDO rm -rf /var/cache/dnf/*

        # add the required repos for el
        install_repos_el

        echo Updating dnf cache.
        $SUDO dnf makecache > /dev/null 2>&1

        # build a cache of installable packages based on the missing deps
        build_installable_pkg_cache_dnf

    else
        # add the required repos for sle
        install_repos_sle

        echo Updating zypper cache.
        $SUDO zypper refresh > /dev/null 2>&1
    fi

    # test if each dependency is available for install
    IFS=',' read -ra package_array <<< "$MISSING_DEPS"
    for pkg in "${package_array[@]}"; do
        INSTALL_DEPS_COUNT=$((INSTALL_DEPS_COUNT+1))

        # Skip packages that will be installed from snapshot.debian.org
        local pkg_trimmed
        # shellcheck disable=SC2001
        pkg_trimmed=$(echo "$pkg" | sed 's/^ *//')
        if [[ -n "${DEBIAN_KERNEL_PKG_INFO[$pkg_trimmed]+isset}" ]]; then
            echo --------------------------------------------------------------
            echo "Skipping apt check for $pkg_trimmed (will be installed from snapshot.debian.org)"
            DIRECT_DOWNLOAD_LIST+="$pkg_trimmed "
            continue
        fi

        check_dep_installable "$pkg"
    done

    local installopt="-y"

    if [[ $PROMPT_USER == 1 ]]; then
        installopt=
    fi

    if [[ $VERBOSE == 1 ]]; then
        echo -----------------------------------------------
        echo Installing the following based on availability:
        echo "$INSTALL_LIST"
        echo -----------------------------------------------
    fi

    # Some kernel headers for debian need to be downloaded and installed
    # from snapshot.debian.org because they may not be available in the regular
    # debian repos.
    if [[ -n $DIRECT_DOWNLOAD_LIST ]]; then
        install_kernel_packages_debian
    fi

    if [[ -n $INSTALL_LIST ]]; then
        # install the dependent packages
        if [ $DISTRO_PACKAGE_MGR == "apt" ]; then
            block_kernel_meta_packages_debian12
            $SUDO apt-get install "$installopt" $INSTALL_LIST
        elif [ $DISTRO_PACKAGE_MGR == "dnf" ]; then
            $SUDO dnf install "$installopt" $INSTALL_LIST
        else
            $SUDO zypper install --oldpackage "$installopt" $INSTALL_LIST
        fi
    fi

    # Cleanup graphics repo if it was set up
    if [[ $USE_GRAPHICS -eq 1 ]]; then
        cleanup_graphics_repo
    fi

    cleanup

    print_no_err "Dependencies Installed."
}

install_dependencies_file() {
    echo ==============================================================
    echo Installing Dependencies : File...

    read_deps
    print_deps

    install_dependencies

    echo Installing Dependencies : File...Complete.
}

####### Main script ###############################################################

echo =================================
echo DEPENDENCY INSTALLER
echo =================================

PROG=${0##*/}
SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO="sudo"

os_release
os_checks

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
        echo "Using amdgpu extract."
        USE_AMDGPU=1
        shift
        ;;
    rocm)
        echo "Using rocm extract."
        USE_ROCM=1
        shift
        ;;
    list)
        echo "Printing list of dependencies."
        DEPS_LIST_ONLY=1
        shift
        ;;
    install)
        echo "Enable dependency install."
        INSTALL_DEPS=1
        shift
        ;;
    install-file)
        echo "Enable dependency install."
        DEPS_FILE="$2"
        shift
        ;;
    verbose)
        echo "Enabling verbose logging."
        VERBOSE=1
        NO_CMD_OUTPUT=""
        shift
        ;;
    gfx=*)
        INSTALL_GFX="${1#*=}"
        echo "Using GFX architecture: $INSTALL_GFX"
        shift
        ;;
    graphics)
        echo "Enabling graphics support (amdgpu-lib)"
        USE_GRAPHICS=1
        shift
        ;;
    *)
        shift
        ;;
    esac
done

# Check if a dependency files was provided for the install
if [[ -n $DEPS_FILE ]]; then
    echo installing deps from file: "$DEPS_FILE"
    install_dependencies_file
    exit 0
fi

if [[ $USE_AMDGPU == 0 ]] && [[ $USE_ROCM == 0 ]] && [[ $USE_GRAPHICS == 0 ]]; then
    print_err "Missing argument for components directory."
    exit 1
fi

# Build the list of dependencies for the given components directories
build_dependencies_list

if [[ $INSTALL_DEPS == 1 ]]; then
    install_dependencies
fi

exit 0
