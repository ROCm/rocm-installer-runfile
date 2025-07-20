#!/bin/bash

# #############################################################################
# Copyright (C) 2025 Advanced Micro Devices, Inc. All rights reserved.
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


###### Functions ###############################################################
os_release() {
    if [[ -r  /etc/os-release ]]; then
        . /etc/os-release

        DISTRO_NAME=$ID

        case "$ID" in
        ubuntu|debian)
            DISTRO_PACKAGE_MGR="apt"
            ;;
        rhel|ol|rocky)
            DISTRO_PACKAGE_MGR="dnf"
            ;;
        sles)
            DISTRO_PACKAGE_MGR="zypper"   
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

    echo "Setting up on $DISTRO_NAME."
}

####### Main script ###############################################################

echo =================================
echo ROCm Setup
echo =================================

os_release

# Check if the current working directory is named rocm-x.y.z
current_dir=$(basename "$(pwd)")
if [[ "$current_dir" =~ ^rocm-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # Extract the version x.y.z from the directory name
    ROCM_VERSION=$(echo "$current_dir" | sed -E 's/rocm-([0-9]+\.[0-9]+\.[0-9]+)/\1/')

    # Save the current working directory path
    ROCM_INSTALL_PATH=$(pwd)

    echo "ROCM_VERSION: $ROCM_VERSION"
    echo "ROCM_INSTALL_PATH: $ROCM_INSTALL_PATH"

    # Create the new script setup-modules-$ROCM_VERSION.sh
    SETUP_SCRIPT="setup-modules-$ROCM_VERSION.sh"
    cat << EOF > "$SETUP_SCRIPT"
#!/bin/bash

ROCM_INSTALL_PATH=$ROCM_INSTALL_PATH
ROCM_VERSION=$ROCM_VERSION

echo Setting Paths
export ROCM_PATH=\$ROCM_INSTALL_PATH
export PATH=\$PATH:\$ROCM_PATH/bin:\$ROCM_PATH/llvm/bin
export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:\$ROCM_PATH/lib:\$ROCM_PATH/llvm/lib

now=\$(date -u +%s)
altscore=\$((6 - 3))
altscore=\$((altscore * 14 + 4)) # Allow up to 14 minor
altscore=\$((altscore * 14 + 2)) # Allow up to 14 patch
altscore=\$((altscore*1000000+(\$now-1600000000)/60))

echo altscore = \$altscore

echo Setting up modules
sudo $DISTRO_PACKAGE_MGR install -y environment-modules

for loc in "/usr/share/modules/modulefiles" "/usr/local/Modules/modulefiles" "/usr/share/Modules/modulefiles"; do
    if [ -d "\$loc" ]; then
        sudo mkdir -p "\$loc/rocm"
        sudo update-alternatives --install "\$loc/rocm/\$ROCM_VERSION" "rocmmod\$ROCM_VERSION" "\$ROCM_PATH/lib/rocmmod" "\$altscore"
        break;
    fi
done

echo Setting up rocm-llvm
ln -s "$ROCM_INSTALL_PATH/lib/llvm/bin/amdclang" "$ROCM_INSTALL_PATH/bin/amdclang"
ln -s "$ROCM_INSTALL_PATH/lib/llvm/bin/amdclang++" "$ROCM_INSTALL_PATH/bin/amdclang++"
ln -s "$ROCM_INSTALL_PATH/lib/llvm/bin/amdclang-cl" "$ROCM_INSTALL_PATH/bin/amdclang-cl"
ln -s "$ROCM_INSTALL_PATH/lib/llvm/bin/amdclang-cpp" "$ROCM_INSTALL_PATH/bin/amdclang-cpp"
ln -s "$ROCM_INSTALL_PATH/lib/llvm/bin/amdflang" "$ROCM_INSTALL_PATH/bin/amdflang"
ln -s "$ROCM_INSTALL_PATH/lib/llvm/bin/amdlld" "$ROCM_INSTALL_PATH/bin/amdlld"
EOF

    # Make the new script executable
    chmod +x "$SETUP_SCRIPT"
    echo "Created $SETUP_SCRIPT"
else
    echo "The current working directory is not named rocm-x.y.z."
    exit 1
fi
