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
EXTRACT_FORMAT="${EXTRACT_FORMAT:-deb}"

# ROCm Packages Source - defaults to format-specific directory
PACKAGE_ROCM_DIR="${PACKAGE_ROCM_DIR:-$PWD/packages-rocm-${EXTRACT_FORMAT}}"

# AMDGPU Packages Source - defaults to format-specific directory
PACKAGE_AMDGPU_DIR="${PACKAGE_AMDGPU_DIR:-$PWD/packages-amdgpu-${EXTRACT_FORMAT}}"

# Extraction output directories
EXTRACT_ROCM_DIR="../rocm-installer/component-rocm"
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

# Extra/Installer dependencies
EXTRA_DEPS=(python3-yaml)
INSTALLER_DEPS=(rsync)

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
    amdgpu                  = Extract AMDGPU packages
    rocm                    = Extract ROCm packages

    nocontent               = Disables content extraction (deps, scriptlets will be extracted only).
    contentlist             = Lists all files extracted to content directories during extraction.

    pkgs-rocm=<file_path>   = <file_path> Path to ROCm source packages directory for extract.
    pkgs-amdgpu=<file_path> = <file_path> Path to AMDGPU source packages directory for extract.
    ext-rocm=<file_path>    = <file_path> Path to ROCm packages extraction directory.
    ext-amdgpu=<file_path>  = <file_path> Path to AMDGPU packages extraction directory.

    Example:

    ./package-extractor-debs.sh prompt rocm ext-rocm="/extracted-rocm"

END_USAGE
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

    # workaround for extra /usr content
    if [[ -d "$dir/share/lintian/overrides" ]]; then
        echo -e "\e[31m$dir/share/lintian/overrides delete\e[0m"
        $SUDO rm -rf "$dir"
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

    # Find the data archive (unpacked by ar in extract_package)
    if [ -f "$PACKAGE_DIR/data.tar.gz" ]; then
        data="$PACKAGE_DIR/data.tar.gz"
    elif [ -f "$PACKAGE_DIR/data.tar.zst" ]; then
        data="$PACKAGE_DIR/data.tar.zst"
    else
        data="$PACKAGE_DIR/data.tar.xz"
    fi

    echo Extracting Data = "$data"

    tar -xf "$data" -C "$package_dir_content"

    rm "$data"

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

    # Extract the build ci/version info from "base" packages
    if echo "$pkg" | grep -q 'amdrocm-base'; then
        echo "--------------------------------"
        echo "Extract rocm versioning..."

        # Extract version from package filename
        local pkg_basename
        pkg_basename=$(basename "$pkg")

        local pattern='amdrocm-base([0-9]+\.[0-9]+)_'

        if [[ $pkg_basename =~ $pattern ]]; then
            ROCM_VER="${BASH_REMATCH[1]}"
        else
            VERSION_INFO=$(dpkg -I "$pkg" | grep -E ' Version:' | awk -F ': ' '{print $2}')
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

    dpkg -I "$PACKAGE"

    VERSION_INFO=$(dpkg -I "$PACKAGE" | grep -E ' Version:' | awk -F ': ' '{print $2}')

    # Write metadata files to deps/{gfx_tag}/ directory
    # Check for amdgpu-based packages pulled with rocm packages
    if echo "$PACKAGE_DIR_NAME" | grep -q 'amdgpu'; then
        # write out the package/component version
        echo "$PACKAGE_DIR_NAME" >> "$EXTRACT_DEPS_DIR/$COMP_TYPE/$EXTRACT_AMDGPU_PKG_CONFIG_FILE"
    else
        echo "$PACKAGE_DIR_NAME" >> "$EXTRACT_DEPS_DIR/$COMP_TYPE/$EXTRACT_ROCM_PKG_CONFIG_FILE"

        # write out the package/component version
        printf "%-25s = %s\n" "$PACKAGE_DIR_NAME" "$VERSION_INFO" >> "$metadata_dir/$EXTRACT_COMPO_LIST_FILE"
        printf "%-25s = %s\n" "$PACKAGE_DIR_NAME" "$VERSION_INFO"
    fi

    echo "VERSION_INFO = $VERSION_INFO"
    echo "PACKAGE      = $PACKAGE_DIR_NAME"

    extract_version "$PACKAGE"
}

