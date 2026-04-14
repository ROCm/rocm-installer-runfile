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
# ###########################################################################
#
# Generic CodeQL Cleanup Script
# Cleans up CodeQL databases, results, and temporary files
# Can be run from any directory

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
Generic CodeQL Cleanup Script

Usage: $0 [OPTIONS]

Options:
  --work-dir <dir>    Working directory to clean (default: current directory)
  --keep-bundle       Keep the CodeQL bundle file (default: prompt)
  -h, --help          Show this help message

What gets cleaned:
  - CodeQL databases (codeql-db-*)
  - Analysis results (codeql-results-*)
  - Build scripts (codeql-build-*.sh)
  - CodeQL installation (codeql/)
  - CodeQL bundle (codeql-bundle-linux64.tar.gz) - optional, will prompt

EOF
    exit 0
}

# Parse arguments
KEEP_BUNDLE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --work-dir)
            WORK_DIR="$2"
            shift 2
            ;;
        --keep-bundle)
            KEEP_BUNDLE="yes"
            shift
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

print_header "CodeQL Cleanup Script"
echo "Working directory: $WORK_DIR"
echo

CLEANED_COUNT=0

# Clean CodeQL databases
print_info "Searching for CodeQL databases..."
for db_dir in codeql-db-*; do
    if [[ -d "$db_dir" ]]; then
        print_info "Removing database: $db_dir"
        rm -rf "$db_dir"
        print_success "Database removed: $db_dir"
        ((CLEANED_COUNT++))
    fi
done

# Clean results directories
print_info "Searching for result directories..."
for results_dir in codeql-results-*; do
    if [[ -d "$results_dir" ]]; then
        print_info "Removing results: $results_dir"
        rm -rf "$results_dir"
        print_success "Results removed: $results_dir"
        ((CLEANED_COUNT++))
    fi
done

# Clean build scripts
print_info "Searching for build scripts..."
for build_script in codeql-build-*.sh; do
    if [[ -f "$build_script" ]]; then
        print_info "Removing build script: $build_script"
        rm -f "$build_script"
        print_success "Build script removed: $build_script"
        ((CLEANED_COUNT++))
    fi
done

# Clean CodeQL installation (extracted from bundle)
if [[ -d "codeql" ]]; then
    print_info "Removing CodeQL installation..."
    rm -rf codeql
    print_success "CodeQL installation removed"
    ((CLEANED_COUNT++))
else
    print_info "No CodeQL installation found"
fi

# Remove CodeQL bundle
echo
if [[ -f "codeql-bundle-linux64.tar.gz" ]]; then
    BUNDLE_SIZE=$(du -h codeql-bundle-linux64.tar.gz | cut -f1)

    if [[ "$KEEP_BUNDLE" = "yes" ]]; then
        print_info "Keeping CodeQL bundle (--keep-bundle specified)"
        BUNDLE_REMOVED=false
    else
        print_info "Removing CodeQL bundle ($BUNDLE_SIZE)..."
        rm -f codeql-bundle-linux64.tar.gz
        print_success "CodeQL bundle removed"
        BUNDLE_REMOVED=true
        ((CLEANED_COUNT++))
    fi
else
    print_info "No CodeQL bundle found in work directory"
    BUNDLE_REMOVED=false
fi

echo
print_header "Cleanup Complete!"
echo

if [[ $CLEANED_COUNT -eq 0 ]]; then
    echo "No CodeQL files found to clean."
else
    echo "Cleaned $CLEANED_COUNT item(s)."
fi

echo
echo "The following items were preserved:"
echo "  ✓ Source code"
if [[ "$BUNDLE_REMOVED" = false ]] && [[ -f "codeql-bundle-linux64.tar.gz" ]]; then
    echo "  ✓ CodeQL bundle (codeql-bundle-linux64.tar.gz)"
fi
echo

if [[ "$BUNDLE_REMOVED" = true ]] || [[ ! -f "codeql-bundle-linux64.tar.gz" ]]; then
    echo "To download a fresh CodeQL bundle:"
    echo "  wget https://github.com/github/codeql-action/releases/latest/download/codeql-bundle-linux64.tar.gz"
    echo
fi
