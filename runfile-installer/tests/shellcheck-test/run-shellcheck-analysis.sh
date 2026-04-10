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
#
# Generic ShellCheck Analysis Script
# Analyzes bash scripts in any directory with ShellCheck
# Can be run from anywhere on the system

set -e  # Exit on error

# Configuration defaults
SOURCE_DIR=""
WORK_DIR="$(pwd)"
PROJECT_NAME=""
EXCLUDE_PATTERNS=()
CONFIG_FILE=""
AUTO_INSTALL=true

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

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

usage() {
    cat << EOF
Generic ShellCheck Analysis Script

Usage: $0 [OPTIONS]

Options:
  --source <dir>         Source directory to scan for bash scripts (required)
  --name <name>          Project name for results (required)
  --config <file>        Load configuration from file
  --work-dir <dir>       Working directory for results (default: current dir)
  --exclude <pattern>    Exclude pattern (can be specified multiple times)
  --no-auto-install      Don't attempt to auto-install shellcheck/jq
  -h, --help             Show this help message

Config File Format:
  SOURCE_DIR="/path/to/source"
  PROJECT_NAME="myproject"
  WORK_DIR="/path/to/workdir"
  EXCLUDE_PATTERNS=("*/test/*" "*/.git/*" "*/build/*")
  AUTO_INSTALL=true

Examples:
  # Using command-line arguments
  $0 --source /path/to/scripts --name myproject

  # Using config file
  $0 --config configs/rocm-installer.conf

  # Mix both (args override config)
  $0 --config myconfig.conf --work-dir /tmp/shellcheck-work

  # With exclusions
  $0 --source /path/to/code --name myapp --exclude "*/build/*" --exclude "*/test/*"

Note: Script can be run from any directory on the system.
EOF
    exit 0
}

SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO="sudo"

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
        --name)
            PROJECT_NAME="$2"
            shift 2
            ;;
        --work-dir)
            WORK_DIR="$2"
            shift 2
            ;;
        --exclude)
            EXCLUDE_PATTERNS+=("$2")
            shift 2
            ;;
        --no-auto-install)
            AUTO_INSTALL=false
            shift
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

if [[ -z "$PROJECT_NAME" ]]; then
    print_error "Project name not specified (--name or config file)"
    usage
fi

# Resolve paths to absolute
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

# Set results directory
RESULTS_DIR="$WORK_DIR/shellcheck-results-$PROJECT_NAME"

# Display configuration
print_header "ShellCheck Analysis Configuration"
echo "Project Name:    $PROJECT_NAME"
echo "Source Dir:      $SOURCE_DIR"
echo "Work Directory:  $WORK_DIR"
echo "Results:         $RESULTS_DIR"
if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
    echo "Exclude Patterns:"
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        echo "  - $pattern"
    done
fi
echo

# Helper function to detect package manager
detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v zypper &> /dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

# Step 1: Check and install dependencies
print_header "Step 1: Checking Dependencies"

# Check for shellcheck
SHELLCHECK=""
if command -v shellcheck &> /dev/null; then
    SHELLCHECK="shellcheck"
    print_step "ShellCheck found: $SHELLCHECK"
elif [ -x "$HOME/bin/shellcheck" ]; then
    SHELLCHECK="$HOME/bin/shellcheck"
    print_step "ShellCheck found: $SHELLCHECK"
elif [ -x "/usr/local/bin/shellcheck" ]; then
    SHELLCHECK="/usr/local/bin/shellcheck"
    print_step "ShellCheck found: $SHELLCHECK"
else
    if [[ "$AUTO_INSTALL" = true ]]; then
        print_warning "ShellCheck not found. Attempting to install..."
        PKG_MGR=$(detect_package_manager)

        case $PKG_MGR in
            apt)
                print_step "Installing ShellCheck via apt..."
                $SUDO apt-get update -qq && $SUDO apt-get install -y shellcheck
                ;;
            dnf)
                print_step "Installing ShellCheck via dnf..."
                $SUDO dnf install -y ShellCheck
                ;;
            zypper)
                print_step "Installing ShellCheck via zypper..."
                $SUDO zypper install -y ShellCheck
                ;;
            *)
                print_error "Could not detect package manager."
                echo ""
                echo "Installation instructions:"
                echo "  Ubuntu/Debian:  sudo apt install shellcheck"
                echo "  RHEL/Rocky:     sudo dnf install ShellCheck"
                echo "  SLES:           sudo zypper install ShellCheck"
                echo ""
                exit 1
                ;;
        esac

        # Verify installation
        if command -v shellcheck &> /dev/null; then
            SHELLCHECK="shellcheck"
            print_step "ShellCheck successfully installed!"
        else
            print_error "ShellCheck installation failed"
            exit 1
        fi
    else
        print_error "ShellCheck not found (use --no-auto-install to disable auto-install)"
        exit 1
    fi
