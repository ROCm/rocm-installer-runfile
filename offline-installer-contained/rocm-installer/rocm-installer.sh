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

# Logs
RUN_INSTALLER_LOG_DIR="$PWD/logs"
RUN_INSTALLER_CURRENT_LOG="$RUN_INSTALLER_LOG_DIR/install_$(date +%s).log"

# Source extract directories
EXTRACT_ROCM_DIR="$PWD/component-rocm"
EXTRACT_AMDGPU_DIR="$PWD/component-amdgpu"

# Target install directories
TARGET_ROCM_DEFAULT_DIR="$PWD/rocm"
TARGET_ROCM_DIR="$TARGET_ROCM_DEFAULT_DIR"
TARGET_AMDGPU_DIR="/"

# Component Configuration
COMPO_ROCM_FILE="$EXTRACT_ROCM_DIR/rocm-packages.config"
COMPO_ROCM_LIST="$EXTRACT_ROCM_DIR/components.txt"
COMPO_AMDGPU_FILE="$EXTRACT_AMDGPU_DIR/amdgpu-packages.config"
COMPONENTS=

# Install Configuration
RSYNC_OPTS="--keep-dirlinks -rlp"
ROCM_INSTALL=0
AMDGPU_INSTALL=0
AMDGPU_START=0
NCURSES_BAR=1

COMPONENT_COUNT=0
POSTINST_COUNT=0
PRERM_COUNT=0
POSTRM_COUNT=0
PROMPT_USER=0
POST_ROCM_INSTALL=0
VERBOSE=0

# Installer preqreqs
INSTALLER_DEPS=(rsync)


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
        
        force  = Force ROCm/amdgpu driver install. 
        
        target=<directory>
               <directory> = Target directory path for ROCm component install.
            
        compconfig=<file_path>
                   <file_path> = Path to components configuration file.
        	
        comp=<comp_list>
             <comp_list> = List of components to install (overrides component configure file).
        
    Post Install:
    -------------
        postrocm     = Run post ROCm installation configuration (scripts, symlink create, etc.)
        amdgpu-start = Start the amdgpu driver after install.

        gpu-access=<access_type>
        
                   <access_type>
                       user = Add current user to render,video group for GPU access
                       all  = Grant GPU access to all users on the system via udev rules.
                 
    Uninstall:
    ----------
        uninstall-rocm (target=<directory>) = Uninstall ROCm. If no target is provided, the first instance of ROCm will be unintalled.
        	        target=directory>   = Optional.  Set target=<directory> to the directory where ROCm is installed.
      
        uninstall-amdgpu = Uninstall amdgpu driver.
        	           
    
    Information/Debug:
    ------------------
    findrocm = Search for an install of ROCm.
    complist = List the version of ROCm components included in the installer.
    prompt   = Run the installer with user prompts.
    verbose  = Run installer with verbose logging
    
+++++++++++++++++++++++++++++++
Usage examples:
+++++++++++++++++++++++++++++++
    
# ROCm installation (no Dependency install)

    * ROCm install location (default) => $PWD/rocm
        bash $PROG rocm
    
# ROCm + Dependency installation
    
    * ROCm install location (default) => $PWD/rocm
        bash $PROG deps=install rocm
    
# ROCm + Dependency installation + ROCm target location
    
    * ROCm install location => /opt
        bash $PROG deps=install target="/" rocm
 
    * ROCm install location => $HOME/myrocm
        bash $PROG deps=install target="$HOME/myrocm" rocm
    
# ROCm + Dependency installation + ROCm target location + Post ROCm configuration
    
    bash $PROG deps=install target="/" rocm postrocm
    bash $PROG deps=install target="$HOME/myrocm" rocm postrocm
    
# ROCm + Dependency installation + ROCm target location + Post ROCm configuration + gpu access (all)

    bash $PROG deps=install target="/" rocm postrocm gpu-access=all
    bash $PROG deps=install target="$HOME/myrocm" rocm postrocm gpu-access=all
    
    ** Recommended ***
    
# amdgpu Driver installation (no Dependency install)
    
    bash $PROG amdgpu

# amdgpu Driver + Dependency installation
    
    bash $PROG deps=install amdgpu
    
