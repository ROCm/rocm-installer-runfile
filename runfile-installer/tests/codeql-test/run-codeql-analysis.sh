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

# Generic CodeQL Analysis Script
# Analyzes any C/C++ project with CodeQL security and quality checks
# Can be run from anywhere on the system

set -e  # Exit on error

# Get the script directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration defaults
CODEQL_BUNDLE=""
CODEQL_DIR=""
CODEQL_DB=""
RESULTS_DIR=""
WORK_DIR="$(pwd)"
SOURCE_DIR=""
BUILD_CMD=""
PROJECT_NAME=""
LANGUAGE="cpp"
CUSTOM_QUERY_FILE=""
CONFIG_FILE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo -e "${BLUE}===================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}===================================================================${NC}"
}

print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat << EOF
Generic CodeQL Analysis Script

Usage: $0 [OPTIONS]

Options:
  --source <dir>         Source code directory to analyze (required)
  --build-cmd <cmd>      Build command to trace (required)
  --name <name>          Project name for database (required)
  --config <file>        Load configuration from file
  --work-dir <dir>       Working directory for outputs (default: current dir)
  --bundle <file>        CodeQL bundle location (default: script-dir or auto-download)
  --language <lang>      Language to analyze (default: cpp)
  --query-suite <file>   Custom query suite file (optional)
  -h, --help             Show this help message

Config File Format:
  SOURCE_DIR="/path/to/source"
  BUILD_CMD="cd /path && make"
  PROJECT_NAME="myproject"
  WORK_DIR="/path/to/workdir"
  LANGUAGE="cpp"
  CUSTOM_QUERY_FILE="/path/to/queries.qls"
  CODEQL_BUNDLE="/path/to/bundle.tar.gz"

Examples:
  # Using command-line arguments
  $0 --source /path/to/src --build-cmd "make" --name myproject

  # Using config file
  $0 --config configs/rocm-ui.conf

  # Mix both (args override config)
  $0 --config myconfig.conf --work-dir /tmp/codeql-work

Note: Script can be run from any directory on the system.
EOF
    exit 0
}

# Save original arguments before first pass
ORIGINAL_ARGS=("$@")

