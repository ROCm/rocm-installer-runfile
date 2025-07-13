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
TARGET_ROCM_DEFAULT_DIR="$PWD"
TARGET_ROCM_DIR="$TARGET_ROCM_DEFAULT_DIR"
TARGET_AMDGPU_DIR="/"

# Component Configuration
COMPO_ROCM_FILE="$EXTRACT_ROCM_DIR/rocm-packages.config"
COMPO_ROCM_LIST="$EXTRACT_ROCM_DIR/components.txt"
COMPO_AMDGPU_FILE="$EXTRACT_AMDGPU_DIR/amdgpu-packages.config"
COMPONENTS=

# Install Configuration
RSYNC_OPTS_ROCM="--keep-dirlinks -rlp "
RSYNC_OPTS_AMDGPU="-a --keep-dirlinks --no-perms --no-owner --no-group --omit-dir-times "
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

# Uninstall data
INSTALLED_AMDGPU_DKMS_BUILD_NUM=0
FORCE_UNINSTALL_AMDGPU=0

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
        uninstall-rocm target=<directory/rocm-ver> = Uninstall ROCm version at target directory path.
                              <directory/rocm-ver> = ROCm version target directory path for uninstall.  
                                         rocm-ver  = ROCm version directory: rocm-x.y.z (x=major, y=minor, patch number)

                             * If target=<directory/rocm-ver> is not provided, uninstall will be from $PWD/rocm-x.y.z
      
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

    * ROCm install location (default) => $PWD/rocm-x.y.z
        bash $PROG rocm
    
# ROCm + Dependency installation
    
    * ROCm install location (default) => $PWD/rocm-x.y.z
        bash $PROG deps=install rocm
    
# ROCm + Dependency installation + ROCm target location
    
    * ROCm install location => /opt/rocm-x.y.z
        bash $PROG deps=install target="/" rocm
 
    * ROCm install location => $HOME/myrocm/rocm-x.y.z
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
    Uninstall ROCm from location = bash $PROG target="$HOME/myrocm/rocm-x.y.z" uninstall-rocm

    Uninstall amdgpu driver      = bash $PROG uninstall-amdgpu
    Uninstall combined           = bash $PROG uninstall-amdgpu uninstall-rocm
    
END_USAGE
}

os_release() {
    if [[ -r  /etc/os-release ]]; then
        . /etc/os-release

        DISTRO_NAME=$ID

        case "$ID" in
        ubuntu|debian)
            DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
                        
            INSTALL_SCRIPTLET_ARG="configure"
            UNINSTALL_SCRIPTLET_ARG="remove"
            PKG_INSTALLED_CMD="apt list --installed"
            ;;
        rhel|ol|rocky)
            DISTRO_VER=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
            
            if [[ $DISTRO_VER != 9* ]] && [[ "$DISTRO_NAME" = "rocky" ]]; then
                echo "$DISTRO_NAME $DISTRO_VER is not a supported OS"
                exit 1
            fi
            	   
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
    
    VERSION_BUILD=${DISTRO_BUILD_VERSION%%.*}
    VERSION_INSTALL=${DISTRO_VER%%.*}
    
    if [[ $DISTRO_NAME == "debian" ]] && [[ $DISTRO_VER == 12 ]]; then
        if [[ $VERSION_BUILD == 22 ]]; then
            echo Using 22.04 build for debian.
            VERSION_BUILD=12
        fi
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

