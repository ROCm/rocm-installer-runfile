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

# Component Extractor Helper
# Generic archive extraction utility for ROCm installer runtime

usage() {
cat <<END_USAGE
Usage: $0 <archive_file|extract-all> [output_dir] [installer_dir]

Extracts compressed tar archives (.tar.xz or .tar.gz) to a specified directory.
For .tar.xz files, uses the embedded xz-static binary for maximum compatibility.

Parameters:
  archive_file  - Archive to extract (.tar.xz or .tar.gz)
                  OR
                  "extract-all" to extract all component and test archives

  output_dir    - Optional: Directory to extract to (default: current directory)
  installer_dir - Optional: Override installer directory (default: script's directory)
                  Used to locate the xz-static binary at {installer_dir}/bin/xz-static

Supported Archive Types:
  .tar.xz       - XZ-compressed tar archive (requires xz-static)
  .tar.gz       - Gzip-compressed tar archive (uses standard tar)

Modes:
  Single file   - Extract one specific archive file
  extract-all   - Extract all component-rocm/content-*.tar.*,
                  component-amdgpu/content-*.tar.*, and tests.tar.* archives
                  Used for noexec mode to extract all on-demand content

Examples:
  $0 content-base.tar.xz
  $0 content-base.tar.xz /tmp/extract
  $0 content-base.tar.xz /tmp/extract /opt/rocm-installer
  $0 extract-all

EXIT STATUS:
  0   - Extraction successful
  1   - Error (missing file, unsupported type, or extraction failure)

END_USAGE
}

run_with_progress() {
    local message="$1"
    shift

    # Start progress indicator in background (write to stderr to avoid logs)
    (
        local i=0
        local spin='-\|/'
        while true; do
            i=$(( (i+1) %4 ))
            printf "\r[%c] %s " "${spin:$i:1}" "$message" >&2
            sleep 0.1
        done
    ) &
    local progress_pid=$!

    # Run the command and capture exit status
    "$@" 2>/dev/null
    local exit_status=$?

    # Cleanup progress indicator
    kill $progress_pid 2>/dev/null
    wait $progress_pid 2>/dev/null
    printf "\r" >&2

    return $exit_status
}

# Parse arguments
if [[ "$1" == "help" || "$1" == "--help" || "$1" == "-h" ]]; then
    usage
    exit 0
fi

# Set INSTALLER_DIR to script's directory by default
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

archive_file="$1"
output_dir="${2:-.}"
installer_dir_override="${3:-}"

# Override INSTALLER_DIR if provided as parameter
if [[ -n "$installer_dir_override" ]]; then
    INSTALLER_DIR="$installer_dir_override"
fi

if [[ -z "$archive_file" ]]; then
    echo -e "\e[31mERROR: Missing required argument\e[0m"
    echo ""
    usage
    exit 1
fi

# Handle extract-all mode (for noexec)
if [[ "$archive_file" == "extract-all" ]]; then
    echo "Extract-all mode: Extracting all component archives..."

    extracted_count=0
    failed_count=0

    # Extract ROCm compressed component archives
    if [[ -d "component-rocm" ]]; then
        for archive in component-rocm/content-*.tar.*; do
            if [[ -f "$archive" ]]; then
                if "$0" "$archive" "component-rocm/content" "$INSTALLER_DIR"; then
                    extracted_count=$((extracted_count + 1))
                else
                    failed_count=$((failed_count + 1))
                fi
            fi
        done
    fi

    # Extract AMDGPU compressed component archives
    if [[ -d "component-amdgpu" ]]; then
        for archive in component-amdgpu/content-*.tar.*; do
            if [[ -f "$archive" ]]; then
                if "$0" "$archive" "component-amdgpu/content" "$INSTALLER_DIR"; then
                    extracted_count=$((extracted_count + 1))
                else
                    failed_count=$((failed_count + 1))
                fi
            fi
        done
    fi

    # Extract tests archive if present (located in component-rocm/)
    # Note: tests.tar.xz contains paths like "component-rocm/content/gfx120x/...",
    # so extract to current directory (not component-rocm/)
    for test_archive in component-rocm/tests.tar.xz component-rocm/tests.tar.gz; do
        if [[ -f "$test_archive" ]]; then
            if "$0" "$test_archive" "." "$INSTALLER_DIR"; then
                extracted_count=$((extracted_count + 1))
            else
                failed_count=$((failed_count + 1))
            fi
        fi
    done

    echo ""
    echo "Extract-all complete: $extracted_count archive(s) extracted, $failed_count failed"

    if [[ $failed_count -gt 0 ]]; then
        exit 1
    fi
    exit 0
fi

if [[ ! -f "$archive_file" ]]; then
    echo -e "\e[31mERROR: Archive not found: $archive_file\e[0m"
    exit 1
fi

# Ensure output directory exists
mkdir -p "$output_dir"

# Detect archive type and extract
archive_name=$(basename "$archive_file")
echo "  Extracting: $archive_name"

success=0

if [[ "$archive_file" == *.tar.xz ]]; then
    # Use xz-static for .tar.xz archives
    if [[ -x "$INSTALLER_DIR/bin/xz-static" ]]; then
        if run_with_progress "Extracting $archive_name" \
           bash -c "\"$INSTALLER_DIR/bin/xz-static\" -dc \"$archive_file\" | tar -xf - -C \"$output_dir\""; then
            success=1
        fi
    else
        echo -e "\e[31mERROR: xz-static not found at $INSTALLER_DIR/bin/xz-static\e[0m"
        exit 1
    fi
elif [[ "$archive_file" == *.tar.gz ]]; then
    # Use tar with gzip for .tar.gz archives
    if run_with_progress "Extracting $archive_name" \
       tar -xzf "$archive_file" -C "$output_dir"; then
        success=1
    fi
else
    echo -e "\e[31mERROR: Unsupported archive type: $archive_file\e[0m"
    echo "Supported types: .tar.xz, .tar.gz"
    exit 1
fi

if [[ $success -eq 0 ]]; then
    echo -e "  \e[31mFailed to extract $archive_name\e[0m"
    exit 1
fi

# Clear any residual progress text before printing success message
printf "\r\033[K"
echo -e "  \e[32mExtracted : $archive_name\e[0m"
exit 0
