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

# ROCm Packages Source
PACKAGE_ROCM_DIR="$PWD/packages-rocm"

# AMDGPU Packages Source
PACKAGE_AMDGPU_DIR="$PWD/packages-amdgpu"

# Extraction Output
EXTRACT_ROCM_DIR="$PWD/component-rocm"
EXTRACT_AMDGPU_DIR="$PWD/component-amdgpu"

EXTRACT_ROCM_PKG_CONFIG_FILE="rocm-packages.config"
EXTRACT_AMDGPU_PKG_CONFIG_FILE="amdgpu-packages.config"

EXTRACT_AMDGPU_DKMS_VER_FILE="amdgpu-dkms-ver.txt"

EXTRACT_COMPO_LIST_FILE="components.txt"          # list the component version of extracted packages
EXTRACT_PACKAGE_LIST_FILE="packages.txt"          # list all extracted packages
EXTRACT_REQUIRED_DEPS_FILE="required_deps.txt"    # list only required dependencies (non-amd deps)
EXTRACT_GLOBAL_DEPS_FILE="global_deps.txt"        # list all extracted dependencies

# Extra/Installer dependencies
EXTRA_DEPS=(python3-setuptools python3-wheel)
INSTALLER_DEPS=(rsync wget)

# Logs
EXTRACT_LOGS_DIR="$PWD/logs"
EXTRACT_CURRENT_LOG="$EXTRACT_LOGS_DIR/extract_$(date +%s).log"

# Config
PROMPT_USER=0
ROCM_EXTRACT=0
AMDGPU_EXTRACT=0

######## Build tags EXTRACT FROM ROCM meta package
ROCM_CI_TAG=none
ROCM_VER_TAG=none
AMDGPU_VER_TAG=none
ROCM_VER=

CORE_PACKAGE=
ROCM_CI_BUILD_TAGS="crdnnh crdcb"

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
    
    pkgs-rocm=<file_path>   = <file_path> Path to ROCm source packages directory for extract.
    pkgs-amdgpu=<file_path> = <file_path> Path to AMDGPU source packages directory for extract.
    ext-rocm=<file_path>    = <file_path> Path to ROCm packages extraction directory.
    ext-amdgpu=<file_path>  = <file_path> Path to AMDGPU packages extraction directory.
        
    Example:
    
    ./package-extractor-rpms.sh prompt rocm ext-rocm="/extracted-rocm"
       
END_USAGE
}

os_release() {
    if [[ -r  /etc/os-release ]]; then
        . /etc/os-release

        DISTRO_NAME=$ID
        DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')

        case "$ID" in
	rhel)
	    echo "Extracting for RHEL $DISTRO_VER."
	    EXTRACT_DISTRO_TYPE=el
            ;;
        sles)
            echo "Extracting for SUSE $DISTRO_VER."
	    EXTRACT_DISTRO_TYPE=sle
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
        read -p "$1" option
    else
        option=y
    fi
}

install_tools() {
    echo ++++++++++++++++++++++++++++++++
    echo Installing tools...
    
    # Install rpmdevtools for dep version
    if [ $EXTRACT_DISTRO_TYPE == "el" ]; then
        $SUDO dnf install -y rpmdevtools
    elif [ $EXTRACT_DISTRO_TYPE == "sle" ]; then
        $SUDO zypper install -y rpmdevtools
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

    echo $stat_dir:
    echo ----------------------------
    echo "size:" 
    echo "-----"
    echo "$(du -sh $stat_dir | awk '{print $1}')"
    echo "$(du -sb $stat_dir | awk '{print $1}')" bytes
    echo "------"
    echo "types:"
    echo "------"
    echo "files = $(find $stat_dir -type f | wc -l)"
    echo "dirs  = $(find $stat_dir -type d | wc -l)"
    echo "links = $(find $stat_dir -type l | wc -l)"
    echo "        ------"
    echo "        $(find $stat_dir | wc -l)"
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
    echo $SCRIPTLET_OPT | tr ' ' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u
}