fi

$SHELLCHECK --version
echo ""

# Check for jq (required for CSV generation)
if ! command -v jq &> /dev/null; then
    if [[ "$AUTO_INSTALL" = true ]]; then
        print_warning "jq not found (required for CSV generation). Attempting to install..."
        PKG_MGR=$(detect_package_manager)

        case $PKG_MGR in
            apt)
                print_step "Installing jq via apt..."
                $SUDO apt-get update -qq && $SUDO apt-get install -y jq
                ;;
            dnf)
                print_step "Installing jq via dnf..."
                $SUDO dnf install -y jq
                ;;
            zypper)
                print_step "Installing jq via zypper..."
                $SUDO zypper install -y jq
                ;;
            *)
                print_warning "Could not detect package manager. CSV generation will be skipped."
                ;;
        esac

        # Verify installation
        if command -v jq &> /dev/null; then
            print_step "jq successfully installed!"
        else
            print_warning "jq installation failed. CSV generation will be skipped."
        fi
    else
        print_warning "jq not found. CSV generation will be skipped."
    fi
else
    print_step "jq found: $(command -v jq)"
fi

echo ""

# Step 2: Create results directory
print_header "Step 2: Setting Up Results Directory"
print_step "Creating results directory..."
mkdir -p "$RESULTS_DIR"
print_info "Results directory: $RESULTS_DIR"

# Step 3: Find bash scripts to analyze
print_header "Step 3: Finding Bash Scripts"
print_step "Scanning for bash scripts..."

# Build find command with exclusions
FIND_CMD="find \"$SOURCE_DIR\" -type f -name \"*.sh\""

# Add default exclusions
FIND_CMD="$FIND_CMD ! -path \"*/.git/*\" ! -path \"*/.*/*\""

# Add user-specified exclusions
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    FIND_CMD="$FIND_CMD ! -path \"$pattern\""
done

FIND_CMD="$FIND_CMD -print 2>/dev/null | sort"

# Execute find command and collect results
SCRIPT_LIST=()
while IFS= read -r script; do
    SCRIPT_LIST+=("$script")
done < <(eval "$FIND_CMD")

