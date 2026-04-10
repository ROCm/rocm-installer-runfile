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

# Get current working directory
WORK_DIR="$(pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${YELLOW}[CLEANUP]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_header() {
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}=================================================${NC}"
}

usage() {
    cat << EOF
Generic ShellCheck Cleanup Script

Usage: $0 [OPTIONS]

Options:
  --work-dir <dir>    Working directory to clean (default: current directory)
  -h, --help          Show this help message

What gets cleaned:
  - ShellCheck results (shellcheck-results-*)

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --work-dir)
            WORK_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Verify work directory exists
if [[ ! -d "$WORK_DIR" ]]; then
    echo -e "${RED}ERROR:${NC} Work directory not found: $WORK_DIR"
    exit 1
fi

cd "$WORK_DIR" || exit

print_header "ShellCheck Cleanup Script"
echo "Working directory: $WORK_DIR"
echo

print_info "Cleaning up ShellCheck results (shellcheck-results-*)"
echo

CLEANED_COUNT=0

# Clean ShellCheck results
print_info "Searching for ShellCheck results..."
for results_dir in shellcheck-results-*; do
    if [[ -d "$results_dir" ]]; then
        print_info "Removing results: $results_dir"
        rm -rf "$results_dir"
        print_success "Results removed: $results_dir"
        ((CLEANED_COUNT++))
    fi
done

echo
print_header "Cleanup Complete!"
echo

if [[ $CLEANED_COUNT -eq 0 ]]; then
    echo "No ShellCheck results found to clean."
else
    echo "Cleaned $CLEANED_COUNT item(s)."
fi

echo
echo "The following items were preserved:"
echo "  ✓ Source code"
echo