write_out_list() {
    local list=$1
    local file=$2
    
    echo "$list" | tr ' ' '\n' > "$file"
}

get_buildversion_info() {
    local pkg="$1"
    
    # Extract the build ci/version info from "core" packages
    if echo "$pkg" | grep -q 'core'; then   
        CORE_PACKAGE=$pkg
        echo CORE_PACKAGE = $CORE_PACKAGE

        # check for CI build tag
        for tag in $ROCM_CI_BUILD_TAGS; do 
            if echo "$pkg" | grep -q "$tag"; then
               ROCM_CI_TAG="$tag"
            fi
        done
        
        # extract the version string
    	VERSION_INFO=$(rpm -qi  --nosignature $CORE_PACKAGE | grep -E 'Version' | awk '{print $3}')
    	echo VERSION_INFO = $VERSION_INFO
    	
    	# filter out the x0y0z0 version value
    	VERSION_INFO=$(echo "$VERSION_INFO" | sed 's/.*\.//')
    	echo VERSION_INFO = $VERSION_INFO
    	
        local VER_MAJ=${VERSION_INFO:0:1}
        local VER_MIN=${VERSION_INFO:2:1}
        local VER_MIN_MIN=${VERSION_INFO:4:1}
        
        if [[ -z $VER_MIN_MIN ]]; then
            VER_MIN_MIN=0
        fi
        
        # check for rocm-core or amdgpu-core and set the tag
        if echo "$pkg" | grep -q 'amdgpu-core'; then
            AMDGPU_VER_TAG=$VER_MAJ"0"$VER_MIN"0"$VER_MIN_MIN
        elif echo "$pkg" | grep -q 'rocm-core'; then
            ROCM_VER_TAG=$VER_MAJ"0"$VER_MIN"0"$VER_MIN_MIN
            
            # get the rocm version from the rocm-core
            VERSION_INFO=$(rpm -qi  --nosignature $CORE_PACKAGE | grep -E 'Version' | awk '{print $3}')
            ROCM_VER=$(echo "$VERSION_INFO" | cut -d '.' -f 1-3)
        else
            print_err "Unknown core package: $pkg"
            exit 1
        fi
    fi
}

write_version() {
    echo -------------------------------------------------------------
    echo Writing version...
    
    i=0
    VERSION_FILE="../VERSION"
    
    while IFS= read -r line; do
        case $i in
            0) INSTALLER_VERSION="$line" ;;
        esac
        
        i=$((i+1))
    done < "$VERSION_FILE"
     
    if [[ -n $ROCM_VER ]]; then
        echo "INSTALLER_VERSION = $INSTALLER_VERSION"
        echo "ROCM_VER          = $ROCM_VER"
    
        # Update the version file
        echo "$INSTALLER_VERSION" > "$VERSION_FILE"
        echo "$ROCM_VER" >> "$VERSION_FILE"
    fi
}