extract_deps() {
    echo --------------------------------
    echo Extracting all dependencies
    echo --------------------------------

    # Use top-level deps directory with GFX tag subdirectory
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
    dpkg -I "$PACKAGE" | grep -E "(Depends|Recommends)"
    echo --------------------------------

    DEPS=$(dpkg -I "$PACKAGE" | grep -E ' Depends' | awk -F ': ' '{print $2}')
    RECOMMENDS=$(dpkg -I "$PACKAGE" | grep -E ' Recommends' | awk -F ': ' '{print $2}')

    # Combine Depends and Recommends (apt installs Recommends by default)
    local ALL_DEPS="$DEPS"
    if [[ -n $RECOMMENDS ]]; then
        if [[ -n $ALL_DEPS ]]; then
            ALL_DEPS+=", $RECOMMENDS"
        else
            ALL_DEPS="$RECOMMENDS"
        fi
    fi

    # Process the combined dependencies
    if [[ -n $ALL_DEPS ]]; then
        echo "-------------"
        echo "Dependencies (Depends + Recommends):"
        echo "-------------"
        echo "$ALL_DEPS" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u

        # write out the dependencies
        echo "$ALL_DEPS" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u > "$package_dir_deps/deps.txt"

        GLOBAL_DEPS+="$ALL_DEPS, "
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

    # Find the control archive (unpacked by ar in extract_package)
    if [ -f "$PACKAGE_DIR/control.tar.gz" ]; then
        control="$PACKAGE_DIR/control.tar.gz"
    elif [ -f "$PACKAGE_DIR/control.tar.zst" ]; then
        control="$PACKAGE_DIR/control.tar.zst"
    else
        control="$PACKAGE_DIR/control.tar.xz"
    fi

    echo "Extracting control: $control"

    tar -xf "$control" -C "$package_dir_scriptlet"

    rm "$control"
    rm "$package_dir_scriptlet/control"
    if [ -f "$package_dir_scriptlet/md5sums" ]; then
        rm "$package_dir_scriptlet/md5sums"
    fi

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

           if [[ $(basename "$scriptlet") == "preinst" ]]; then
               SCRIPLET_PREINST_COUNT=$((SCRIPLET_PREINST_COUNT+1))

           elif [[ $(basename "$scriptlet") == "postinst" ]]; then
               SCRIPLET_POSTINST_COUNT=$((SCRIPLET_POSTINST_COUNT+1))

           elif [[ $(basename "$scriptlet") == "prerm" ]]; then
               SCRIPLET_PRERM_COUNT=$((SCRIPLET_PRERM_COUNT+1))

           elif [[ $(basename "$scriptlet") == "postrm" ]]; then
               SCRIPLET_POSTRM_COUNT=$((SCRIPLET_POSTRM_COUNT+1))
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

    PACKAGE_DIR_NAME=$(echo "$base_name" | awk -F'_' '{print $1}')

    # Use temp directory for unpacking .deb file
    PACKAGE_DIR=$(mktemp -d)

    echo "Package Directory Name = $PACKAGE_DIR_NAME"
    echo "Component Type         = $COMP_TYPE"

    # Unpack the .deb file (creates data.tar.*, control.tar.*, debian-binary)
    echo "Unpack '$PACKAGE'"
    ar xv --output "$PACKAGE_DIR" "$PACKAGE"

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

    # Clean up temp directory
    rm -rf "$PACKAGE_DIR"

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
    local maintainer
    local description

    package=$(dpkg -I "$PACKAGE" | grep "Package:")
    maintainer=$(dpkg -I "$PACKAGE" | grep -m 1 "Maintainer:")
    description=$(dpkg -I "$PACKAGE" | grep "Description:")

    if [[ $package =~ "amdgpu" || $package =~ "rocm" || $package =~ "hip" ]]; then
        AMDPKG=1
    else
       if [[ -n $maintainer ]]; then
           if [[ $maintainer =~ Advanced\ Micro\ Devices || $maintainer =~ ROCm || $maintainer =~ AMD || $maintainer =~ amd\.com ]]; then
               AMDPKG=1
           fi
       fi

       if [[ -n $description ]]; then
           if [[ $description =~ "Advanced Micro Devices" || $description =~ "ROCm" || $description =~ "Radeon"  ]]; then
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

    # Write to deps/{gfx_tag}/ directory
    echo "$PACKAGE_LIST" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u > "$EXTRACT_DEPS_DIR/$COMP_TYPE/$EXTRACT_PACKAGE_LIST_FILE"
}

