# Generic ShellCheck Analysis Tool

A portable, generic ShellCheck analysis tool that can analyze bash scripts in any directory from anywhere on the system.

## Features

- **Run from anywhere**: Works from any directory on your system
- **Generic**: Analyze any bash script directory, not just ROCm Installer
- **Flexible configuration**: Use config files, command-line args, or both
- **Auto-install**: Automatically installs shellcheck and jq if not present
- **Comprehensive output**: Text, JSON, and CSV formats
- **Pattern exclusions**: Skip test directories, build artifacts, etc.

## Quick Start

### Analyzing ROCm Installer (Simplest Method)

```bash
cd /path/to/runfile-installer/tests/shellcheck-test
./analyze-runfile-installer.sh
```

This automatically:
- Dynamically finds the runfile-installer directory
- Analyzes all bash scripts in the installer
- Generates comprehensive results
- Returns exit code (0=success, non-zero=issues found)

### Option 1: Using Config File

```bash
# From anywhere on your system:
/path/to/shellcheck-test/run-shellcheck-analysis.sh --config /path/to/shellcheck-test/configs/rocm-installer.conf

# Or create your own config:
cp /path/to/shellcheck-test/configs/example.conf myproject.conf
# Edit myproject.conf with your settings
/path/to/shellcheck-test/run-shellcheck-analysis.sh --config myproject.conf
```

### Option 2: Using Command-Line Arguments

```bash
/path/to/utils/shellcheck-test/run-shellcheck-analysis.sh \
    --source /path/to/scripts \
    --name myproject
```

### Option 3: Mix Both (Args Override Config)

```bash
# Use config but override work directory
/path/to/utils/shellcheck-test/run-shellcheck-analysis.sh \
    --config configs/rocm-installer.conf \
    --work-dir /tmp/my-analysis
```

## Command-Line Options

```
--source <dir>         Source directory to scan for bash scripts (required)
--name <name>          Project name for results (required)
--config <file>        Load configuration from file
--work-dir <dir>       Working directory for results (default: current dir)
--exclude <pattern>    Exclude pattern (can be specified multiple times)
--no-auto-install      Don't attempt to auto-install shellcheck/jq
-h, --help             Show help message
```

## Configuration File Format

```bash
# Required parameters
SOURCE_DIR="/path/to/scripts"
PROJECT_NAME="myproject"

# Optional parameters
WORK_DIR="/tmp/shellcheck-work"
EXCLUDE_PATTERNS=("*/test/*" "*/build/*" "*/.git/*")
AUTO_INSTALL=true
```

## Examples

### Example 1: Analyze ROCm Installer

```bash
# Using the quick-start script (automatic detection)
cd /path/to/runfile-installer/tests/shellcheck-test
./analyze-runfile-installer.sh

# Or specify installer location with environment variable
export RUNFILE_INSTALLER_DIR=/path/to/runfile-installer
./analyze-runfile-installer.sh

# Results will be in: ./shellcheck-results-rocm-installer/
```

### Example 2: Analyze Custom Script Directory

```bash
# Create config file
cat > myscripts.conf << 'EOF'
SOURCE_DIR="/home/user/myscripts"
PROJECT_NAME="myscripts"
WORK_DIR="/tmp/shellcheck-myscripts"
EXCLUDE_PATTERNS=("*/backup/*" "*/old/*")
EOF

# Run analysis
/path/to/utils/shellcheck-test/run-shellcheck-analysis.sh --config myscripts.conf

# Results will be in: /tmp/shellcheck-myscripts/shellcheck-results-myscripts/
```

### Example 3: Ad-hoc Analysis with Exclusions

```bash
/path/to/utils/shellcheck-test/run-shellcheck-analysis.sh \
    --source /usr/local/bin \
    --name system-scripts \
    --exclude "*/backup/*" \
    --exclude "*/deprecated/*" \
    --work-dir /tmp/system-check
```

## Output Files

After analysis completes, results are saved to `shellcheck-results-<project-name>/`:

- **shellcheck-results.txt**: Human-readable report with all issues
- **shellcheck-results.json**: JSON format for tools and automation
- **shellcheck-results.csv**: CSV format for spreadsheet analysis (requires jq)
- **SUMMARY.txt**: Summary report with issue counts and top problems

## Cleanup

Clean up analysis results:

```bash
# Clean current directory
/path/to/utils/shellcheck-test/cleanup.sh

# Clean specific directory
/path/to/utils/shellcheck-test/cleanup.sh --work-dir /tmp/shellcheck-work
```

## Exit Codes and CI/CD Integration

The analysis script returns exit codes suitable for CI/CD pipelines:

- **Exit 0**: No errors or warnings found (success)
  - Info and style issues are allowed
  - Safe to deploy/continue pipeline