get_package_list() {
    echo Getting package list...
    
    PACKAGE_LIST=
    
    if [ ! -d $PACKAGE_DIR ]; then
        print_err "$PACKAGE_DIR does not exist."
        exit 1
    fi
    
    for pkg in $PACKAGE_DIR/*; do
        if [[ $pkg == *.rpm ]]; then
            echo $pkg
            PACKAGES+="$pkg "
            
            get_buildversion_info "$pkg"
        fi
    done
    
    echo "AMDGPU_VER_TAG = $AMDGPU_VER_TAG"
    echo "ROCM_VER_TAG   = $ROCM_VER_TAG"
    echo "ROCM_CI_TAG    = $ROCM_CI_TAG"
    echo "ROCM_VER       = $ROCM_VER"
    
    # write out the ROCm version to the version file
    write_version
    
    echo Getting package list...Complete.
}

move_opt_contents_to_root() {
    echo Moving opt contents...
    
    local content_dir="$1"
    echo "Content root: $content_dir"

    # Loop through the content directory
    for dir in "$content_dir"/*; do
        local dirname=$(basename "$dir")
        # Check if the current directory is the opt directory
        if [[ -d "$dir" && $dirname == "opt" ]]; then
            echo "Found 'opt' directory: $dir"

            # Move all contents of the 'opt' directory to the root content directory
            mv "$dir/"* "$content_dir/"

            # Remove the empty 'opt' directory
            rmdir "$dir"
            echo "Moved contents of '$dir' to '$content_dir'."
        else
            echo -e "\e[93m$dir not moved.\e[0m"
            
            # workaround for extra /usr content for RHEL
            if [[ $content_dir =~ "component-rocm" && $dirname == "usr"  ]]; then
                if [[ -d "$dir/lib/.build-id" ]]; then
                    echo -e "\e[31m$dir/lib/.build-id delete\e[0m"
                    $SUDO rm -r "$dir/lib/.build-id"
                    rmdir "$dir/lib"
                    rmdir "$dir"
                fi
            fi
        fi
    done
    
    echo Moving opt contents...Complete.
}

extract_data() {
    echo --------------------------------
    echo Extracting all data/content
    echo --------------------------------
    
    local package_dir_content="$PACKAGE_DIR/content"
    
    echo Creating content directory: $package_dir_content
    mkdir $package_dir_content
    
    echo "Extracting Data..."
    
    # Extract the rpm package file content
    pushd $package_dir_content
    
        rpm2cpio "$PACKAGE" | cpio -idmv > /dev/null 2>&1
        
    popd
    
    # Move content out of the opt directory to root content directory
    move_opt_contents_to_root "$package_dir_content"
    
    echo Extracting Data...Complete.
    echo ---------------------------
}

extract_info() {
    echo --------------------------------
    echo Extracting package info
    echo --------------------------------
    
    rpm -qi --nosignature $PACKAGE
    
    VERSION_INFO=$(rpm -qi --nosignature $PACKAGE | grep -E 'Version' | awk '{print $3}')
    
    # Extract the package list
    # Check for amdgpu-based packages pulled with rocm packages
    if echo "$PACKAGE_DIR_NAME" | grep -q 'amdgpu'; then
        # filter for rocm version, 1:, build type
        VERSION_INFO=$(echo "$VERSION_INFO" | sed -E "s/.$AMDGPU_VER_TAG.*//;s/^1://")
        
        echo "$PACKAGE_DIR_NAME" >> "$EXTRACT_DIR/$EXTRACT_AMDGPU_PKG_CONFIG_FILE"
    else
        # filter for rocm version, 1:, build type
        VERSION_INFO=$(echo "$VERSION_INFO" | sed -E "s/.$ROCM_VER_TAG.*//;s/^1://;s/-$ROCM_CI_TAG.*//")
        
        echo "$PACKAGE_DIR_NAME" >> "$EXTRACT_DIR/$EXTRACT_ROCM_PKG_CONFIG_FILE"
        
        # write out the package/component version
        printf "%-25s = %s\n" "$PACKAGE_DIR_NAME" "$VERSION_INFO" >> "$EXTRACT_DIR/$EXTRACT_COMPO_LIST_FILE"
    fi
    
    echo "PACKAGE      = $PACKAGE_DIR_NAME"
    echo "VERSION_INFO = $VERSION_INFO"
}

extract_deps() {
    echo --------------------------------
    echo Extracting all dependencies
    echo --------------------------------
    
    local package_dir_deps="$PACKAGE_DIR/deps"
    
    echo "Extracting Dependencies...: $PACKAGE to $package_dir_deps"

    if [ ! -d $package_dir_deps ]; then
        echo Creating deps directory: $package_dir_deps
        mkdir -p $package_dir_deps
    fi

    echo --------------------------------
    rpm -qpRv --nosignature $PACKAGE
    echo --------------------------------
    
    DEPS=$(rpm -qpRv --nosignature $PACKAGE | grep -E 'manual' | sed 's/manual: /,/')
    
    # Process the depends
    if [[ -n $DEPS ]]; then
        echo "-------------"
        echo "Dependencies:"
        echo "-------------"
        echo $DEPS | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u
        
        # write out the dependencies
        echo $DEPS | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u > "$package_dir_deps/deps.txt"
        
        GLOBAL_DEPS+="$DEPS "
        echo "-------------"
    fi

    echo Extracting Dependencies...Complete.
    echo -----------------------------------
}