filter_deps_version() {
    echo -----------------------------
    echo Dependency Version Filter...

    # Read from deps/{gfx_tag}/ directory
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

        # filter the current package for spaces around "|" in multi-deps lines and versioning within brackets
        # shellcheck disable=SC2001
        current_package=$(echo "$line" | sed 's/ *| */|/g')
        current_package=$(echo "$current_package" | awk -F '[()]' '{print $1}' | awk '{print $1}')

        # extract the current version number only
        current_version=$(echo "$line" | sed -n 's/.*(\(.*\)).*/\1/p' | sed 's/[><=]*//g' | awk '{print $1}')

        echo ++++++
        echo "current  : $current_package : $current_version"
        echo "prev     : $prev_package : $prev_version"
        echo "prev_line: $prev_line"
        echo ++++++

        if [[ -n $prev_package ]]; then
            # check if the current and previous dep are equal.  If equal, compare the version
            if [ "$current_package" = "$prev_package" ]; then
                echo "Same package (cur = prev): comparing versions"
                if dpkg --compare-versions "$current_version" gt "$prev_version"; then
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

    # Write to deps/{gfx_tag}/ directory
    echo "$GLOBAL_DEPS" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u > "$EXTRACT_DEPS_DIR/$COMP_TYPE/$EXTRACT_GLOBAL_DEPS_FILE"
}

extract_debs() {
    echo ===================================================
    echo Extracting DEBs...

    PKG_COUNT=0

    # COMP_TYPE should already be set by caller (extract_rocm_debs or extract_amdgpu_debs)
    # Directories should already be created by caller
    if [[ -z "$COMP_TYPE" ]]; then
        echo "ERROR: COMP_TYPE not set before calling extract_debs"
        return 1
    fi

    echo Extracting DEB...

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

    echo Extracting DEBs...Complete.
}

combine_deps() {
    echo ===================================================
    echo Combining dependencies from all component-rocm subdirectories...

    # Use the new deps/ directory structure
    local deps_root_dir="$EXTRACT_DEPS_DIR"
    if [ ! -d "$deps_root_dir" ]; then
        echo "ERROR: $deps_root_dir directory does not exist!"
        return 1
    fi

    # Put the combined deps file in EXTRACT_ROCM_DIR root
    local output_dir="$EXTRACT_ROCM_DIR"
    local combined_deps_file="$output_dir/rocm_required_deps_deb.txt"
    local gfx_deps_file="$output_dir/rocm_required_deps_deb_gfx.tmp"
    local gfx_deps_sorted="$output_dir/rocm_required_deps_deb_gfx_sorted.tmp"
    local gfx_deps_filtered="$output_dir/rocm_required_deps_deb_gfx_filtered.tmp"
    local temp_deps_file="$output_dir/rocm_required_deps_deb.tmp"

    # Remove only the output file and temporary files
    echo "Removing previous rocm_required_deps_deb.txt if it exists..."
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
    local all_packages_file="$output_dir/all_packages.tmp"
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
    if [ -f "$all_packages_file" ]; then
        # Filter out any AMD packages from the combined dependencies
        # Extract package name (before space or comparison operator) and check against packages list
        sort -u "$temp_deps_file" | while IFS= read -r dep_line; do
            # Extract package name (everything before first space, =, <, >, or ()
            pkg_name=$(echo "$dep_line" | awk '{print $1}' | sed 's/[<>=()].*//')
            # Check if package name is in the AMD packages list
            if ! grep -qxF "$pkg_name" "$all_packages_file"; then
                echo "$dep_line"
            fi
        done > "$combined_deps_file"
    else
        sort -u "$temp_deps_file" > "$combined_deps_file"
    fi

    rm -f "$temp_deps_file" "$all_packages_file"

    local total_deps
    total_deps=$(wc -l < "$combined_deps_file")
    echo "Combined dependencies from $gfx_component_count gfx component subdirectories + base component"
    echo "Total unique required dependencies: $total_deps"
    echo "Output file: $combined_deps_file"

    echo Combining dependencies...Complete.
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

    local pkg_name
    pkg_name=$(basename "$(dirname "$signature_file")")

    # Check if this is a meta package with scriptlets but no content
    if [ $sig_count -eq 0 ]; then
        # Determine component type from the signature file path
        local comp_type=""
        if [[ "$signature_file" =~ /deps/base/ ]]; then
            comp_type="base"
        elif [[ "$signature_file" =~ /deps/(gfx[^/]+)/ ]]; then
            comp_type="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$comp_type" ]]; then
            local scriptlet_dir="$EXTRACT_SCRIPTLETS_DIR/$comp_type/$pkg_name"
            if [[ -d "$scriptlet_dir" ]] && [[ -n "$(find "$scriptlet_dir" -type f \( -name 'preinst' -o -name 'postinst' -o -name 'prerm' -o -name 'postrm' \) 2>/dev/null)" ]]; then
                # Meta package with scriptlets - create special marker signature
                echo "META_PACKAGE_WITH_SCRIPTLETS" >> "$signature_file"
                sig_count=1
                echo "  Generated meta package signature for $pkg_name (has scriptlets, no content)"
            fi
        fi
    else
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