if [ ${#SCRIPT_LIST[@]} -eq 0 ]; then
    print_warning "No bash scripts found to analyze"
    exit 0
fi

print_info "Found ${#SCRIPT_LIST[@]} bash scripts to analyze:"
for script in "${SCRIPT_LIST[@]}"; do
    # Show relative path from source directory
    rel_path="${script#"$SOURCE_DIR"/}"
    echo "  - $rel_path"
done

# Step 4: Run ShellCheck analyses
print_header "Step 4: Running ShellCheck Analysis"

# Analysis 1: Human-readable format
print_step "Running ShellCheck analysis (text format)..."
{
    echo "ShellCheck Analysis Results"
    echo "============================"
    echo "Project: $PROJECT_NAME"
    echo "Generated: $(date)"
    echo "Scripts analyzed: ${#SCRIPT_LIST[@]}"
    echo ""
    echo "====================================================================="
    echo ""

    total_issues=0
    for script in "${SCRIPT_LIST[@]}"; do
        rel_path="${script#"$SOURCE_DIR"/}"
        echo "Analyzing: $rel_path"
        echo "-------------------------------------------------------------------"

        if $SHELLCHECK "$script" 2>&1; then
            echo "✓ No issues found"
        else
            ((total_issues++)) || true
        fi
        echo ""
    done

    echo "====================================================================="
    echo "Summary: Found issues in $total_issues script(s)"

} > "$RESULTS_DIR/shellcheck-results.txt"

print_info "Text results saved to $RESULTS_DIR/shellcheck-results.txt"

# Analysis 2: JSON format for detailed analysis
print_step "Running ShellCheck analysis (JSON format)..."
{
    echo "["
    first=true
    for script in "${SCRIPT_LIST[@]}"; do
        if [ "$first" = false ]; then
            echo ","
        fi
        first=false

        rel_path="${script#"$SOURCE_DIR"/}"
        echo "  {"
        echo "    \"file\": \"$rel_path\","
        echo "    \"results\": "
        $SHELLCHECK -f json "$script" 2>/dev/null || echo "[]"
        echo "  }"
    done
    echo ""
    echo "]"
} > "$RESULTS_DIR/shellcheck-results.json"

print_info "JSON results saved to $RESULTS_DIR/shellcheck-results.json"

# Analysis 3: CSV format for spreadsheet viewing
if command -v jq &> /dev/null; then
    print_step "Generating CSV report..."
    {
        echo "\"File\",\"Line\",\"Column\",\"Severity\",\"Code\",\"Message\""
        for script in "${SCRIPT_LIST[@]}"; do
            rel_path="${script#"$SOURCE_DIR"/}"
            $SHELLCHECK -f json "$script" 2>/dev/null | \
                jq -r --arg file "$rel_path" '.[] | [$file, .line, .column, .level, .code, .message] | @csv' 2>/dev/null || true
        done
    } > "$RESULTS_DIR/shellcheck-results.csv"

    print_info "CSV results saved to $RESULTS_DIR/shellcheck-results.csv"
else
    print_warning "jq not available, skipping CSV generation"
fi

# Step 5: Generate summary report
print_header "Step 5: Generating Summary Report"

{
    echo "ShellCheck Analysis Summary"
    echo "==========================="
    echo "Project: $PROJECT_NAME"
    echo "Generated: $(date)"
    echo ""
    echo "Scripts Analyzed: ${#SCRIPT_LIST[@]}"
    echo ""

    # Count issues by severity
    echo "Issues by Severity:"
    echo "-------------------"

    error_count=$(grep -c '"level":"error"' "$RESULTS_DIR/shellcheck-results.json" 2>/dev/null) || error_count=0
    warning_count=$(grep -c '"level":"warning"' "$RESULTS_DIR/shellcheck-results.json" 2>/dev/null) || warning_count=0
    info_count=$(grep -c '"level":"info"' "$RESULTS_DIR/shellcheck-results.json" 2>/dev/null) || info_count=0
    style_count=$(grep -c '"level":"style"' "$RESULTS_DIR/shellcheck-results.json" 2>/dev/null) || style_count=0

    echo "Errors:   $error_count"
    echo "Warnings: $warning_count"
    echo "Info:     $info_count"
    echo "Style:    $style_count"
    echo ""

    total=$(( error_count + warning_count + info_count + style_count ))
    echo "Total Issues: $total"
    echo ""

    # Top 10 most common issues
    if command -v jq &> /dev/null; then
        echo "Top Issues:"
        echo "-----------"
        jq -r '.[] | .results[] | .code' "$RESULTS_DIR/shellcheck-results.json" 2>/dev/null | \
            sort | uniq -c | sort -rn | head -10 | \
            awk '{printf "SC%s: %d occurrences\n", $2, $1}' || echo "No issues found"
        echo ""
    fi

    echo "Output Files:"
    echo "-------------"
    echo "- $RESULTS_DIR/shellcheck-results.txt  : Human-readable report"
    echo "- $RESULTS_DIR/shellcheck-results.json : JSON format for tools"
    if command -v jq &> /dev/null; then
        echo "- $RESULTS_DIR/shellcheck-results.csv  : CSV format for spreadsheets"
    fi
    echo "- $RESULTS_DIR/SUMMARY.txt             : This summary"
    echo ""

    echo "Next Steps:"
    echo "-----------"
    echo "1. Review issues in shellcheck-results.txt"
    if command -v jq &> /dev/null; then
        echo "2. Import CSV into spreadsheet for detailed analysis"
    fi
    echo "3. Fix errors and warnings"
    echo "4. Re-run analysis to verify fixes"
    echo ""

    echo "ShellCheck Documentation:"
    echo "-------------------------"
    echo "- https://www.shellcheck.net/"
    echo "- https://github.com/koalaman/shellcheck/wiki"

} > "$RESULTS_DIR/SUMMARY.txt"

print_info "Summary report saved to $RESULTS_DIR/SUMMARY.txt"

# Display summary
print_header "Analysis Complete!"
cat "$RESULTS_DIR/SUMMARY.txt"

print_header "Results Location"
print_info "All results saved to: $RESULTS_DIR/"
print_step "Review the following files:"
echo "  - shellcheck-results.txt  (human-readable)"
if command -v jq &> /dev/null; then
    echo "  - shellcheck-results.csv  (spreadsheet)"
fi
echo "  - shellcheck-results.json (JSON)"
echo "  - SUMMARY.txt             (summary)"

# Check for errors and warnings, set exit code
# Re-calculate counts (were calculated inside heredoc subshell)
error_count=$(grep -c '"level":"error"' "$RESULTS_DIR/shellcheck-results.json" 2>/dev/null) || error_count=0
warning_count=$(grep -c '"level":"warning"' "$RESULTS_DIR/shellcheck-results.json" 2>/dev/null) || warning_count=0

if [[ "$error_count" -gt 0 ]] || [[ "$warning_count" -gt 0 ]]; then
    echo ""
    if [[ "$error_count" -gt 0 ]] && [[ "$warning_count" -gt 0 ]]; then
        print_error "Analysis found $error_count error(s) and $warning_count warning(s)"
    elif [[ "$error_count" -gt 0 ]]; then
        print_error "Analysis found $error_count error(s)"
    else
        print_error "Analysis found $warning_count warning(s)"
    fi
    exit 1
fi

exit 0