extract_scriptlets() {
    echo --------------------------------
    echo Extracting all scriptlets
    echo --------------------------------
    
    local package_dir_scriptlet="$PACKAGE_DIR/scriptlets"
    
    echo "Extracting Scriptlets...: $PACKAGE to $package_dir_scriptlet"
    
    if [ ! -d $package_dir_scriptlet ]; then
        echo Creating scriptlet directory: $package_dir_scriptlet
        mkdir -p $package_dir_scriptlet
    fi
    
    local scriptlets=$(rpm -qp --scripts --nosignature "$PACKAGE")
    echo +++++++++++
    echo $scriptlets
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
    for scriptlet in $package_dir_scriptlet/*; do
       if [[ -s $scriptlet ]]; then
           echo ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
           echo Making scriptlet $scriptlet executable.
           chmod +x "$scriptlet"
           
           # Check the script content for /opt
           if echo "$(cat $scriptlet)" | grep -q '/opt'; then
               echo "Scriptlet contains /opt"
               SCRIPTLET_OPT_COUNT=$((SCRIPTLET_OPT_COUNT+1))
               SCRIPTLET_OPT+="$(echo "$base_name") "
           fi
           
           echo ++++++++++++++++++++++++++++
           echo $(basename $scriptlet)
           echo ++++++++++++++++++++++++++++
           cat "$scriptlet"
           echo ++++++++++++++++++++++++++++
           
           if [[ $(basename $scriptlet) == "preinstall.sh" ]]; then
               SCRIPLET_PREINST_COUNT=$((SCRIPLET_PREINST_COUNT+1))
               
               # Rename for rocm-installer
               mv "$scriptlet" "$(dirname "$scriptlet")/preinst"
               
           elif [[ $(basename $scriptlet) == "postinstall.sh" ]]; then
               SCRIPLET_POSTINST_COUNT=$((SCRIPLET_POSTINST_COUNT+1))
               
               # Rename for rocm-installer
               mv "$scriptlet" "$(dirname "$scriptlet")/postinst"
               
           elif [[ $(basename $scriptlet) == "preuninstall.sh" ]]; then
               SCRIPLET_PRERM_COUNT=$((SCRIPLET_PRERM_COUNT+1))
               
               # Rename for rocm-installer
               mv "$scriptlet" "$(dirname "$scriptlet")/prerm"
               
           elif [[ $(basename $scriptlet) == "postuninstall.sh" ]]; then
               SCRIPLET_POSTRM_COUNT=$((SCRIPLET_POSTRM_COUNT+1))
               
               # Rename for rocm-installer
               mv "$scriptlet" "$(dirname "$scriptlet")/postrm"
               
           fi
           
       else
           if [[ -f $scriptlet ]]; then
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
    
    local base_name=$(basename $PACKAGE)
    
    PACKAGE_DIR_NAME=$(echo "$base_name" | sed 's/-[0-9].*$//')
    PACKAGE_DIR=$EXTRACT_DIR/$PACKAGE_DIR_NAME
    
    echo "Package Directory Name    = $PACKAGE_DIR_NAME"
    echo "Package Extract Directory = $PACKAGE_DIR"
    
    if [ ! -d $PACKAGE_DIR ]; then
        echo Create directory $PACKAGE_DIR
        mkdir -p $PACKAGE_DIR
    fi
    
    # Extract the content from data
    extract_data
    
    # Extract package info
    extract_info
    
    # Extract the dependencies
    extract_deps
    
    # Extract the scriptlets
    extract_scriptlets
    
    # write the package list
    PACKAGE_LIST+="$PACKAGE_DIR_NAME, "
    
    # Dump the file stats on the extraction
    dump_extract_stats "$PACKAGE_DIR"
    
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
    
    local package=$(rpm -q --queryformat "%{NAME}" --nosignature $PACKAGE)
    local vendor=$(rpm -qi --nosignature $PACKAGE | grep Vendor)
    
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
        AMD_PACKAGES+="$(basename $PACKAGE) "
    else
        print_err "3rd Party PACKAGE"
        NON_AMD_COUNT=$((NON_AMD_COUNT+1))
        OTHER_PACKAGES+="$(basename $PACKAGE) "
    fi
}

write_package_list() {
    echo ^^^^^^^^^^^^^^^^^^^^
    echo Extracted Packages:
    echo ^^^^^^^^^^^^^^^^^^^^
    echo PKG_COUNT = $PKG_COUNT
    echo --------------------
    echo "$PACKAGE_LIST" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u
    echo "$PACKAGE_LIST" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u > "$EXTRACT_DIR/$EXTRACT_PACKAGE_LIST_FILE"
}

filter_deps_version() {
    echo -----------------------------
    echo Dependency Version Filter...
    
    local packages_file="$EXTRACT_DIR/$EXTRACT_PACKAGE_LIST_FILE"
    local deps_file="$EXTRACT_DIR/$EXTRACT_GLOBAL_DEPS_FILE"
    
    local deps_file_filtered="$EXTRACT_DIR/global_deps_filtered.txt"
    local reqs_file="$EXTRACT_DIR/$EXTRACT_REQUIRED_DEPS_FILE"
    
    local prev_package=""
    local prev_version=""
    local prev_line=
    
    local config_file="$EXTRACT_DIR/$EXTRACT_PKG_CONFIG_FILE"
    CONFIG_PKGS=$(<"$config_file")
    
    if [ -f "$deps_file_filtered" ]; then
        rm "$deps_file_filtered"
    fi
    
    echo "TAGS: ROCM_CI_TAG=$ROCM_CI_TAG : ROCM_VER_TAG=$ROCM_VER_TAG : AMDGPU_VER_TAG=$AMDGPU_VER_TAG"
    
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
                if echo "$prev_version" | grep -qE "$ROCM_CI_TAG|$ROCM_VER_TAG|$AMDGPU_VER_TAG"; then
                    echo -e "\e[32mTag package: write prev_package: $prev_package\e[0m"
                    echo $prev_package >> "$deps_file_filtered"
                elif echo "$CONFIG_PKGS" | grep -qw "$prev_package"; then
                    echo -e "\e[32mConfig package: write prev_package: $prev_package\e[0m"
                    echo $prev_package >> "$deps_file_filtered"
                else
                    echo -e "\e[32mNon-Tag package: write prev_line: $prev_line\e[0m"
                    echo $prev_line >> "$deps_file_filtered"
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
    echo $prev_line >> "$deps_file_filtered"
    
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
    echo "$GLOBAL_DEPS" | tr ',' '\n' | awk 'NF' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u > "$EXTRACT_DIR/$EXTRACT_GLOBAL_DEPS_FILE"
}

extract_rpms() {
    echo ===================================================
    echo Extracting RPMs...
    
    PKG_COUNT=0
    
    if [ -d $EXTRACT_DIR ]; then
        echo -e "\e[93mExtraction directory exists. Removing: $EXTRACT_DIR\e[0m"
        $SUDO rm -rf $EXTRACT_DIR
    fi
    
    echo Creating Extraction directory.
    mkdir $EXTRACT_DIR
    
    echo Extracting RPM...
    
    for pkg in $PACKAGES; do
        
        PKG_COUNT=$((PKG_COUNT+1))
        
        echo -------------------------------------------------------------------------------
        echo -e "\e[93mpkg $PKG_COUNT = $(basename $pkg)\e[0m"
        
        PACKAGE=$pkg
        
        check_package_owner
        if [[ $AMDPKG == 1 ]]; then
            extract_package
        fi
        
    done
    
    echo Extracting RPMs...Complete.
}

extract_rocm_rpms() {
    echo ===================================================
    echo Extracting ROCm RPMs...
    
    echo -----------------------------------------
    echo "PACKAGE_ROCM_DIR   = $PACKAGE_ROCM_DIR"
    echo "EXTRACT_ROCM_DIR   = $EXTRACT_ROCM_DIR"
    echo -----------------------------------------
    
    PACKAGE_DIR="$PACKAGE_ROCM_DIR"
    EXTRACT_DIR="$EXTRACT_ROCM_DIR"
    
    EXTRACT_PKG_CONFIG_FILE="$EXTRACT_ROCM_PKG_CONFIG_FILE"
    
    init_stats
    
    get_package_list
    extract_rpms
    
    add_extra_deps
    
    echo Extracting ROCm RPMs...Complete.
    
    echo -e "\e[93m========================================\e[0m"
    echo -e "\e[93mExtracted ROCm: $PKG_COUNT packages\e[0m"
    echo -e "\e[93m========================================\e[0m"
}

extract_amdgpu_rpms() {
    echo ===================================================
    echo Extracting AMDGPU RPMs...
    
    echo -----------------------------------------
    echo "PACKAGE_AMDGPU_DIR = $PACKAGE_AMDGPU_DIR"
    echo "EXTRACT_AMDGPU_DIR = $EXTRACT_AMDGPU_DIR"
    echo ------------------------------------------
    
    PACKAGE_DIR="$PACKAGE_AMDGPU_DIR"
    EXTRACT_DIR="$EXTRACT_AMDGPU_DIR"
    
    EXTRACT_PKG_CONFIG_FILE="$EXTRACT_AMDGPU_PKG_CONFIG_FILE"
    
    init_stats
    
    get_package_list
    extract_rpms
    
    echo Extracting AMDGPU RPMs...Complete.

    echo -e "\e[93m========================================\e[0m"
    echo -e "\e[93m$PKG_COUNT AMDGPU packages extracted\e[0m"
    echo -e "\e[93m========================================\e[0m"
    
    # extract the amdgpu-dkms build version
    local amdgpu_dkms_path="$EXTRACT_AMDGPU_DIR/amdgpu-dkms/content/usr/src"
    
    if [ -d $amdgpu_dkms_path ]; then
        AMDGPU_DKMS_BUILD_VER=$(ls $amdgpu_dkms_path)
        AMDGPU_DKMS_BUILD_VER=${AMDGPU_DKMS_BUILD_VER#amdgpu-}
        
        echo AMDGPU_DKMS_BUILD_VER = $AMDGPU_DKMS_BUILD_VER
        echo "$AMDGPU_DKMS_BUILD_VER" >> "$EXTRACT_DIR/$EXTRACT_AMDGPU_DKMS_VER_FILE"
    fi
}

write_extract_info() {
    dump_extract_stats "$EXTRACT_DIR"
    
    write_global_deps
    write_package_list
    
    scriptlet_stats
}


####### Main script ###############################################################

# Create the extraction log directory
if [ ! -d $EXTRACT_LOGS_DIR ]; then
    mkdir -p $EXTRACT_LOGS_DIR
fi

exec > >(tee -a "$EXTRACT_CURRENT_LOG") 2>&1

echo ===============================
echo PACKAGE EXTRACTOR - RPM
echo ===============================

PROG=${0##*/}
SUDO=$([[ $(id -u) -ne 0 ]] && echo "sudo" ||:)

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
        EXTRACT_AMDGPU_DIR+="/component-amdgpu"
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

install_tools

if [[ $ROCM_EXTRACT == 1 ]]; then
    extract_rocm_rpms
    write_extract_info
    
    filter_deps_version
fi

if [[ $AMDGPU_EXTRACT == 1 ]]; then
    extract_amdgpu_rpms
    write_extract_info
    
    filter_deps_version
fi

if [[ -n $EXTRACT_CURRENT_LOG ]]; then
    echo -e "\e[32mExtract log stored in: $EXTRACT_CURRENT_LOG\e[0m"
fi

