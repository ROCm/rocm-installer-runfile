#!/bin/bash

# #############################################################################
# ROCm Runfile Installer - Cleanup Script
#
# This script cleans up build artifacts and downloaded packages from the
# ROCm runfile installer build process.
#
# Directory Structure (for reference):
#   build-installer/        - Build scripts (setup-installer.sh, build-installer.sh)
#   package-puller/         - Package download scripts and downloaded packages
#   package-extractor/      - Downloaded packages (before extraction)
#   rocm-installer/         - Extracted components (after extraction)
#   build/                  - Final .run installer output
#   build-UI/               - UI build directory
#   build-config/           - Generated configuration files
# #############################################################################

# Get the directory where this script is located
OFFLINE_SELF_BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect if sudo is needed
SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO="sudo"
echo SUDO: "$SUDO"

# Parse arguments
CLEAN_SETUP=0
CLEAN_BUILD=0

usage() {
cat <<END_USAGE
Usage: $0 [options]

[options]:
    setup   = Clean only setup-installer artifacts (pulled packages)
    build   = Clean only build-installer artifacts (extracted components, build outputs)
    (no args) = Clean everything (default)

Examples:
    ./clean-setup.sh         # Clean everything
    ./clean-setup.sh setup   # Clean only pulled packages
    ./clean-setup.sh build   # Clean only build artifacts

END_USAGE
}

if [ "$#" -eq 0 ]; then
    # No arguments - clean everything
    CLEAN_SETUP=1
    CLEAN_BUILD=1
else
    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            setup)
                CLEAN_SETUP=1
                ;;
            build)
                CLEAN_BUILD=1
                ;;
            help|--help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $arg"
                usage
                exit 1
                ;;
        esac
    done
fi

echo =======================
if [ $CLEAN_SETUP -eq 1 ] && [ $CLEAN_BUILD -eq 1 ]; then
    echo "Cleaning up everything..."
elif [ $CLEAN_SETUP -eq 1 ]; then
    echo "Cleaning up setup artifacts..."
elif [ $CLEAN_BUILD -eq 1 ]; then
    echo "Cleaning up build artifacts..."
fi
echo =======================

pushd "$OFFLINE_SELF_BASE" || exit