- **Exit 1**: One or more errors or warnings found (failure)
  - Errors: Critical issues (syntax errors, parsing failures)
  - Warnings: Potential bugs or bad practices
  - Pipeline should fail
  - Review and fix issues before proceeding

**Example CI/CD Usage:**
```bash
# Run analysis - exits with 1 if errors found
./analyze-runfile-installer.sh || exit 1

# Or capture exit code
./analyze-runfile-installer.sh
if [ $? -ne 0 ]; then
    echo "ShellCheck found errors - aborting build"
    exit 1
fi
```

## Understanding ShellCheck Severity Levels

| Level | Meaning | Exit Code Impact | Action |
|-------|---------|------------------|--------|
| `error` | Syntax error or critical issue | Triggers exit 1 | Must fix |
| `warning` | Potential bug or bad practice | Triggers exit 1 | Must fix |
| `info` | Suggestion for improvement | No impact | Consider fixing |
| `style` | Stylistic issue | No impact | Nice to fix |

## Common ShellCheck Issues

### SC2086: Quote to prevent splitting
```bash
# Bad
rm $file

# Good
rm "$file"
```

### SC2046: Quote to prevent word splitting
```bash
# Bad
for file in $(ls *.txt); do

# Good
for file in *.txt; do
```

### SC2154: Variable is referenced but not assigned
```bash
# Usually means you forgot to define it or there's a typo
echo "$MYVAR"  # Did you mean $MY_VAR?
```

## Troubleshooting

### "ShellCheck not found"
- Script will attempt auto-install if AUTO_INSTALL=true
- Manual install: `sudo apt install shellcheck` (Ubuntu/Debian)
- Or use `--no-auto-install` to disable auto-install

### "jq not found - CSV generation skipped"
- CSV is optional, JSON and text results still generated
- Install jq for CSV: `sudo apt install jq`

### "No bash scripts found"
- Verify SOURCE_DIR points to correct location
- Check your EXCLUDE_PATTERNS aren't too broad
- Ensure scripts have `.sh` extension

## Requirements

- **Operating System**: Linux (tested on Ubuntu, RHEL-based distros)
- **ShellCheck**: Will auto-install if not present
- **jq**: Optional, for CSV generation (will auto-install if not present)

## Directory Structure

```
runfile-installer/tests/shellcheck-test/
├── run-shellcheck-analysis.sh    # Main analysis script
├── cleanup.sh                     # Cleanup script
├── analyze-runfile-installer.sh     # Quick-start wrapper for installer
├── configs/
│   ├── rocm-installer.conf       # ROCm Installer configuration
│   └── example.conf              # Template configuration
└── README.md                     # This file
```

## Portable Usage

The scripts work from any location and automatically find the runfile-installer directory.

### Working with Different Directory Structures

The ROCm Installer config dynamically locates the runfile-installer directory, regardless of where shellcheck-test is located.

**Option 1: Automatic search (Default)**
The config searches upward from the shellcheck-test location to find a `runfile-installer` directory containing `build-installer` and `rocm-installer` subdirectories.

```bash
# Works from any location:
/path/to/shellcheck-test/analyze-runfile-installer.sh

# Examples that work:
# - /repo/runfile-installer/tests/shellcheck-test
# - /source/my-installer/runfile-installer/tests/shellcheck-test
```

**Option 2: Use environment variable (Override)**
```bash
export RUNFILE_INSTALLER_DIR=/path/to/runfile-installer
./analyze-runfile-installer.sh
```

## Working Directory Structure

When you run an analysis, the following structure is created in the work directory:

```
<work-dir>/
└── shellcheck-results-<project-name>/
    ├── shellcheck-results.txt
    ├── shellcheck-results.json
    ├── shellcheck-results.csv
    └── SUMMARY.txt
```

## Tips and Best Practices

1. **Exclude test directories**: Use `EXCLUDE_PATTERNS` to skip test scripts
2. **Regular analysis**: Run shellcheck as part of your development workflow
3. **Fix errors first**: Address `error` level issues before `warning` or `style`
4. **Learn from issues**: ShellCheck provides explanations - click the SC codes for details
5. **Config files in repos**: Store config files in your project for repeatability

## Links

- [ShellCheck Homepage](https://www.shellcheck.net/)
- [ShellCheck Wiki](https://github.com/koalaman/shellcheck/wiki)
- [ShellCheck Gallery of Bad Code](https://github.com/koalaman/shellcheck#user-content-gallery-of-bad-code)
- [ShellCheck Online](https://www.shellcheck.net/) - Test scripts in your browser

## License

Copyright (C) 2024-2026 Advanced Micro Devices, Inc. All rights reserved.