extract_rocm_debs() {
    echo ===================================================
    echo Extracting ROCm DEBs...

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

    # Collect all package files and group by gfx tag
    declare -A GFX_PACKAGES
    GFX_PACKAGES["base"]=""

    for pkg_file in "$PACKAGE_DIR"/*.deb; do
        if [[ -f "$pkg_file" ]]; then
            pkg_name=$(basename "$pkg_file")

            # Detect gfx tag from package name (e.g., amdrocm-blas7.11-gfx94x_*.deb)
            if [[ "$pkg_name" =~ -gfx([0-9a-z]+)_ ]]; then
                gfx_tag="gfx${BASH_REMATCH[1]}"
                GFX_PACKAGES["$gfx_tag"]+="$pkg_file "
            else
                # Non-gfx package goes to base
                GFX_PACKAGES["base"]+="$pkg_file "
            fi
        fi
    done

    # Process each gfx group
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

        extract_debs

        add_extra_deps

        write_extract_info
        filter_deps_version

        echo -e "\e[93m========================================\e[0m"
        echo -e "\e[93mExtracted: $PKG_COUNT $gfx_tag packages\e[0m"
        echo -e "\e[93m========================================\e[0m"
    done

    # Combine dependencies from all component-rocm subdirectories
    echo ""
    combine_deps

    # Generate signature files for uninstall auto-detection
    echo ""
    generate_rocm_signature_files

    echo ""
    echo Extracting ROCm DEBs...Complete.
}

extract_amdgpu_debs() {
    echo ===================================================
    echo Extracting AMDGPU DEBs...

    PACKAGE_DIR="$PACKAGE_AMDGPU_DIR"
    EXTRACT_PKG_CONFIG_FILE="$EXTRACT_AMDGPU_PKG_CONFIG_FILE"

    # Check if package directory exists
    if [[ ! -d "$PACKAGE_DIR" ]]; then
        echo "ERROR: Package directory not found: $PACKAGE_DIR"
        return 1
    fi

    # Extract distro name from EXTRACT_AMDGPU_DIR path to use as COMP_TYPE
    # e.g., ../rocm-installer/component-amdgpu/ub24 → COMP_TYPE=ub24
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

    echo Getting package list...

    PACKAGE_LIST=

    for pkg in "$PACKAGE_DIR"/*; do
        if [[ $pkg == *.deb ]]; then
            echo "$pkg"
            PACKAGES+="$pkg "
        fi
    done

    echo Getting package list...Complete.

    extract_debs

    echo ""
    echo Extracting AMDGPU DEBs...Complete.

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
    echo "Extraction statistics for: $gfx_tag"
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
echo PACKAGE EXTRACTOR - DEB
echo ===============================

PROG=${0##*/}
SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO="sudo"

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

prompt_user "Extract packages (y/n): "
if [[ $option == "N" || $option == "n" ]]; then
    echo "Exiting extractor."
    exit 1
fi

if [[ $ROCM_EXTRACT == 1 ]]; then
    extract_rocm_debs
fi

if [[ $AMDGPU_EXTRACT == 1 ]]; then
    extract_amdgpu_debs
    write_extract_info

    filter_deps_version
fi

if [[ -n $EXTRACT_CURRENT_LOG ]]; then
    echo -e "\e[32mExtract log stored in: $EXTRACT_CURRENT_LOG\e[0m"
fi