###### Setup-related cleanup (pulled packages) ######
if [ $CLEAN_SETUP -eq 1 ]; then
    echo ""
    echo ">>> Cleaning setup artifacts..."

    if [ -d "package-puller/packages" ]; then
        echo -e "\e[93mRemoving: package-puller/packages\e[0m"
        $SUDO rm -r package-puller/packages
    fi

    if [ -d "package-puller/packages-repo" ]; then
        echo -e "\e[93mRemoving: package-puller/packages-repo\e[0m"
        $SUDO rm -r package-puller/packages-repo
    fi

    if [ -d "package-puller/logs" ]; then
        echo -e "\e[93mRemoving: package-puller/logs\e[0m"
        $SUDO rm -r package-puller/logs
    fi

    if [ -f "package-puller/epel-release-latest-10.noarch.rpm" ]; then
        echo -e "\e[93mRemoving: package-puller/epel-release-latest-10.noarch.rpm\e[0m"
        $SUDO rm package-puller/epel-release-latest-10.noarch.rpm*
    fi

    if [ -f "package-puller/epel-release-latest-9.noarch.rpm" ]; then
        echo -e "\e[93mRemoving: package-puller/epel-release-latest-9.noarch.rpm\e[0m"
        $SUDO rm package-puller/epel-release-latest-9.noarch.rpm*
    fi

    if [ -f "package-puller/epel-release-latest-8.noarch.rpm" ]; then
        echo -e "\e[93mRemoving: package-puller/epel-release-latest-8.noarch.rpm\e[0m"
        $SUDO rm package-puller/epel-release-latest-8.noarch.rpm*
    fi

    if [ -d "package-extractor/packages-amdgpu" ]; then
        echo -e "\e[93mRemoving: package-extractor/packages-amdgpu\e[0m"
        $SUDO rm -r package-extractor/packages-amdgpu
    fi

    # Remove all packages-amdgpu-* directories (distro-specific)
    for amdgpu_dir in package-extractor/packages-amdgpu-*; do
        if [ -d "$amdgpu_dir" ]; then
            echo -e "\e[93mRemoving: $amdgpu_dir\e[0m"
            $SUDO rm -r "$amdgpu_dir"
        fi
    done

    if [ -d "package-extractor/packages-rocm-deb" ]; then
        echo -e "\e[93mRemoving: package-extractor/packages-rocm-deb\e[0m"
        $SUDO rm -r package-extractor/packages-rocm-deb
    fi

    if [ -d "package-extractor/packages-rocm-rpm" ]; then
        echo -e "\e[93mRemoving: package-extractor/packages-rocm-rpm\e[0m"
        $SUDO rm -r package-extractor/packages-rocm-rpm
    fi

    if [ -d "build-config" ]; then
        echo -e "\e[93mRemoving: build-config\e[0m"
        $SUDO rm -r build-config
    fi

    if [ -d "package-puller/ubuntu-chroot" ]; then
        echo -e "\e[93mRemoving: package-puller/ubuntu-chroot\e[0m"
        $SUDO rm -r package-puller/ubuntu-chroot
    fi

    if [ -d "package-puller/package-repo-config" ]; then
        echo -e "\e[93mRemoving: package-puller/package-repo-config\e[0m"
        $SUDO rm -r package-puller/package-repo-config
    fi

    # Remove all packages-rocm-gfx* directories
    for gfx_dir in package-extractor/packages-rocm-gfx*; do
        if [ -d "$gfx_dir" ]; then
            echo -e "\e[93mRemoving: $gfx_dir\e[0m"
            $SUDO rm -r "$gfx_dir"
        fi
    done
fi