# Combined Installation

    bash $PROG deps=install target="/" rocm amdgpu postrocm gpu-access=all
    bash $PROG deps=install target=$HOME/myrocm" rocm amdgpu postrocm gpu-access=all
    
# Uninstall

    Uninstall ROCm               = bash $PROG uninstall-rocm
    Uninstall ROCm from location = bash $PROG target="$HOME/myrocm" uninstall-rocm
    Uninstall amdgpu driver      = bash $PROG uninstall-amdgpu
    Uninstall combined           = bash $PROG uninstall-amdgpu uninstall-rocm
    
END_USAGE
}

os_release() {
    if [[ -r  /etc/os-release ]]; then
        . /etc/os-release

        DISTRO_NAME=$ID

        case "$ID" in
        ubuntu)
            DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
            
	    INSTALL_SCRIPTLET_ARG="configure"
	    UNINSTALL_SCRIPTLET_ARG="remove"
	    PKG_INSTALLED_CMD="apt list --installed"
	    ;;
	rhel)
	    DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
	   
	    INSTALL_SCRIPTLET_ARG="1"
	    UNINSTALL_SCRIPTLET_ARG="0"
	    PKG_INSTALLED_CMD="rpm -qa"
	    
	    if ! rpm -qa | grep -qE "ncurses-[0-9]"; then
	        NCURSES_BAR=0
	    fi
	    
            ;;
        sles)
            if rpm -qa | grep -q "awk"; then
	        DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
	    fi
            
	    INSTALL_SCRIPTLET_ARG="1"
	    UNINSTALL_SCRIPTLET_ARG="0"
	    PKG_INSTALLED_CMD="rpm -qa"
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
    
    echo "Installing for $DISTRO_NAME $DISTRO_VER."
}

