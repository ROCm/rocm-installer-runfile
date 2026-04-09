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

# Quick-start script for analyzing runfile installer scripts
# This is a convenience wrapper that uses the rocm-installer.conf
# Automatically finds and analyzes the runfile-installer directory

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================================================"
echo "Runfile Installer ShellCheck Analysis"
echo "======================================================================"
echo ""
echo "This will analyze all bash scripts in the runfile installer."
echo "The runfile-installer directory will be automatically detected."
echo "Working directory: $(pwd)"
echo ""

# Run with rocm-installer config and capture exit code
"$SCRIPT_DIR/run-shellcheck-analysis.sh" --config "$SCRIPT_DIR/configs/rocm-installer.conf" "$@"
SHELLCHECK_EXIT_CODE=$?

# Exit with the same code as the ShellCheck analysis
exit $SHELLCHECK_EXIT_CODE