###### Build-related cleanup (extracted components, build outputs) ######
if [ $CLEAN_BUILD -eq 1 ]; then
    echo ""
    echo ">>> Cleaning build artifacts..."

    # Remove makeself installation in build-installer directory
    # Handle any version pattern: makeself-*
    for makeself_dir in build-installer/makeself-*; do
        if [ -d "$makeself_dir" ]; then
            echo -e "\e[93mRemoving: $makeself_dir\e[0m"
            $SUDO rm -r "$makeself_dir"
        fi
    done

    # Remove makeself .run installers in build-installer directory
    for makeself_run in build-installer/makeself-*.run; do
        if [ -f "$makeself_run" ]; then
            echo -e "\e[93mRemoving: $makeself_run\e[0m"
            $SUDO rm "$makeself_run"
        fi
    done

    # Remove VERSION file from root if it exists (shouldn't be there)
    if [ -f "VERSION" ]; then
        echo -e "\e[93mRemoving: VERSION (should only be in build-installer/)\e[0m"
        $SUDO rm VERSION
    fi

    if [ -d "build-UI" ]; then
        echo -e "\e[93mRemoving: build-UI\e[0m"
        $SUDO rm -r build-UI
    fi

    if [ -d "build" ]; then
        echo -e "\e[93mRemoving: build\e[0m"
        $SUDO rm -r build
    fi

    if [ -d "package-extractor/logs" ]; then
        echo -e "\e[93mRemoving: package-extractor/logs\e[0m"
        $SUDO rm -r package-extractor/logs
    fi
    
    if [ -f "rocm-installer/epel-release-latest-8.noarch.rpm" ]; then
        echo -e "\e[93mRemoving: rocm-installer/epel-release-latest-8.noarch.rpm\e[0m"
        $SUDO rm rocm-installer/epel-release-latest-8.noarch.rpm*
    fi

    if [ -f "rocm-installer/epel-release-latest-9.noarch.rpm" ]; then
        echo -e "\e[93mRemoving: rocm-installer/epel-release-latest-9.noarch.rpm\e[0m"
        $SUDO rm rocm-installer/epel-release-latest-9.noarch.rpm*
    fi

    if [ -f "rocm-installer/epel-release-latest-10.noarch.rpm" ]; then
        echo -e "\e[93mRemoving: rocm-installer/epel-release-latest-10.noarch.rpm\e[0m"
        $SUDO rm rocm-installer/epel-release-latest-10.noarch.rpm*
    fi
    
    if [ -d "rocm-installer/component-rocm" ]; then
        echo -e "\e[93mRemoving: rocm-installer/component-rocm\e[0m"
        $SUDO rm -r rocm-installer/component-rocm
    fi

    if [ -d "rocm-installer/component-rocm-deb" ]; then
        echo -e "\e[93mRemoving: rocm-installer/component-rocm-deb\e[0m"
        $SUDO rm -r rocm-installer/component-rocm-deb
    fi

    if [ -d "rocm-installer/component-amdgpu" ]; then
        echo -e "\e[93mRemoving: rocm-installer/component-amdgpu\e[0m"
        $SUDO rm -r rocm-installer/component-amdgpu
    fi

    # Remove all component-amdgpu-* directories (distro-specific)
    for amdgpu_dir in rocm-installer/component-amdgpu-*; do
        if [ -d "$amdgpu_dir" ]; then
            echo -e "\e[93mRemoving: $amdgpu_dir\e[0m"
            $SUDO rm -r "$amdgpu_dir"
        fi
    done

    # Remove all component-rocm-gfx* directories (old structure)
    for gfx_dir in rocm-installer/component-rocm-gfx*; do
        if [ -d "$gfx_dir" ]; then
            echo -e "\e[93mRemoving: $gfx_dir\e[0m"
            $SUDO rm -r "$gfx_dir"
        fi
    done

    # Remove compressed component archives (new on-demand extraction)
    echo -e "\e[93mRemoving compressed component archives...\e[0m"

    # Remove archives from component-rocm/ directory (new location)
    for archive in rocm-installer/component-rocm/content-*.tar.xz rocm-installer/component-rocm/content-*.tar.gz; do
        if [ -f "$archive" ]; then
            echo -e "\e[93mRemoving: $archive\e[0m"
            $SUDO rm "$archive"
        fi
    done

    if [ -f "rocm-installer/component-rocm/tests.tar.xz" ]; then
        echo -e "\e[93mRemoving: rocm-installer/component-rocm/tests.tar.xz\e[0m"
        $SUDO rm rocm-installer/component-rocm/tests.tar.xz
    fi

    # Remove archives from root rocm-installer/ directory (legacy locations)
    for archive in rocm-installer/content-*.tar.xz rocm-installer/content-*.tar.gz; do
        if [ -f "$archive" ]; then
            echo -e "\e[93mRemoving: $archive (legacy location)\e[0m"
            $SUDO rm "$archive"
        fi
    done

    # Clean AMDGPU content archive (new location: inside component-amdgpu directory)
    if [ -f "rocm-installer/component-amdgpu/content-amdgpu.tar.xz" ]; then
        echo -e "\e[93mRemoving: rocm-installer/component-amdgpu/content-amdgpu.tar.xz\e[0m"
        $SUDO rm rocm-installer/component-amdgpu/content-amdgpu.tar.xz
    fi

    # Clean legacy AMDGPU archive location (root level)
    if [ -f "rocm-installer/component-amdgpu.tar.xz" ]; then
        echo -e "\e[93mRemoving: rocm-installer/component-amdgpu.tar.xz (legacy location)\e[0m"
        $SUDO rm rocm-installer/component-amdgpu.tar.xz
    fi

    if [ -f "rocm-installer/component-rocm-deb.tar.xz" ]; then
        echo -e "\e[93mRemoving: rocm-installer/component-rocm-deb.tar.xz\e[0m"
        $SUDO rm rocm-installer/component-rocm-deb.tar.xz
    fi

    if [ -f "rocm-installer/tests.tar.xz" ]; then
        echo -e "\e[93mRemoving: rocm-installer/tests.tar.xz (legacy location)\e[0m"
        $SUDO rm rocm-installer/tests.tar.xz
    fi

    # Remove xz-static binary
    if [ -f "rocm-installer/bin/xz-static" ]; then
        echo -e "\e[93mRemoving: rocm-installer/bin/xz-static\e[0m"
        $SUDO rm rocm-installer/bin/xz-static
    fi

    if [ -d "rocm-installer/bin" ] && [ -z "$(ls -A rocm-installer/bin 2>/dev/null)" ]; then
        echo -e "\e[93mRemoving empty: rocm-installer/bin\e[0m"
        $SUDO rmdir rocm-installer/bin
    fi

    if [ -d "rocm-installer/logs" ]; then
        echo -e "\e[93mRemoving: rocm-installer/logs\e[0m"
        $SUDO rm -r rocm-installer/logs
    fi

    if [ -d "logs" ]; then
        echo -e "\e[93mRemoving: logs\e[0m"
        $SUDO rm -r logs
    fi

    # Note: VERSION file is copied from build-installer/VERSION to rocm-installer/VERSION during build
    if [ -f "rocm-installer/VERSION" ]; then
        echo -e "\e[93mRemoving: rocm-installer/VERSION\e[0m"
        $SUDO rm rocm-installer/VERSION
    fi

    if [ -f "rocm-installer/rocm_ui" ]; then
        echo -e "\e[93mRemoving: rocm-installer/rocm_ui\e[0m"
        $SUDO rm rocm-installer/rocm_ui
    fi

    if [ -d "rocm-installer/UI" ]; then
        echo -e "\e[93mRemoving: rocm-installer/UI\e[0m"
        $SUDO rm -r rocm-installer/UI
    fi

    if [ -f "rocm-installer/deps_list.txt" ]; then
        echo -e "\e[93mRemoving: rocm-installer/deps_list.txt\e[0m"
        $SUDO rm rocm-installer/deps_list.txt
    fi

    # Test-related artifacts (created during testing/build)
    if [ -d "rocm-installer/test-logs" ]; then
        echo -e "\e[93mRemoving: rocm-installer/test-logs\e[0m"
        $SUDO rm -r rocm-installer/test-logs
    fi

    if [ -d "test/rocm-examples" ]; then
        echo -e "\e[93mRemoving: test/rocm-examples\e[0m"
        $SUDO rm -r test/rocm-examples
    fi

    if [ -d "test/shaderc" ]; then
        echo -e "\e[93mRemoving: test/shaderc\e[0m"
        $SUDO rm -r test/shaderc
    fi

    if [ -d "test/glslang" ]; then
        echo -e "\e[93mRemoving: test/glslang\e[0m"
        $SUDO rm -r test/glslang
    fi

    if [ -d "test/rocdecode-test" ]; then
        echo -e "\e[93mRemoving: test/rocdecode-test\e[0m"
        $SUDO rm -r test/rocdecode-test
    fi

    if [ -d "test/build" ]; then
        echo -e "\e[93mRemoving: test/build\e[0m"
        $SUDO rm -r test/build
    fi

    if [ -d "test/CMakeFiles" ]; then
        echo -e "\e[93mRemoving: test/CMakeFiles\e[0m"
        $SUDO rm -r test/CMakeFiles
    fi

    # Clean temporary files in build-installer directory
    if [ -f "build-installer/CMakeCache.txt" ]; then
        echo -e "\e[93mRemoving: build-installer/CMakeCache.txt\e[0m"
        $SUDO rm build-installer/CMakeCache.txt
    fi

    if [ -d "build-installer/CMakeFiles" ]; then
        echo -e "\e[93mRemoving: build-installer/CMakeFiles\e[0m"
        $SUDO rm -r build-installer/CMakeFiles
    fi

    # Clean generated makeself headers (regenerated from .template files during build)
    if [ -f "build-installer/rocm-makeself-header.sh" ]; then
        echo -e "\e[93mRemoving: build-installer/rocm-makeself-header.sh (generated)\e[0m"
        $SUDO rm build-installer/rocm-makeself-header.sh
    fi

    if [ -f "build-installer/rocm-makeself-header-pre.sh" ]; then
        echo -e "\e[93mRemoving: build-installer/rocm-makeself-header-pre.sh (generated)\e[0m"
        $SUDO rm build-installer/rocm-makeself-header-pre.sh
    fi

    # Reset VERSION file based on cleanup mode
    # - Full clean (CLEAN_SETUP=1): Keep only line 1 (installer version)
    # - Build clean only: Keep lines 1-2 (installer version + ROCm version from setup)
    if [ -f "build-installer/VERSION" ]; then
        if [ $CLEAN_SETUP -eq 1 ]; then
            # Full clean - keep only installer version (line 1)
            echo -e "\e[93mResetting: build-installer/VERSION (keeping only installer version)\e[0m"
            INSTALLER_VERSION=$(sed -n '1p' build-installer/VERSION)
            echo "$INSTALLER_VERSION" > build-installer/VERSION
        else
            # Build-only clean - keep installer version and ROCm version (lines 1-2)
            # Lines 3-6 are written by build-installer.sh and should be cleared for rebuild
            echo -e "\e[93mResetting: build-installer/VERSION (keeping installer version and ROCm version)\e[0m"
            INSTALLER_VERSION=$(sed -n '1p' build-installer/VERSION)
            ROCM_VERSION=$(sed -n '2p' build-installer/VERSION)
            {
                echo "$INSTALLER_VERSION"
                echo "$ROCM_VERSION"
            } > build-installer/VERSION
        fi
    fi

    # Clean hybrid compression artifacts
    if [ -f "build-installer/tools/xz-static" ]; then
        echo -e "\e[93mRemoving: build-installer/tools/xz-static\e[0m"
        $SUDO rm build-installer/tools/xz-static
    fi

    if [ -f "build-installer/tools/xz-static-build-note.txt" ]; then
        echo -e "\e[93mRemoving: build-installer/tools/xz-static-build-note.txt\e[0m"
        $SUDO rm build-installer/tools/xz-static-build-note.txt
    fi

    # (tests.tar.xz already removed above in compressed component archives section)

    # Remove compressed components archives (both old and new names, both gzip and xz)
    if [ -f "rocm-installer/components.tar.gz" ]; then
        echo -e "\e[93mRemoving: rocm-installer/components.tar.gz\e[0m"
        $SUDO rm rocm-installer/components.tar.gz
    fi

    if [ -f "rocm-installer/components.tar.xz" ]; then
        echo -e "\e[93mRemoving: rocm-installer/components.tar.xz\e[0m"
        $SUDO rm rocm-installer/components.tar.xz
    fi

    # Remove embedded xz-static binary
    if [ -d "rocm-installer/bin" ]; then
        echo -e "\e[93mRemoving: rocm-installer/bin (xz-static)\e[0m"
        $SUDO rm -r rocm-installer/bin
    fi

    # Clean any leftover xz build directories from testing
    for xz_build_dir in /tmp/xz-static-build-*; do
        if [ -d "$xz_build_dir" ]; then
            echo -e "\e[93mRemoving: $xz_build_dir\e[0m"
            $SUDO rm -r "$xz_build_dir" 2>/dev/null || true
        fi
    done

    if [ -f "/tmp/xz-compression.log" ]; then
        echo -e "\e[93mRemoving: /tmp/xz-compression.log\e[0m"
        $SUDO rm /tmp/xz-compression.log 2>/dev/null || true
    fi
fi

popd || exit

echo ""
echo =======================
if [ $CLEAN_SETUP -eq 1 ] && [ $CLEAN_BUILD -eq 1 ]; then
    echo "Cleaning up...Complete"
elif [ $CLEAN_SETUP -eq 1 ]; then
    echo "Setup cleanup...Complete"
elif [ $CLEAN_BUILD -eq 1 ]; then
    echo "Build cleanup...Complete"
fi
echo =======================