get_version() {
    local i=0
    
    if [ -f "./VERSION" ]; then
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
    fi
    
    echo "Installer Version: $INSTALLER_VERSION"
    echo "ROCm Version     : $ROCM_VERSION"
    echo "ROCm Build       : $ROCM_BUILD_NUM"
    echo "amdgpu Build     : $AMDGPU_DKMS_BUILD_NUM"
    echo "Installer        : $BUILD_INSTALLER_NAME"
    
    if [[ $RUNFILE_INSTALL == 1 ]]; then
        PROG="$BUILD_INSTALLER_NAME"
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

print_warning() {
    local msg=$1
    echo -e "\e[93m++++++++++++++++++++++++++++++++++++\e[0m"
    echo -e "\e[93m$msg\e[0m"
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
        read -p "$1" option
    else
        option=y
    fi
}

dump_rocm_state() {
    echo ============================
    echo ROCm Install Summary
    echo ============================
    
    local rocm_install_loc=
    local ls_opt=
    
    if [[ ! $TARGET_DIR == "/" ]]; then
        rocm_install_loc=$TARGET_DIR
    fi
    
    for dir in "$rocm_install_loc/opt"/*; do
        if [ -d $dir ] && echo $dir | grep -q 'rocm-'; then
            rocm_directory=$dir
            break
        fi
    done
    
    echo -e "\e[32mROCm Installed to: $rocm_directory\e[0m"

    if [[ $VERBOSE == 1 ]]; then
        ls_opt="-la"
        
        echo ----------------------------
        echo -e "\e[95m$TARGET_DIR\e[0m"
        ls $ls_opt $TARGET_DIR
        
        echo ----------------------------
        if [[ ! $TARGET_DIR == "/" ]]; then
            echo -e "\e[95m$TARGET_DIR/opt\e[0m"
        else
            echo -e "\e[95m/opt\e[0m"
        fi
        ls $ls_opt $TARGET_DIR/opt
        
        echo ----------------------------
        echo -e "\e[95m$rocm_directory\e[0m"
        ls $ls_opt $rocm_directory
        
        echo ----------------------------
        echo -e "\e[95m/etc/ld.so.conf.d\e[0m"
        ls /etc/ld.so.conf.d
        
        echo ----------------------------
        echo -e "\e[95m/etc/alternatives\e[0m"
        ls $ls_opt /etc/alternatives
        
        echo ----------------------------
        echo -e "\e[95m$rocm_directory/include\e[0m"
        ls $ls_opt $rocm_directory/include
        
        echo ----------------------------
        echo -e "\e[95m$rocm_directory/bin\e[0m"
        ls $ls_opt $rocm_directory/bin
        
        echo ----------------------------
        echo -e "\e[95m$rocm_directory/lib\e[0m"
        ls $ls_opt $rocm_directory/lib
    fi
    
    echo ----------------------------
    echo -e "\e[95mInstalled Components:\e[0m"
    echo "$COMPONENTS"
}

dump_stats() {
    echo ----------------------------
    echo STATS
    echo -----
    
    echo "COMPONENT_COUNT = $COMPONENT_COUNT"
    echo "POSTINST_COUNT  = $POSTINST_COUNT"
    
    echo -----
    local stat_dir=$1
    
    if [[ "$stat_dir" == //* ]]; then
        stat_dir="/${stat_dir#//}"
    fi

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

install_deps() {
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    echo -e "\e[96mINSTALL Dependencies\e[0m"
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    
    echo Installing Dependencies...
    
    echo "DEPS_ARG = $DEPS_ARG"
    
    local status=0
    
    # select switch deps to be install (rocm/amdgpu)
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
        
        ./deps-installer.sh $deps_rocm $deps_amdgpu $depOp list
        status=$?
        
         if [[ status -ne 0 ]]; then
            print_err "Failed Dependencies list."
            exit 1
        fi
        
        exit 0
        
    elif [[ $DEPS_ARG == "validate" ]]; then
        
        echo Validating required dependencies
        
        ./deps-installer.sh $deps_rocm $deps_amdgpu $depOp
        status=$?
        
        if [[ status -ne 0 ]]; then
            print_err "Failed Dependencies validation."
            exit 1
        fi
        
        exit 0
        
    elif [[ $DEPS_ARG == "install" ]] || [[ $DEPS_ARG == "install-only" ]]; then
        
        ./deps-installer.sh $deps_rocm $deps_amdgpu $depOp install
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

read_components() {
    echo --------------------------------
    echo "Read Component Configuration: $COMPO_FILE ..."
    
    COMPONENTS=
    
    if [ ! -f $COMPO_FILE ]; then
        print_err "Component config file $COMPO_FILE does not exist."
        exit 1
    fi
    
    while IFS= read -r compo; do
        COMPONENTS="$COMPONENTS $compo"
    done < "$COMPO_FILE"
    
    echo "COMPONENTS = $COMPONENTS"
    
    echo "Read Component Configuration...Complete."
}

list_components() {
    echo --------------------------------
    
    if [ -f $COMPO_ROCM_LIST ]; then    
        while IFS= read -r compo; do
            echo "$compo"
        done < "$COMPO_ROCM_LIST"
    else
        print_err "Components list $COMPO_ROCM_LIST does not exist."
    fi
    
    exit 0
}

set_prefix_scriptlet() {
    local rocm_ver_dir=$1
    
    # Set the PREFIX variable for rpm-based extracted scriptlets
    if [[ $INSTALL_SCRIPTLET_ARG == "1" ]]; then
    
        if [[ -n $SUDO_OPTS ]]; then
            SUDO_OPTS="$SUDO -E"
        fi
        echo SUDO_OPTS = $SUDO_OPTS
        
        if [[ -n $rocm_ver_dir ]]; then
            echo "Setting PREFIX0 = $rocm_ver_dir"
            export RPM_INSTALL_PREFIX0="$rocm_ver_dir"
        fi
    fi
}

configure_scriptlet() {
    print_str "Configuring scriptlet."
    
    local scriptlet=$(cat $1)
    
    local rocm_default="/opt"
    local rocm_reloc="$TARGET_DIR/opt"
    local postinst_reloc="$1-reloc"
    
    if echo "$scriptlet" | grep -q '/opt'; then
         print_str "/opt detected -> $rocm_reloc"
    fi
    
    print_str "Using scriptlet: $1"
    
    sed "s|$rocm_default|$rocm_reloc|g" $1 > "$postinst_reloc"
    $SUDO chmod +x "$postinst_reloc"
}

install_postinst_scriptlet() {
    local component=$1
    local postinst_scriptlet="$EXTRACT_DIR/$component/scriptlets/postinst"
    
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
            $SUDO_OPTS "$postinst_scriptlet-reloc" "$INSTALL_SCRIPTLET_ARG"
        else
            $SUDO_OPTS "$postinst_scriptlet" "$INSTALL_SCRIPTLET_ARG"
        fi
        
        echo -e "\e[92mComplete: $?\e[0m"
        
        POSTINST_COUNT=$((POSTINST_COUNT+1))
    fi
}

uninstall_prerm_scriptlet() {
    local component=$1
    local prerm_scriptlet="$EXTRACT_DIR/$component/scriptlets/prerm"
    
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
            $SUDO_OPTS "$prerm_scriptlet-reloc" "$UNINSTALL_SCRIPTLET_ARG"
        else
            $SUDO_OPTS "$prerm_scriptlet" "$UNINSTALL_SCRIPTLET_ARG"
        fi
        
        echo -e "\e[92mComplete: $?\e[0m"
        
        PRERM_COUNT=$((PRERM_COUNT+1))
    fi
}

uninstall_postrm_scriptlet() {
    local component=$1
    local postrm_scriptlet="$EXTRACT_DIR/$component/scriptlets/postrm"
    
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
            $SUDO_OPTS "$postrm_scriptlet-reloc" "$UNINSTALL_SCRIPTLET_ARG"
        else
            $SUDO_OPTS "$postrm_scriptlet" "$UNINSTALL_SCRIPTLET_ARG"
        fi

        echo -e "\e[92mComplete: $?\e[0m"

        POSTRM_COUNT=$((POSTRM_COUNT+1))
    fi
}

install_rocm_component() {
    echo --------------------------------
    
    local component=$1
    local content_dir="$EXTRACT_DIR/$component/content"
    local script_dir="$EXTRACT_DIR/$component/scriptlets"
    
    echo Copying content component: $component...

    # Copy the component content/data to the target location
    $SUDO rsync $RSYNC_OPTS "$content_dir"/* "$TARGET_DIR"
    if [ $? -ne 0 ]; then
        print_err "rsync error."
        exit 1
    fi
            
    COMPONENT_COUNT=$((COMPONENT_COUNT+1))
        
    echo Copying content component: $component...Complete.
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

find_rocm_with_progress() {
    ROCM_DIR=
    ROCM_TARGET_ROOT=0
    
    local rocm_find_base=
    local rocm_version_dir=""
    
    local find_opt=$1
    local found=1
    local progress=0
    local temp_file=$(mktemp)
    
    # Check for a package install of rocm
    if $PKG_INSTALLED_CMD 2>&1 | grep "rocm"; then
        print_err "Package installation of ROCm"
        echo "Please uninstall previous version of ROCm using the package manager."
        exit 1
    else
        echo No package-based ROCm install found.
    fi

    # optimize the search based on if the target arg is set or "all" option
    if [[ "$find_opt" == "all" || -z "$INSTALL_TARGET" ]]; then
        echo Using no target.
        rocm_find_base="/"
    else
        echo Using target argument.
        
        # Check for a /opt/rocm install
        if [ "$TARGET_ROCM_DIR" == "/" ]; then
           echo Target directory is /
           rocm_find_base="/opt"
        else
            echo Target directory is not / 
            rocm_find_base="$TARGET_ROCM_DIR"
        fi
    fi

    # Look for the rocm install directory
    echo "Looking for ROCm at: $rocm_find_base"

    # Start the find command in the background
    find "$rocm_find_base" -type f -path '*/opt/rocm-*/.info/version' ! -path '*/rocm-installer/component-rocm/*' -print 2>/dev/null > "$temp_file" &
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
        echo "ROCm detected."
        
        ROCM_DIR=${rocm_version_dir%%.info*}
        echo "ROCm Install Directory found."
        
        # check if the path is root at the default /opt/rocm*
        if [[ "$ROCM_DIR" == /opt/rocm* ]]; then
            echo ROCm Default Root path.
            ROCM_TARGET_ROOT=1
        fi
        
        # list any rocm install paths
        ROCM_INSTALLS=
        echo "ROCm Installation/s:"
        while IFS= read -r rocm_inst; do
            echo "    ${rocm_inst%%.info*}"
            ROCM_INSTALLS+="${rocm_inst%%.info*},"
        done < "$temp_file"
        
        found=0
    fi
    
    if [ ! -f "$temp_file" ]; then
        rm "$temp_file"
    fi
    
    return $found
}

prereq_installer_check() {
    local not_install=""
    
    # Check if the require packages are installed on the system for installer to function
    for pkg in ${INSTALLER_DEPS[@]}; do
        # Check if this a package install of rocm
        if ! $PKG_INSTALLED_CMD 2>&1 | grep "$pkg" > /dev/null 2>&1; then
            echo "Package $pkg not installed."
            not_install+="$pkg "
        else
            echo $pkg is installed
        fi
    done  
    
    if [[ -n $not_install ]]; then
        print_err "ROCm Runfile installer requires installation of the following packages: $not_install"
        exit 1
    fi
}

process_prev_rocm() {
    # Check if rocm install is being forced, if not, prompt the user
    if [[ $FORCE_INSTALL == 1 ]]; then
        print_warning "Forcing ROCm install."
    else
        echo -e "Multiple Runfile installations may cause existing installs to stop functioning.\n"
        read -p "Do you wish to continue with a new Runfile ROCm installation (y/n): " option
        if [[ $option == "Y" || $option == "y" ]]; then
            echo "Proceeding with install..."
        else
            echo -e "Exiting Installer.\n"
            echo -e "Please uninstall previous version/s of ROCm using the Runfile installer.\n"
            echo "Usage:"
            echo "------"
            IFS=',' read -ra rocm_install <<< "$ROCM_INSTALLS"
            for inst in "${rocm_install[@]}"; do
                if [[ "$inst" == /opt/rocm* ]]; then
                   echo "bash $PROG target=/ uninstall-rocm"
                else
                    echo "bash $PROG target=${inst%%/\opt*} uninstall-rocm"
                fi
            done
            echo
            
            exit 1
        fi
    fi
}

preinstall_rocm() {
    echo --------------------------------
    echo Preinstall ROCm...
    
    # Check for installer prerequisites
    prereq_installer_check
    
    # Check for any previous installs of ROCm
    find_rocm_with_progress "all"

    if [[ $? -eq 0 ]]; then
        print_warning "Warning: Runfile installation of ROCm detected"
        process_prev_rocm
    else
        print_no_err "ROCm Install not found."
    fi
    
    echo Preinstall ROCm...Complete.
    echo --------------------------------
}

install_rocm() {
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    echo -e "\e[96mINSTALL ROCm\e[0m"
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    
    # If using a target, check that the target directory for install exists
    if [[ -n "$INSTALL_TARGET" && ! -d "$TARGET_ROCM_DIR" ]]; then
        print_err "Target directory $TARGET_ROCM_DIR for install does not exist."
        exit 1
    fi
    
    # Check if rocm is installable
    preinstall_rocm
    
    echo "EXTRACT_ROCM_DIR = $EXTRACT_ROCM_DIR"
    echo "TARGET_ROCM_DIR  = $TARGET_ROCM_DIR"
    
    EXTRACT_DIR="$EXTRACT_ROCM_DIR"
    TARGET_DIR="$TARGET_ROCM_DIR"
    
    # Find the ROCm version for install
    ROCM_CORE_VER_DIR=$(find "$EXTRACT_DIR/rocm-core/content/opt" -type d -name "*rocm*" -print -quit)
    ROCM_CORE_VER_NAME=$(basename "$ROCM_CORE_VER_DIR")
    echo "Installing: $ROCM_CORE_VER_NAME"
    
    prompt_user "Install ROCm (y/n): "
    if [[ $option == "N" || $option == "n" ]]; then
        echo "Exiting Installer."
        exit 1
    fi
    
    if [[ -n $INSTALL_COMPO ]]; then
       echo Installing component: $INSTALL_COMPO
       COMPONENTS=$INSTALL_COMPO
    else
        if [[ -n $INSTALL_COMPO_FILE ]]; then
            COMPO_FILE="$INSTALL_COMPO_FILE"
        else
            COMPO_FILE="$COMPO_ROCM_FILE"
        fi
        
        echo Installing components from config.
        read_components
    fi
    
    # Install each component in the component list for ROCm
    for compo in ${COMPONENTS[@]}; do
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        echo -e "\e[32mInstalling $compo\e[0m"
        install_rocm_component $compo
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    done
    
    # Install/set any post install configuration
    if [[ $POST_ROCM_INSTALL == 1 ]]; then
        install_post_rocm
    fi
    
    dump_rocm_state
    dump_stats "$TARGET_ROCM_DIR/opt"
}

uninstall_rocm() {
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    echo -e "\e[95mUNINSTALL ROCm\e[0m"
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    
    echo "EXTRACT_ROCM_DIR = $EXTRACT_ROCM_DIR"
    echo "INSTALL_TARGET   = $INSTALL_TARGET"
    
    EXTRACT_DIR="$EXTRACT_ROCM_DIR"
    
    local rocm_ver_dir=
    local rocm_rm_dir=
    
    # Check for any previous installs of ROCm
    find_rocm_with_progress
    
    if [[ $? -eq 0 ]]; then
        print_no_err "ROCm Install found."
        
        # set the version directory
        rocm_ver_dir="${ROCM_DIR%/}"
        
        # check for the root/default target /opt/rocm
        if [[ $ROCM_TARGET_ROOT == 1 ]]; then
            TARGET_DIR="/"
            rocm_rm_dir="$ROCM_DIR"
        else
            TARGET_DIR="${ROCM_DIR%%/\opt*}"
            rocm_rm_dir="${ROCM_DIR%/\rocm*}"
        fi
        
        echo "TARGET_DIR             : $TARGET_DIR"
        echo "ROCM Version Directory : $rocm_ver_dir/"
        echo "ROCm Removal Directory : $rocm_rm_dir"
    else
        print_err "ROCm Install Directory not found"
        exit 1
    fi
    
    # Start the uninstall
    prompt_user "Uninstall ROCm (y/n): "
    if [[ $option == "N" || $option == "n" ]]; then
        echo "Exiting Installer."
        exit 1
    fi

    # if the directory for removal exists, then remove the components and delete it
    if [[ -d "$rocm_rm_dir" && "rocm_rm_dir" != "/" ]]; then
        echo Uninstalling components from config.
    
        COMPO_FILE="$COMPO_ROCM_FILE"
        read_components
        
        # Set the PREFIX variable for rpm-based extracted scriptlets if required
        set_prefix_scriptlet "$rocm_ver_dir"
    
        # Run the pre-remove scripts for each component
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        echo "prerm executing...."
        for compo in ${COMPONENTS[@]}; do
            uninstall_prerm_scriptlet $compo
        done
        echo "prerm executing....Complete."
        
        # Run the post-remove scripts for each component
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        echo "postrm executing...."
        for compo in ${COMPONENTS[@]}; do
            uninstall_postrm_scriptlet $compo
        done
        echo "postrm executing....Complete."
        
        echo -e "\e[93mRemoving install directory: $rocm_rm_dir\e[0m"
        $SUDO rm -r "$rocm_rm_dir"
        
        # if target is the default install path and the directory exist remove it
        if [[ "$TARGET_DIR" == *"$TARGET_ROCM_DEFAULT_DIR"* && -d "$TARGET_ROCM_DEFAULT_DIR" ]]; then
            echo -e "\e[93mRemoving default directory: $TARGET_ROCM_DEFAULT_DIR\e[0m"
            $SUDO rm -r "$TARGET_ROCM_DEFAULT_DIR"
        fi
    else
        print_err "ROCm remove target: $rocm_rm_dir does not exist."
        exit 1
    fi
    
    # remove extra install directories
    if [[ -d "$TARGET_DIR/long_pathname_so_that_rpms_can_package_the_debug_info" ]]; then
        echo Removing long_pathname.
        echo -e "\e[93mRemoving long_pathname.\e[0m"
        $SUDO rm -r "$TARGET_DIR/long_pathname_so_that_rpms_can_package_the_debug_info"
    fi
    
    echo "PRERM_COUNT  = $PRERM_COUNT"
    echo "POSTRM_COUNT = $POSTRM_COUNT"
    echo -e "\e[95mUNINSTALL ROCm Components. Complete.\e[0m"   
}

install_amdgpu_component() {
    echo --------------------------------

    local component=$1
    local content_dir="$EXTRACT_DIR/$component/content"
    local script_dir="$EXTRACT_DIR/$component/scriptlets"

    echo Copying content component: $component...

    # Copy the component content/data to the target location 

    if [[ $component == "amdgpu-dkms" ]]; then

        $SUDO rsync $RSYNC_OPTS "$content_dir/"* "$TARGET_DIR"
        if [ $? -ne 0 ]; then
            print_err "rsync error."
            exit 1
        fi

        if [ -f "$script_dir/amdgpu_firmware" ]; then
            # workaround amdgpu_firmware being called via amdgpu-dkms.amdgpu_firmware
            $SUDO cp -p $script_dir/amdgpu_firmware $script_dir/amdgpu-dkms.amdgpu_firmware
        fi
    else
        $SUDO rsync $RSYNC_OPTS "$content_dir/"* "$TARGET_DIR"

        if [ $? -ne 0 ]; then
            print_err "rsync error."
            exit 1
        fi
    fi

    COMPONENT_COUNT=$((COMPONENT_COUNT+1))

    echo Copying content component: $component...Complete.

    # Process any scriptlets
    for scriptlet in $script_dir/*; do
        if [[ -f $scriptlet ]]; then
            print_str "Detected: $scriptlet."
        fi
    done

    # Execute any postinst scriptlets
    install_postinst_scriptlet $component
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

    # Check if deps are install ie. dkms
    if $PKG_INSTALLED_CMD 2>&1 | grep "dkms" > /dev/null 2>&1; then
        echo "dkms package installed."
        # Check if driver already present in dkms
        if $SUDO dkms status | grep "amdgpu"; then
            print_err "amdgpu driver installed."
            echo "Please uninstall previous version of amdgpu using the Runfile installer."
            echo "Usage: bash $PROG uninstall-amdgpu"
            exit 1
        fi
    else
        print_err "dkms package not installed."
        exit 1
    fi

    echo Preinstall amdgpu...Complete.
    echo --------------------------------
}

install_amdgpu() {
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    echo -e "\e[96mINSTALL AMDGPU\e[0m"
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    
    # Check if amdgpu is installable
    preinstall_amdgpu

    echo "EXTRACT_AMDGPU_DIR = $EXTRACT_AMDGPU_DIR"
    echo "TARGET_AMDGPU_DIR  = $TARGET_AMDGPU_DIR"

    EXTRACT_DIR="$EXTRACT_AMDGPU_DIR"
    TARGET_DIR="$TARGET_AMDGPU_DIR"
    COMPO_FILE="$COMPO_AMDGPU_FILE"
    
    read_components

    # Workaround for amdgpu packages order
    #for compo in ${COMPONENTS[@]}; do
    install_arr=($COMPONENTS)
    for(( i=${#install_arr[@]}-1; i>=0; i-- )) do
        compo=${install_arr[i]}

        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        echo -e "\e[32mInstalling $compo\e[0m"
        install_amdgpu_component $compo
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

    find $file_path -type $type -print0 | while IFS= read -r -d '' filename; do
        remove_filename=$(echo $filename|sed -e "s%$path_to_files%%g")

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
    local installed_dir=$2

    # Recursively check all subdirs under files starting from the deepest level

    find "$files_dir" -depth -type d | while read -r subdir_files_dir; do
        # Remove the base path of installation to get the relative path
        relativePath="${subdir_files_dir#$files_dir}"

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
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    echo -e "\e[95mUNINSTALL amdgpu\e[0m"
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

    echo "EXTRACT_AMDGPU_DIR = $EXTRACT_AMDGPU_DIR"
    echo "TARGET_AMDGPU_DIR  = $TARGET_AMDGPU_DIR"

    EXTRACT_DIR="$EXTRACT_AMDGPU_DIR"
    TARGET_DIR="$TARGET_AMDGPU_DIR"

    echo Uninstalling components from config.

    COMPO_FILE="$COMPO_AMDGPU_FILE"
    read_components

    # Run the pre-remove scripts for each component
    # Workaround for amdgpu packages order
    #for compo in ${COMPONENTS[@]}; do
    remove_arr=($COMPONENTS)
    for(( i=0; i<${#remove_arr[@]}; i++ )) do
        compo=${remove_arr[i]}

        uninstall_prerm_scriptlet $compo
        # remove files
        path_to_files="$EXTRACT_AMDGPU_DIR/$compo/content"

        find_and_delete $path_to_files "l"
        find_and_delete $path_to_files "f"

        delete_empty_dirs $path_to_files "/"

        uninstall_postrm_scriptlet $compo
    done

    echo "PRERM_COUNT  = $PRERM_COUNT"
    echo "POSTRM_COUNT = $POSTRM_COUNT"
    echo -e "\e[95mUNINSTALL amdgpu Components. Complete.\e[0m"
}

install_postint_scriptlets() {
    echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    echo Running post install scripts...
    
    for compo in ${COMPONENTS[@]}; do
        install_postinst_scriptlet $compo
    done
    
    echo Running post install scripts...Complete.
}

install_post_rocm() {
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    echo -e "\e[96mINSTALL ROCm post-install config\e[0m"
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    
    echo "TARGET_DIR = $TARGET_DIR"
    
    local rocm_ver_dir=
    
    if [[ $TARGET_DIR == "/" ]]; then
        rocm_ver_dir="/opt/$ROCM_CORE_VER_NAME"
    else
        rocm_ver_dir="$TARGET_DIR/opt/$ROCM_CORE_VER_NAME"
    fi
    
    # Set the PREFIX variable for rpm-based extracted scriptlets if required
    set_prefix_scriptlet "$rocm_ver_dir"
    
    # Run all postinstall scripts for the components
    install_postint_scriptlets
}

set_gpu_access() {
    echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    echo Setting GPU Access...

    if [[ $GPU_ACCESS == "user" ]]; then
        echo Adding current user: $USER to render,video group.

        $SUDO usermod -aG render,video $USER

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

####### Main script ###############################################################

echo =================================
echo ROCm INSTALLER
echo =================================

SUDO=$([[ $(id -u) -ne 0 ]] && echo "sudo" ||:)
SUDO_OPTS="$SUDO"
PROG=${0##*/}

os_release

# Create the installer log directory
if [ ! -d $RUN_INSTALLER_LOG_DIR ]; then
    mkdir -p $RUN_INSTALLER_LOG_DIR
fi

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
        AMDGPU_START=1
        echo "Start amdgpu on install."
        shift
        ;;
    rocm)
        ROCM_INSTALL=1
        ROCM_ARG="all"
        echo "Using ROCm args : $ROCM_ARG"
        shift
        ;;
    rocm=*)
        ROCM_INSTALL=1
        ROCM_ARG="${1#*=}"
        echo "Using ROCm args : $ROCM_ARG"
        shift
        ;;
    compconfig=*)
        INSTALL_COMPO_FILE="${1#*=}"
        echo Using component install configuration: $INSTALL_COMPO_FILE
        shift
        ;;
    comp=*)
        INSTALL_COMPO="${1#*=}"
        echo Installing component: $INSTALL_COMPO
        shift
        ;;
    target=*)
        INSTALL_TARGET="${1#*=}"
        echo Using install target location: $INSTALL_TARGET
        TARGET_ROCM_DIR="$INSTALL_TARGET"
        shift
        ;;
    force)
        FORCE_INSTALL=1
        echo "Forcing install."
        shift
        ;;
    runfile)
        RUNFILE_INSTALL=1
        echo "install from runfile."
        shift
        ;;
    postrocm)
        echo "Enabling post ROCm install."
        POST_ROCM_INSTALL=1
        shift
        ;;
    gpu-access=*)
        GPU_ACCESS="${1#*=}"
        echo Setting GPU access: $GPU_ACCESS
        shift
        ;;
    findrocm)
        echo "Finding ROCm install."
        
        find_rocm_with_progress

        if [[ $? -eq 0 ]]; then
            echo "Runfile installation of ROCm: $ROCM_DIR"
            exit 0
        else
            echo "ROCm Install not found."
            exit 1
        fi
        ;;
    complist)
        echo Component List
        list_components
        shift
        ;;
    prompt)
        echo "Enabling user prompts."
        PROMPT_USER=1
        shift
        ;;
    verbose)
        echo "Enabling verbose logging."
        VERBOSE=1
        RSYNC_OPTS+="v"
        shift
        ;;
    uninstall-rocm)
        echo "Enabling Uninstall ROCm"
        UNINSTALL_ROCM=1

        DEPS_ARG=
        ROCM_INSTALL=0
        AMDGPU_INSTALL=0
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

exec > >(tee -a "$RUN_INSTALLER_CURRENT_LOG") 2>&1

get_version

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

echo "Installer log stored in: $RUN_INSTALLER_CURRENT_LOG"