validate_version() {
    # For non-local builds, verify package version matches for the running host distribution
        
    echo "Checking version: Build $VERSION_BUILD : Install Distro $VERSION_INSTALL"
    
    if [[ $VERSION_BUILD != $VERSION_INSTALL ]]; then
        echo -e "\e[31m++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\e[0m"
        echo -e "\e[31mError: ROCm Runfile Installer Package mismatch:\e[0m"
        echo -e "\e[31mInstall Build: ${DISTRO_NAME} ${VERSION_BUILD}\e[0m"
        echo -e "\e[31mInstall OS   : ${DISTRO_NAME} ${VERSION_INSTALL}\e[0m"
        echo -e "\e[31m++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\e[0m"
        echo Exiting installation.
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
        read -p "$1" option
    else
        option=y
    fi
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
        ls $ls_opt $rocm_install_loc
        
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
    local stat_dir="$1/$INSTALLER_ROCM_VERSION_NAME"
    
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
    echo -e "\e[96mINSTALL Dependencies : $DISTRO_NAME $DISTRO_BUILD_VERSION\e[0m"
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
    
        # validate the version of the installer
        validate_version
        
        echo Validating required dependencies
        
        ./deps-installer.sh $deps_rocm $deps_amdgpu $depOp
        status=$?
        
        if [[ status -ne 0 ]]; then
            print_err "Failed Dependencies validation."
            exit 1
        fi
        
        exit 0
        
    elif [[ $DEPS_ARG == "install" ]] || [[ $DEPS_ARG == "install-only" ]]; then
    
        # validate the version of the installer
        validate_version
        
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
    local rocm_reloc="$TARGET_DIR"
    local postinst_reloc="$1-reloc"
    
    echo "config: $rocm_reloc"
    
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

    # Perform the replacement
    sed -i "s/$search_string/$replace_string/g" "$scriptlet_file"

    # Check if replacement was successful
    if [ $? -eq 0 ]; then
        echo "Successfully updated $scriptlet_file"
    else
        echo "Error processing $file"
        # Restore backup if there was an error
        mv "$scriptlet_file.bak" "$scriptlet_file"
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

uninstall_prerm_scriptlet_amdgpu() {
    local component=$1
    local prerm_scriptlet="$EXTRACT_DIR/$component/scriptlets/prerm"

    # execute pre-install with arg "remove" or "0"
    if [[ -s "$prerm_scriptlet" ]]; then
        echo --------------------------------
        echo -e "\e[92mExecuting prerm script for $component...\e[0m"

        if [[ $FORCE_UNINSTALL_AMDGPU == 1 ]]; then
            echo "Patching prerm scriptlet $prerm_scriptlet"
            patch_scriptlet_version $prerm_scriptlet $AMDGPU_DKMS_BUILD_NUM $INSTALLED_AMDGPU_DKMS_BUILD_NUM
        fi
        
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

        if [[ $FORCE_UNINSTALL_AMDGPU == 1 ]]; then
            echo "Restoring prerm scriptlet $prerm_scriptlet"
            mv "$prerm_scriptlet.bak" "$prerm_scriptlet"
        fi
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
    
    if [[ -n $INSTALLED_PKGS ]]; then
        local matches=$(echo "$INSTALLED_PKGS" | grep -E "^($component)/")
        if [[ -n $matches ]]; then
            print_warning "Package installation of ROCm package: $component"
            echo $matches
            read -p "Overwrite package install of $compo (y/n): " option
            if [[ $option == "Y" || $option == "y" ]]; then
                echo "Proceeding with install..."
                # Copy the component content/data to the target location
                $SUDO rsync $RSYNC_OPTS_ROCM "$content_dir"/* "$TARGET_DIR"
                if [ $? -ne 0 ]; then
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
        $SUDO rsync $RSYNC_OPTS_ROCM "$content_dir"/* "$TARGET_DIR"
        if [ $? -ne 0 ]; then
            print_err "rsync error."
            exit 1
        fi
        COMPONENT_COUNT=$((COMPONENT_COUNT+1))
    fi
        
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

check_rocm_package_install() {
    #echo Checking for package installation: $1...
    
    local rocm_loc=$1
    local ret=0
    
    # Package install only for /opt installs
    if [[ "$TARGET_DIR" == "/opt" || "$rocm_loc" == "/opt/rocm"* ]]; then
        # check for a rocm-core package and if it matches the version of rocm being installed
        local rocm_core_pkg=$($PKG_INSTALLED_CMD 2>&1 | grep "rocm-core")
        
        local rocm_ver_name=$(basename "$rocm_loc")
        local rocm_ver=${rocm_ver_name#rocm-}
    
        IFS='.' read -r x y z <<< "${rocm_ver_name#rocm-}"
        local rocm_core_ver=$(printf "%d%02d%02d" "$x" "$y" "$z")
        
        if [[ -n $rocm_core_pkg ]] && [[ "$rocm_core_pkg" == *"$rocm_core_ver"* ]]; then
            echo rocm-core package detected : $rocm_core_ver
        
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

find_rocm_with_progress() {
    ROCM_DIR=
    ROCM_TARGET_ROOT=0
    
    local rocm_find_base=
    local rocm_version_dir=""
    local rocm_depth=
    
    local find_opt=$1
    local found=1
    local progress=0
    local temp_file=$(mktemp)
    
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
    find "$rocm_find_base" $rocm_depth -type f -path '*/rocm-*/.info/version' ! -path '*/rocm-installer/component-rocm/*' -print 2>/dev/null > "$temp_file" &
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
        done < <(sort -V "$temp_file")
        
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
    read -p "Do you wish to continue with a new Runfile ROCm installation (y/n): " option
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
            # Check if the same version is being installed
            if [[ "$inst" == *"$INSTALLER_ROCM_VERSION"* ]]; then
                echo Version match: $INSTALLER_ROCM_VERSION
                prev_install=1
                break
            fi
        done
        
        # Query the user for processing of the previous install of rocm
        if [[ $prev_install -eq 1 ]]; then
            query_prev_rocm "$inst"
        fi  
    fi
}

preinstall_rocm() {
    echo --------------------------------
    echo Preinstall ROCm...
    
    # Check for installer prerequisites
    prereq_installer_check
    
    # Check for any previous installs of ROCm for the current target
    find_rocm_with_progress "$TARGET_DIR"

    if [[ $? -eq 0 ]]; then
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

configure_rocm_install() {
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
}

install_rocm() {
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    echo -e "\e[96mINSTALL ROCm\e[0m"
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    
    set_rocm_target
    
    # If using a target, check that the target directory for install exists
    if [[ -n "$INSTALL_TARGET" && ! -d "$TARGET_DIR" ]]; then
        print_err "Target directory $TARGET_DIR for install does not exist."
        exit 1
    fi
    
    # Find the ROCm version for install
    ROCM_CORE_VER_DIR=$(find "$EXTRACT_DIR/rocm-core/content" -type d -name "*rocm*" -print -quit)
    INSTALLER_ROCM_VERSION_NAME=$(basename "$ROCM_CORE_VER_DIR")
    INSTALLER_ROCM_VERSION=${INSTALLER_ROCM_VERSION_NAME#rocm-}
    
    IFS='.' read -r x y z <<< "$INSTALLER_ROCM_VERSION"
    ROCM_CORE_VER_STR=$(printf "%d%02d%02d" "$x" "$y" "$z")
    
    echo "Install    : $INSTALLER_ROCM_VERSION_NAME : $ROCM_CORE_VER_STR"
    
    # Check if rocm is installable
    preinstall_rocm
    
    prompt_user "Install ROCm (y/n): "
    if [[ $option == "N" || $option == "n" ]]; then
        echo "Exiting Installer."
        exit 1
    fi
    
    # configure the rocm components for install
    configure_rocm_install
    
    # Install each component in the component list for ROCm
    for compo in ${COMPONENTS[@]}; do
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        echo -e "\e[32mInstalling $compo\e[0m"
        install_rocm_component $compo
        echo ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    done
    
    dump_rocm_state
    dump_stats "$TARGET_DIR"
}

uninstall_rocm_target() {
    local inst=$1

    # set the version directory
    local rocm_ver_dir="${inst%/}"
    local rocm_rm_dir="${inst%/\rocm*}"
    
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
        
        if [ -d "$rocm_ver_dir" ]; then
            echo -e "\e[93mRemoving ROCm version directory: $rocm_ver_dir\e[0m"
            $SUDO rm -r "$rocm_ver_dir"
        fi
        
        # Check if the "rocm" symlink exists
        if [[ -L "$rocm_rm_dir/rocm" ]]; then
            echo "Found symlink 'rocm': $rocm_rm_dir"
            
            local item_count=$(find "$rocm_rm_dir" -mindepth 1 -maxdepth 1 | wc -l)

            # If the directory contains only the "rocm" symlink, delete it
            if [[ $item_count -eq 1 ]]; then
                $SUDO rm "$rocm_rm_dir/rocm"
                echo "Removing symlink 'rocm'."
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
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    echo -e "\e[95mUNINSTALL ROCm\e[0m"
    echo =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    
    set_rocm_target
    
    # Check for any previous installs of ROCm
    find_rocm_with_progress "$TARGET_DIR"
    
    if [[ $? -eq 0 ]]; then
    
        # Update the target for scriptlet hanndling
        if [[ "$TARGET_DIR" == *"rocm"* ]]; then
            TARGET_DIR="${TARGET_ROCM_DIR%/\rocm*}"
            echo "TARGET_DIR : $TARGET_DIR"
        fi

        # Check the list of rocm installs for the current target
        IFS=',' read -ra rocm_install <<< "$ROCM_INSTALLS"
        
        print_no_err "ROCm Installs found: ${#rocm_install[@]}"
        
        # Check if multiple rocm installs at current target
        if [[ ${#rocm_install[@]} > 1 ]]; then
            echo "Multiple ROCm installs for target=$INSTALL_TARGET"
            read -p "Do you wish to uninstall all ROCm installations at target (y/n): " option
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

install_amdgpu_component() {
    echo --------------------------------

    local component=$1
    local content_dir="$EXTRACT_DIR/$component/content"
    local script_dir="$EXTRACT_DIR/$component/scriptlets"

    echo Copying content component: $component...

    # Copy the component content/data to the target location 

    if [[ $component == "amdgpu-dkms" ]]; then

        $SUDO rsync $RSYNC_OPTS_AMDGPU "$content_dir/"* "$TARGET_DIR"
        if [ $? -ne 0 ]; then
            print_err "rsync error."
            exit 1
        fi

        if [ -f "$script_dir/amdgpu_firmware" ]; then
            # workaround amdgpu_firmware being called via amdgpu-dkms.amdgpu_firmware
            $SUDO cp -p $script_dir/amdgpu_firmware $script_dir/amdgpu-dkms.amdgpu_firmware
        fi
    else
        $SUDO rsync $RSYNC_OPTS_AMDGPU "$content_dir/"* "$TARGET_DIR"

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

query_prev_driver_version() {
    # Get DKMS status output
    # SUSE require sudo for dkms
    dkms_output=$($SUDO dkms status)

    while read -r line; do
        # Extract driver name and version (format is "module, version, kernel/arch/...")
        if [[ $line =~ ^([^\/]+)\/([^,]+),\ ([^,]+),\ (.+)$ ]]; then
            driver=${BASH_REMATCH[1]}
            if [ $driver = "amdgpu" ]; then
                INSTALLED_AMDGPU_DKMS_BUILD_NUM="${BASH_REMATCH[2]}"
                kernel_version=${BASH_REMATCH[3]}
                if [[ $VERBOSE == 1 ]]; then
                    echo "Driver: $driver"
                    echo "Version: $INSTALLED_AMDGPU_DKMS_BUILD_NUM"
                    echo "Kernel Version: $kernel_version"
                fi
            fi
        fi
    done < <(echo $dkms_output)
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
        query_prev_driver_version

        if [ ! $INSTALLED_AMDGPU_DKMS_BUILD_NUM = 0 ] ; then
            print_err "amdgpu driver installed, version $INSTALLED_AMDGPU_DKMS_BUILD_NUM"
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
    
    # validate the version of the installer
    validate_version
    
    # Check if amdgpu is installable
    preinstall_amdgpu

    echo "EXTRACT_AMDGPU_DIR = $EXTRACT_AMDGPU_DIR"
    echo "TARGET_AMDGPU_DIR  = $TARGET_AMDGPU_DIR"

    EXTRACT_DIR="$EXTRACT_AMDGPU_DIR"
    TARGET_DIR="$TARGET_AMDGPU_DIR"
    COMPO_FILE="$COMPO_AMDGPU_FILE"
    
    read_components
    
    # Install each component in the component list for amdgpu
    for compo in ${COMPONENTS[@]}; do
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
    local force_remove_dir=0

    find $file_path -type $type -print0 | while IFS= read -r -d '' filename; do
        remove_filename=$(echo $filename|sed -e "s%$path_to_files%%g")

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
                $SUDO rm -f $remove_filename 2>/dev/null
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

    query_prev_driver_version

    if [ $INSTALLED_AMDGPU_DKMS_BUILD_NUM == 0 ] ; then
        print_err "amdgpu driver not installed."
        echo "Please install amdgpu using the Runfile installer."
        echo "Usage: bash $PROG amdgpu"
        exit 1
    fi

    echo "Installed amdgpu version $INSTALLED_AMDGPU_DKMS_BUILD_NUM"
    echo "Runfile amdgpu version $AMDGPU_DKMS_BUILD_NUM"

    if [ ! $INSTALLED_AMDGPU_DKMS_BUILD_NUM == $AMDGPU_DKMS_BUILD_NUM ] ; then
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
    read_components

    # Run the pre-remove scripts for each component
    # Workaround for amdgpu packages order
    #for compo in ${COMPONENTS[@]}; do
    remove_arr=($COMPONENTS)
    for(( i=0; i<${#remove_arr[@]}; i++ )) do
        compo=${remove_arr[i]}

        uninstall_prerm_scriptlet_amdgpu $compo

        # remove files
        path_to_files="$EXTRACT_AMDGPU_DIR/$compo/content"

        echo "Removing amdgpu files..."
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
    
    local rocm_ver_dir=
    
    # check if postrocm is part of a rocm install
    if [[ $ROCM_INSTALL == 1 ]]; then
        echo ROCm post-install...
        if [[ $TARGET_DIR == "/" ]]; then
            rocm_ver_dir="/opt/$INSTALLER_ROCM_VERSION_NAME"
        else
            rocm_ver_dir="$TARGET_DIR/$INSTALLER_ROCM_VERSION_NAME"
        fi
        
    else
        echo ROCm post-install for target...
        
        # check if the target arg is used
        if [[ -z "$INSTALL_TARGET" ]]; then
            print_err "target= argument required."
            exit 1
        fi
        
        set_rocm_target
    	
    	# check if target has a rocm install
        find_rocm_with_progress "$TARGET_DIR"
        if [[ $? -ne 0 ]]; then
            print_err "ROCm runfile install at target $TARGET_DIR not found."
            exit 1
        fi
        
        IFS=',' read -ra rocm_install <<< "$ROCM_INSTALLS"
        print_no_err "ROCm Installs found: ${#rocm_install[@]}"
        
        # Only allow for single post-rocm install
        if [[ ${#rocm_install[@]} > 1 ]]; then
            print_err "Multiple ROCm installation found.  Please select a single target for post install."
            exit 1
        fi
        
        # check if there found target rocm version matches the rocm version of the installer
        local rocm_ver_name=$(basename "${rocm_install[0]}")
        local rocm_ver=${rocm_ver_name#rocm-}
        
        echo "Install ROCm version: $ROCM_VERSION"
        echo "Target ROCM version : $rocm_ver"
            
        if [[ "$rocm_ver" != "$ROCM_VERSION" ]]; then
            print_err "ROCm version mismatch."
            exit 1
        fi
        
        rocm_ver_dir="$ROCM_DIR"
        TARGET_DIR="${TARGET_DIR%/\rocm-[0-9]*}"
        
        # configure the rocm components for install
        configure_rocm_install    
    fi
    
    echo "rocm_ver_dir: $rocm_ver_dir"
    echo "TARGET_DIR  : $TARGET_DIR"
    
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

# Create the installer log directory
if [ ! -d $RUN_INSTALLER_LOG_DIR ]; then
    mkdir -p $RUN_INSTALLER_LOG_DIR
fi

exec > >(tee -a "$RUN_INSTALLER_CURRENT_LOG") 2>&1

echo =================================
echo ROCm INSTALLER
echo =================================

SUDO=$([[ $(id -u) -ne 0 ]] && echo "sudo" ||:)
SUDO_OPTS="$SUDO"
PROG=${0##*/}

os_release

echo "args: $@"
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
        echo "Enabling Post ROCm install."
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
            check_rocm_package_install "$inst"
            if [[ $? -eq 0 ]]; then
                echo "Runfile        : $inst"
            else
                echo "Package manager: $inst"
            fi
            
        done
        
        exit 0
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
        RSYNC_OPTS_ROCM+="--itemize-changes -v "
        RSYNC_OPTS_AMDGPU+="--itemize-changes -v "
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

echo "Installer log stored in: $RUN_INSTALLER_CURRENT_LOG"

