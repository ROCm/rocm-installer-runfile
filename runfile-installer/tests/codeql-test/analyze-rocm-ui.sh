#!/bin/bash

# #############################################################################
# Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
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

# Quick-start script for analyzing ROCm UI
# This is a convenience wrapper that uses the rocm-ui.conf

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


os_release() {
    if [[ ! -r /etc/os-release ]]; then
        echo "ERROR: Cannot detect OS - /etc/os-release not found"
        exit 1
    fi

    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO_NAME=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
    DISTRO_VER="$VERSION_ID"

    # Validate this is AlmaLinux (manylinux build environment)
    if [[ "$DISTRO_NAME" != "almalinux" ]]; then
        echo "ERROR: This script is designed for AlmaLinux manylinux build environment only"
        echo "Detected OS: $DISTRO_NAME $DISTRO_VER"
        echo ""
        echo "The ROCm UI build process is tightly coupled to the AlmaLinux manylinux"
        echo "container environment used for ROCm installer builds."
        echo ""
        echo "If you need to run CodeQL on other distributions, use the generic"
        echo "run-codeql-analysis.sh script directly with appropriate configuration."
        exit 1
    fi

    echo "Detected: AlmaLinux $DISTRO_VER (manylinux build environment)"
}

install_rocm_ui_prerequisites() {
    echo "======================================================================"
    echo "Installing ROCm UI Build Prerequisites"
    echo "======================================================================"

    # Install ncurses-devel (required for all builds)
    if ! rpm -q ncurses-devel > /dev/null 2>&1; then
        echo "Installing ncurses-devel..."
        $SUDO dnf install -y ncurses-devel
    else
        echo "ncurses-devel already installed"
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
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-$releasever
metadata_expire=86400
countme=1
enabled_metadata=1
EOF

            echo "Devel repository configuration created."

            # Force metadata refresh
            echo "Refreshing repository metadata..."
            $SUDO dnf clean metadata
            $SUDO dnf makecache

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
    elif [[ -f /etc/redhat-release ]]; then
        # For other EL distros, try to install ncurses-static
        if ! rpm -q ncurses-static > /dev/null 2>&1; then
            echo "Installing ncurses-static..."
            $SUDO dnf install -y ncurses-static || echo "INFO: ncurses-static not available (may not be needed)"
        else
            echo "ncurses-static already installed"
        fi
    fi

    echo "Build prerequisites installation complete"
    echo ""
}

cleanup_build_directories() {
    echo ""
    echo "======================================================================"
    echo "Cleaning Up Build Directories"
    echo "======================================================================"

    # Source the config file to get INSTALLER_DIR
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/configs/rocm-ui.conf"

    BUILD_UI_DIR="$INSTALLER_DIR/build-UI"

    if [[ -d "$BUILD_UI_DIR" ]]; then
        echo "Removing build-UI directory: $BUILD_UI_DIR"
        rm -rf "$BUILD_UI_DIR"
        echo "Cleanup complete"
    else
        echo "Build-UI directory not found (already clean)"
    fi
}

echo "======================================================================"
echo "ROCm UI CodeQL Analysis"
echo "======================================================================"
echo ""

SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO="sudo"
echo SUDO: "$SUDO"

# Detect OS and validate AlmaLinux
os_release

echo "This will analyze the ROCm Installer UI using CodeQL."
echo "Working directory: $(pwd)"
echo ""

# Install prerequisites before running analysis
install_rocm_ui_prerequisites

# Run with rocm-ui config and capture exit code
"$SCRIPT_DIR/run-codeql-analysis.sh" --config "$SCRIPT_DIR/configs/rocm-ui.conf" "$@"
CODEQL_EXIT_CODE=$?

# Cleanup build directories after analysis (always run, even if analysis failed)
cleanup_build_directories

# Exit with the same code as the CodeQL analysis
exit $CODEQL_EXIT_CODE
