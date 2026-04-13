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

# Component Compressor Helper
# Generic directory compression utility for ROCm installer build process

usage() {
cat <<END_USAGE
Usage: $0 <source_dir> <output_archive> [compression_type] [xz_level] [hybrid_all_xz]

Compresses a directory into a tar archive using the specified compression method.

Parameters:
  source_dir       - Directory to compress (relative or absolute path)
  output_archive   - Output archive filename (e.g., "content-base.tar.xz")
  compression_type - Optional: "xz", "pigz", or "auto" (default: auto)
                     "auto" uses hybrid_all_xz parameter to decide
  xz_level         - Optional: XZ compression level 1-9 (default: 9)
  hybrid_all_xz    - Optional: "yes" or "no" (default: no)
                     Used when compression_type is "auto"
                     If "yes", auto selects xz; otherwise selects pigz

Examples:
  $0 component-rocm/content/base component-rocm/content-base.tar.xz
  $0 component-rocm/content/base component-rocm/content-base.tar.xz xz 9
  $0 component-rocm/content/base component-rocm/content-base.tar.xz auto 9 yes

END_USAGE
}

show_compression_progress() {
    local archive_file=$1

    # Wait for archive file to be created
    while [[ ! -f "$archive_file" ]]; do
        sleep 0.5
    done

    # Show immediate feedback that compression has started
    printf "\r\033[K  Compressing..."

    local last_size=0
    local shown_initial=false

    # Loop until killed by parent process
    while true; do
        if [[ -f "$archive_file" ]]; then
            local current_size
            current_size=$(stat -c%s "$archive_file" 2>/dev/null || stat -f%z "$archive_file" 2>/dev/null || echo 0)

            local current_kb=$((current_size / 1024))

            # Show size as soon as we have any data
            if [[ $current_kb -gt 0 ]]; then
                if [[ $current_kb -ne $last_size ]]; then
                    printf "\r\033[K  Compressed: %s" "$(format_size "$current_size")"
                    last_size=$current_kb
                    shown_initial=true
                fi
            elif [[ "$shown_initial" == "false" ]]; then
                # Keep showing "Compressing..." while waiting for first data
                printf "\r\033[K  Compressing..."
            fi
        fi
        sleep 1
    done
}

format_size() {
    local bytes=$1
    local kb=$((bytes / 1024))
    local mb=$((kb / 1024))
    local gb=$((mb / 1024))

    if [[ $gb -gt 0 ]]; then
        echo "${gb}.$(( (mb * 10 / 1024) % 10 )) GB"
    elif [[ $mb -gt 0 ]]; then
        echo "${mb} MB"
    else
        echo "${kb} KB"
    fi
}

format_duration() {
    local duration=$1
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    echo "${hours}h ${minutes}m ${seconds}s (${duration} seconds)"
}

# Parse arguments
if [[ "$1" == "help" || "$1" == "--help" || "$1" == "-h" ]]; then
    usage
    exit 0
fi

source_dir="$1"
output_archive="$2"
compression_type="${3:-auto}"
xz_level="${4:-9}"
hybrid_all_xz="${5:-no}"

if [[ -z "$source_dir" || -z "$output_archive" ]]; then
    echo -e "\e[31mERROR: Missing required arguments\e[0m"
    echo ""
    usage
    exit 1
fi

if [[ ! -d "$source_dir" ]]; then
    echo -e "\e[31mERROR: Source directory not found: $source_dir\e[0m"
    exit 1
fi

# Auto-detect compression type if requested
if [[ "$compression_type" == "auto" ]]; then
    if [[ "$hybrid_all_xz" == "yes" ]]; then
        compression_type="xz"
    else
        compression_type="pigz"
    fi
fi

# Calculate source size
source_size_kb=$(du -sk "$source_dir" 2>/dev/null | awk '{print $1}')

echo "  Source: $source_dir ($(format_size $((source_size_kb * 1024))))"
echo "  Target: $output_archive"
echo "  Method: $compression_type (level: $xz_level)"

start_time=$(date +%s)

# Start progress monitor in background
show_compression_progress "$output_archive" &
progress_pid=$!

# Ensure progress monitor is killed on exit
trap 'kill $progress_pid 2>/dev/null; wait $progress_pid 2>/dev/null' EXIT INT TERM

success=0

if [[ "$compression_type" == "xz" ]]; then
    if tar -cf - -C "$(dirname "$source_dir")" "$(basename "$source_dir")" 2>/dev/null | \
       xz "-$xz_level" -T"$(nproc)" --verbose 2>/tmp/compress-xz.log > "$output_archive"; then
        success=1
    fi
else
    # Use pigz or fallback to gzip
    if command -v pigz &> /dev/null; then
        if tar -cf - -C "$(dirname "$source_dir")" "$(basename "$source_dir")" 2>/dev/null | \
           pigz -6 -p "$(nproc)" > "$output_archive"; then
            success=1
        fi
    else
        if tar -czf "$output_archive" -C "$(dirname "$source_dir")" "$(basename "$source_dir")" 2>/dev/null; then
            success=1
        fi
    fi
fi

# Stop progress monitor
kill $progress_pid 2>/dev/null
wait $progress_pid 2>/dev/null
trap - EXIT INT TERM

if [[ $success -eq 0 ]]; then
    echo ""
    echo -e "  \e[31mFailed to compress $source_dir\e[0m"
    exit 1
fi

# Update with final size to match the summary line
final_size=$(stat -c%s "$output_archive" 2>/dev/null || stat -f%z "$output_archive" 2>/dev/null || echo 0)
printf "\r\033[K  Compressed: %s\n" "$(format_size "$final_size")"

end_time=$(date +%s)
duration=$((end_time - start_time))

# Verify archive was created
if [[ ! -f "$output_archive" || ! -s "$output_archive" ]]; then
    echo -e "  \e[31mArchive creation failed or is empty\e[0m"
    exit 1
fi

# Calculate compression stats
archive_size_kb=$(du -k "$output_archive" | awk '{print $1}')

ratio=$((source_size_kb / archive_size_kb))
reduction=$(( 100 - (archive_size_kb * 100 / source_size_kb) ))

echo -e "  \e[32mCompressed: $(format_size $((archive_size_kb * 1024))) (${ratio}:1, ${reduction}%) in \e[36m$(format_duration "$duration")\e[0m"

exit 0