# Parse arguments first to check for config file
while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Load config file if specified
if [[ -n "$CONFIG_FILE" ]]; then
    # Resolve relative config paths from current directory
    if [[ ! "$CONFIG_FILE" = /* ]]; then
        CONFIG_FILE="$(pwd)/$CONFIG_FILE"
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    print_info "Loading configuration from: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Restore arguments for second pass
set -- "${ORIGINAL_ARGS[@]}"

# Re-parse arguments to override config values
OPTIND=1
while [[ $# -gt 0 ]]; do
    case $1 in
        --source)
            SOURCE_DIR="$2"
            shift 2
            ;;
        --build-cmd)
            BUILD_CMD="$2"
            shift 2
            ;;
        --name)
            PROJECT_NAME="$2"
            shift 2
            ;;
        --work-dir)
            WORK_DIR="$2"
            shift 2
            ;;
        --bundle)
            CODEQL_BUNDLE="$2"
            shift 2
            ;;
        --language)
            LANGUAGE="$2"
            shift 2
            ;;
        --query-suite)
            CUSTOM_QUERY_FILE="$2"
            shift 2
            ;;
        --config)
            # Already handled in first pass
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$SOURCE_DIR" ]]; then
    print_error "Source directory not specified (--source or config file)"
    usage
fi

if [[ -z "$BUILD_CMD" ]]; then
    print_error "Build command not specified (--build-cmd or config file)"
    usage
fi

if [[ -z "$PROJECT_NAME" ]]; then
    print_error "Project name not specified (--name or config file)"
    usage
fi

# Resolve all paths to absolute
if [[ ! "$SOURCE_DIR" = /* ]]; then
    SOURCE_DIR="$(cd "$(dirname "$SOURCE_DIR")" && pwd)/$(basename "$SOURCE_DIR")"
fi

if [[ ! "$WORK_DIR" = /* ]]; then
    WORK_DIR="$(cd "$WORK_DIR" && pwd)"
fi

# Verify source directory exists
if [[ ! -d "$SOURCE_DIR" ]]; then
    print_error "Source directory not found: $SOURCE_DIR"
    exit 1
fi

# Create work directory if needed
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Set derived paths
CODEQL_DIR="$WORK_DIR/codeql"
CODEQL_DB="$WORK_DIR/codeql-db-$PROJECT_NAME"
RESULTS_DIR="$WORK_DIR/codeql-results-$PROJECT_NAME"

# Determine CodeQL bundle location
if [[ -z "$CODEQL_BUNDLE" ]]; then
    # Check script directory first
    if [[ -f "$SCRIPT_DIR/codeql-bundle-linux64.tar.gz" ]]; then
        CODEQL_BUNDLE="$SCRIPT_DIR/codeql-bundle-linux64.tar.gz"
    else
        CODEQL_BUNDLE="$WORK_DIR/codeql-bundle-linux64.tar.gz"
    fi
elif [[ ! "$CODEQL_BUNDLE" = /* ]]; then
    # Resolve relative bundle path
    CODEQL_BUNDLE="$(pwd)/$CODEQL_BUNDLE"
fi

# Custom query suite path resolution
if [[ -n "$CUSTOM_QUERY_FILE" ]]; then
    if [[ ! "$CUSTOM_QUERY_FILE" = /* ]]; then
        # Try script directory first
        if [[ -f "$SCRIPT_DIR/$CUSTOM_QUERY_FILE" ]]; then
            CUSTOM_QUERY_FILE="$SCRIPT_DIR/$CUSTOM_QUERY_FILE"
        else
            CUSTOM_QUERY_FILE="$(pwd)/$CUSTOM_QUERY_FILE"
        fi
    fi
fi

# Display configuration
print_header "CodeQL Analysis Configuration"
echo "Project Name:    $PROJECT_NAME"
echo "Source Dir:      $SOURCE_DIR"
echo "Build Command:   $BUILD_CMD"
echo "Language:        $LANGUAGE"
echo "Work Directory:  $WORK_DIR"
echo "CodeQL Bundle:   $CODEQL_BUNDLE"
echo "Database:        $CODEQL_DB"
echo "Results:         $RESULTS_DIR"
if [[ -n "$CUSTOM_QUERY_FILE" ]]; then
    echo "Custom Queries:  $CUSTOM_QUERY_FILE"
fi
echo

# Step 1: Download CodeQL bundle if needed
print_header "Step 1: Checking/Downloading CodeQL Bundle"

if [[ ! -f "$CODEQL_BUNDLE" ]]; then
    print_info "CodeQL bundle not found: $CODEQL_BUNDLE"
    print_step "Downloading latest CodeQL bundle from GitHub..."

    CODEQL_DOWNLOAD_URL="https://github.com/github/codeql-action/releases/latest/download/codeql-bundle-linux64.tar.gz"

    print_info "Download URL: $CODEQL_DOWNLOAD_URL"
    print_info "This may take several minutes (bundle is ~820MB)..."

    if command -v wget &> /dev/null; then
        wget -O "$CODEQL_BUNDLE" "$CODEQL_DOWNLOAD_URL"
    elif command -v curl &> /dev/null; then
        curl -L -o "$CODEQL_BUNDLE" "$CODEQL_DOWNLOAD_URL"
    else
        print_error "Neither wget nor curl is available"
        print_info "Please install wget or curl, or manually download:"
        print_info "  URL: $CODEQL_DOWNLOAD_URL"
        print_info "  Save as: $CODEQL_BUNDLE"
        exit 1
    fi

    if [[ ! -f "$CODEQL_BUNDLE" ]]; then
        print_error "Download failed"
        exit 1
    fi

    print_info "Download complete: $(du -h "$CODEQL_BUNDLE" | cut -f1)"
else
    print_info "CodeQL bundle found: $CODEQL_BUNDLE ($(du -h "$CODEQL_BUNDLE" | cut -f1))"
fi

# Step 2: Extract CodeQL bundle
print_header "Step 2: Extracting CodeQL Bundle"
if [[ -d "$CODEQL_DIR" ]]; then
    print_info "CodeQL directory already exists, skipping extraction"
else
    print_step "Extracting $(basename "$CODEQL_BUNDLE")..."
    tar -xzf "$CODEQL_BUNDLE" -C "$WORK_DIR"
    print_info "CodeQL extracted to $CODEQL_DIR/"
fi

# Verify CodeQL installation
if [[ ! -x "$CODEQL_DIR/codeql" ]]; then
    print_error "CodeQL executable not found at $CODEQL_DIR/codeql"
    exit 1
fi

# Display CodeQL version
print_step "Checking CodeQL version..."
"$CODEQL_DIR/codeql" --version

# Install custom query suite if available
CUSTOM_QUERY_INSTALL_DIR=""
if [[ -n "$CUSTOM_QUERY_FILE" ]] && [[ -f "$CUSTOM_QUERY_FILE" ]]; then
    print_step "Installing custom query suite: $(basename "$CUSTOM_QUERY_FILE")"

    # Find cpp-queries directory (version may vary)
    CUSTOM_QUERY_INSTALL_DIR=$(find "$CODEQL_DIR/qlpacks/codeql" -type d -name "codeql-suites" | grep cpp-queries | head -1)

    if [[ -n "$CUSTOM_QUERY_INSTALL_DIR" ]]; then
        cp "$CUSTOM_QUERY_FILE" "$CUSTOM_QUERY_INSTALL_DIR/"
        print_info "Custom query suite installed to: $CUSTOM_QUERY_INSTALL_DIR"
    else
        print_error "CodeQL cpp-queries directory not found"
        print_info "Custom queries will not be available"
    fi
fi

# Step 3: Create build script
print_header "Step 3: Preparing Build Script"
BUILD_SCRIPT="$WORK_DIR/codeql-build-$PROJECT_NAME.sh"

print_step "Creating build script..."
cat > "$BUILD_SCRIPT" << EOF
#!/bin/bash
set -e
# CodeQL build script for $PROJECT_NAME
$BUILD_CMD
EOF
chmod +x "$BUILD_SCRIPT"
print_info "Build script created: $BUILD_SCRIPT"

# Step 4: Clean old database
print_header "Step 4: Cleaning Previous Analysis"
if [[ -d "$CODEQL_DB" ]]; then
    print_step "Removing old CodeQL database..."
    rm -rf "$CODEQL_DB"
fi

# Step 5: Create CodeQL database
print_header "Step 5: Creating CodeQL Database"
print_step "Building project and extracting database..."
print_info "This will compile the source code and trace the build"

"$CODEQL_DIR/codeql" database create "$CODEQL_DB" \
    --language="$LANGUAGE" \
    --source-root="$SOURCE_DIR" \
    --command="$BUILD_SCRIPT" \
    --overwrite

print_info "CodeQL database created successfully"

# Step 6: Create results directory
print_step "Creating results directory..."
mkdir -p "$RESULTS_DIR"

# Step 7: Run CodeQL analyses
print_header "Step 7: Running CodeQL Analyses"

# Find query suites dynamically
CPP_QUERIES_DIR=$(find "$CODEQL_DIR" -type d -path "*/cpp-queries/*/codeql-suites" | head -1)

if [[ -z "$CPP_QUERIES_DIR" ]]; then
    print_error "Could not find cpp-queries suites directory"
    exit 1
fi

# Analysis 1: Security and Quality queries
print_step "Running security and quality analysis..."
"$CODEQL_DIR/codeql" database analyze "$CODEQL_DB" \
    --format=csv \
    --output="$RESULTS_DIR/security-and-quality.csv" \
    -- "$CPP_QUERIES_DIR/cpp-security-and-quality.qls"

print_info "Results saved to $RESULTS_DIR/security-and-quality.csv"

# Analysis 2: Security-only queries
print_step "Running security analysis..."
"$CODEQL_DIR/codeql" database analyze "$CODEQL_DB" \
    --format=csv \
    --output="$RESULTS_DIR/security.csv" \
    -- "$CPP_QUERIES_DIR/cpp-security-extended.qls"

print_info "Results saved to $RESULTS_DIR/security.csv"

# Analysis 3: Custom queries (if available)
CUSTOM_QUERY_INSTALLED="$CUSTOM_QUERY_INSTALL_DIR/$(basename "$CUSTOM_QUERY_FILE")"
if [[ -n "$CUSTOM_QUERY_FILE" ]] && [[ -f "$CUSTOM_QUERY_INSTALLED" ]]; then
    print_step "Running custom query analysis..."
    "$CODEQL_DIR/codeql" database analyze "$CODEQL_DB" \
        --format=csv \
        --output="$RESULTS_DIR/custom-queries.csv" \
        -- "$CUSTOM_QUERY_INSTALLED"

    print_info "Custom query results saved to $RESULTS_DIR/custom-queries.csv"
fi

# Analysis 4: SARIF format for IDE integration
print_step "Generating SARIF output for IDE integration..."
"$CODEQL_DIR/codeql" database analyze "$CODEQL_DB" \
    --format=sarif-latest \
    --output="$RESULTS_DIR/results.sarif" \
    -- "$CPP_QUERIES_DIR/cpp-security-and-quality.qls"

print_info "SARIF results saved to $RESULTS_DIR/results.sarif"

# Step 8: Generate summary report
print_header "Step 8: Generating Summary Report"

cat > "$RESULTS_DIR/SUMMARY.txt" << EOF
CodeQL Analysis Summary
=======================
Generated: $(date)
Project: $PROJECT_NAME
Database: $CODEQL_DB
Source: $SOURCE_DIR
Language: $LANGUAGE

Files Analyzed:
EOF

# List source files based on language
case "$LANGUAGE" in
    cpp)
        find "$SOURCE_DIR" -name "*.c" -o -name "*.cpp" -o -name "*.h" -o -name "*.hpp" | sort >> "$RESULTS_DIR/SUMMARY.txt"
        ;;
    *)
        echo "See database for file list" >> "$RESULTS_DIR/SUMMARY.txt"
        ;;
esac

cat >> "$RESULTS_DIR/SUMMARY.txt" << EOF

Analysis Results:
-----------------

Security and Quality Issues:

Errors:
EOF

if [[ -f "$RESULTS_DIR/security-and-quality.csv" ]]; then
    grep -c '"error"' "$RESULTS_DIR/security-and-quality.csv" >> "$RESULTS_DIR/SUMMARY.txt" 2>/dev/null || echo "0" >> "$RESULTS_DIR/SUMMARY.txt"

    {
        echo ""
        echo "Warnings:"
    } >> "$RESULTS_DIR/SUMMARY.txt"

    grep -c '"warning"' "$RESULTS_DIR/security-and-quality.csv" >> "$RESULTS_DIR/SUMMARY.txt" 2>/dev/null || echo "0" >> "$RESULTS_DIR/SUMMARY.txt"

    {
        echo ""
        echo "Recommendations:"
    } >> "$RESULTS_DIR/SUMMARY.txt"

    grep -c '"recommendation"' "$RESULTS_DIR/security-and-quality.csv" >> "$RESULTS_DIR/SUMMARY.txt" 2>/dev/null || echo "0" >> "$RESULTS_DIR/SUMMARY.txt"

    {
        echo ""
        echo "Top Issues:"
        echo "------------"
    } >> "$RESULTS_DIR/SUMMARY.txt"

    grep -E '"warning"|"error"' "$RESULTS_DIR/security-and-quality.csv" | \
        cut -d',' -f1 | sort | uniq -c | sort -rn | head -10 >> "$RESULTS_DIR/SUMMARY.txt" 2>/dev/null || true
fi

cat >> "$RESULTS_DIR/SUMMARY.txt" << EOF

Output Files:
-------------
- $RESULTS_DIR/security-and-quality.csv : Complete security and quality analysis
- $RESULTS_DIR/security.csv             : Security-focused analysis
EOF

if [[ -f "$RESULTS_DIR/custom-queries.csv" ]]; then
    echo "- $RESULTS_DIR/custom-queries.csv       : Custom query results" >> "$RESULTS_DIR/SUMMARY.txt"
fi

cat >> "$RESULTS_DIR/SUMMARY.txt" << EOF
- $RESULTS_DIR/results.sarif            : SARIF format for IDE integration
- $RESULTS_DIR/SUMMARY.txt              : This summary report

Next Steps:
-----------
1. Review CSV files for detailed findings
2. Import SARIF file into VS Code or other IDE for inline warnings
3. Prioritize fixing 'error' and 'warning' severity issues
4. Address 'recommendation' items for code quality improvements

For more information:
  CodeQL Database: $CODEQL_DB
  CodeQL CLI: $CODEQL_DIR/codeql

EOF

print_info "Summary report saved to $RESULTS_DIR/SUMMARY.txt"

# Display summary
print_header "Analysis Complete!"
cat "$RESULTS_DIR/SUMMARY.txt"

print_header "Results Location"
print_info "All results saved to: $RESULTS_DIR/"
print_step "Review the following files:"
echo "  - security-and-quality.csv (main results)"
echo "  - security.csv (security-focused)"
if [[ -f "$RESULTS_DIR/custom-queries.csv" ]]; then
    echo "  - custom-queries.csv (custom queries)"
fi
echo "  - results.sarif (IDE integration)"
echo "  - SUMMARY.txt (summary report)"

# Check for errors in all CSV files and set exit code
TOTAL_ERROR_COUNT=0

for csv_file in "$RESULTS_DIR"/*.csv; do
    if [[ -f "$csv_file" ]]; then
        # Count errors and ensure we get a clean numeric value
        FILE_ERROR_COUNT=$(grep -c '"error"' "$csv_file" 2>/dev/null || echo "0")
        # Strip any whitespace/newlines and ensure it's a number
        FILE_ERROR_COUNT=$(echo "$FILE_ERROR_COUNT" | tr -d '\n\r' | grep -o '[0-9]*' | head -1)
        # Default to 0 if empty
        FILE_ERROR_COUNT=${FILE_ERROR_COUNT:-0}

        TOTAL_ERROR_COUNT=$((TOTAL_ERROR_COUNT + FILE_ERROR_COUNT))

        if [[ "$FILE_ERROR_COUNT" -gt 0 ]]; then
            print_info "Found $FILE_ERROR_COUNT error(s) in $(basename "$csv_file")"
        fi
    fi
done

if [[ "$TOTAL_ERROR_COUNT" -gt 0 ]]; then
    echo ""
    print_error "Analysis found $TOTAL_ERROR_COUNT total error(s) across all results"
    exit 1
fi

exit 0
