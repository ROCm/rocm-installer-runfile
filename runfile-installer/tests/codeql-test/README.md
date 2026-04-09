# Generic CodeQL Analysis Tool

A portable, generic CodeQL security and quality analysis tool that can analyze any C/C++ project from anywhere on the system.

## Features

- **Run from anywhere**: Works from any directory on your system
- **Portable**: Automatically adapts to different directory locations
- **Generic**: Analyze any C/C++ codebase, not just ROCm UI
- **Flexible configuration**: Use config files, command-line args, or both
- **Auto-download**: Automatically downloads CodeQL bundle if not present
- **Comprehensive analysis**: Runs security, quality, and custom query suites
- **Multiple output formats**: CSV, SARIF for IDE integration, and summary reports
- **Exit codes**: Returns 0 for success, 1 if errors found (CI/CD friendly)

## Quick Start

### Analyzing ROCm UI (Simplest Method)

```bash
cd /path/to/utils/codeql-test
./analyze-rocm-ui.sh
```

**Note:** This script is designed for AlmaLinux manylinux build environments only.

This automatically:
- Validates running on AlmaLinux
- Installs build prerequisites (ncurses-devel, ncurses-static)
- Dynamically finds the UI directory with C/C++ source files
- Runs the analysis
- Cleans up build artifacts
- Returns exit code (0=success, 1=errors found)

### Option 1: Using Config File (Recommended)

```bash
# From anywhere on your system:
/path/to/utils/codeql-test/run-codeql-analysis.sh --config /path/to/utils/codeql-test/configs/rocm-ui.conf

# Or create your own config:
cp /path/to/utils/codeql-test/configs/example.conf myproject.conf
# Edit myproject.conf with your settings
/path/to/utils/codeql-test/run-codeql-analysis.sh --config myproject.conf
```

### Option 2: Using Command-Line Arguments

```bash
/path/to/utils/codeql-test/run-codeql-analysis.sh \
    --source /path/to/source/code \
    --build-cmd "cd /path && make clean && make" \
    --name myproject
```

### Option 3: Mix Both (Args Override Config)

```bash
# Use config but override work directory
/path/to/utils/codeql-test/run-codeql-analysis.sh \
    --config configs/rocm-ui.conf \
    --work-dir /tmp/my-analysis
```

## Command-Line Options

```
--source <dir>         Source code directory to analyze (required)
--build-cmd <cmd>      Build command to trace (required)
--name <name>          Project name for database (required)
--config <file>        Load configuration from file
--work-dir <dir>       Working directory for outputs (default: current dir)
--bundle <file>        CodeQL bundle location (default: script-dir or auto-download)
--language <lang>      Language to analyze (default: cpp)
--query-suite <file>   Custom query suite file (optional)
-h, --help             Show this help message
```

## Portable Usage

The scripts work from any location and automatically find dependencies.

### Working with Different Directory Structures

The ROCm UI config dynamically locates the UI directory containing C/C++ source files, regardless of parent directory naming (e.g., `runfile-installer`, `runfile-installer`, etc.).

**Option 1: Automatic search (Default)**
The config searches upward from the codeql-test location to find a `UI` directory containing a `src` subdirectory with .c/.cpp files.

```bash
# Works from any location:
/path/to/codeql-test/analyze-rocm-ui.sh

# Examples that work:
# - /repo/runfile-installer/UI/src/*.c
# - /repo/runfile-installer/UI/src/*.c
# - /source/rocm-installer-runfile-internal/runfile-installer/UI/src/*.c
```

**Option 2: Use environment variable (Override)**
```bash
export ROCM_UI_DIR=/path/to/runfile-installer/UI
./analyze-rocm-ui.sh
```

**Option 3: Run from anywhere**
```bash
# Set the UI location
export ROCM_UI_DIR=/path/to/UI

# Run from anywhere
/path/to/utils/codeql-test/analyze-rocm-ui.sh
```

### Directory Structure Detection

The `rocm-ui.conf` automatically:
1. Checks `ROCM_INSTALLER_DIR` environment variable
2. Tries relative path from repository root
3. Searches for the directory if not found
4. Validates the directory contains required UI subdirectory
5. Shows clear error if directory cannot be found

## Configuration File Format

```bash
# Required parameters
SOURCE_DIR="/path/to/source"
BUILD_CMD="cd /path && make clean && make"
PROJECT_NAME="myproject"

# Optional parameters
WORK_DIR="/tmp/codeql-work"
LANGUAGE="cpp"
CUSTOM_QUERY_FILE="/path/to/queries.qls"
CODEQL_BUNDLE="/path/to/codeql-bundle-linux64.tar.gz"
```

## Examples

### Example 1: Analyze ROCm UI

```bash
# Using the provided config
cd /home/amd/offline-self
utils/codeql-test/run-codeql-analysis.sh --config utils/codeql-test/configs/rocm-ui.conf

# Results will be in: ./codeql-results-rocm-ui/
```

### Example 2: Analyze a Makefile Project

```bash
# Create config file
cat > myproject.conf << 'EOF'
SOURCE_DIR="/home/user/myproject/src"
BUILD_CMD="cd /home/user/myproject && make clean && make"
PROJECT_NAME="myproject"
WORK_DIR="/tmp/codeql-myproject"
EOF

# Run analysis
/path/to/utils/codeql-test/run-codeql-analysis.sh --config myproject.conf

# Results will be in: /tmp/codeql-myproject/codeql-results-myproject/
```

### Example 3: Analyze a CMake Project

```bash
/path/to/utils/codeql-test/run-codeql-analysis.sh \
    --source /home/user/cmakeapp/src \
    --build-cmd "cd /home/user/cmakeapp/build && cmake .. && make clean && make" \
    --name cmakeapp \
    --work-dir /tmp/codeql-work
```

### Example 4: Using AMD Custom Query Suite

The ROCm UI configuration uses the AMD Must-Fix query suite by default:

```bash
# AMD Must-Fix queries are included automatically with rocm-ui.conf
cd /home/amd/offline-self/utils/codeql-test
./analyze-rocm-ui.sh
```

The AMD Must-Fix suite (`suites/amd-cpp-must-fix.qls`) includes critical checks for:
- **Must-Fix 1.0**: Arithmetic overflows, pointer issues, type conversions
- **Must-Fix 2.0**: Buffer overflows, cleartext storage, OpenSSL vulnerabilities
- **Must-Fix 3.0**: Resource leaks, NULL pointer dereferences, uncontrolled allocations

### Example 5: Using Custom Query Suite

```bash
/path/to/utils/codeql-test/run-codeql-analysis.sh \
    --source /home/user/app/src \
    --build-cmd "cd /home/user/app && make" \
    --name myapp \
    --query-suite /path/to/custom-queries.qls
```

## Output Files

After analysis completes, results are saved to `codeql-results-<project-name>/`:

- **security-and-quality.csv**: Complete security and quality analysis
- **security.csv**: Security-focused analysis
- **custom-queries.csv**: Results from AMD Must-Fix query suite (if enabled)
- **results.sarif**: SARIF format for IDE integration (VS Code, etc.)
- **SUMMARY.txt**: Summary report with issue counts and top findings

### Custom Query Suite Results

When using the AMD Must-Fix suite (or any custom suite), the `custom-queries.csv` file contains results from your custom queries. These are separate from the standard CodeQL security and quality queries, allowing you to focus on AMD-specific or project-specific concerns.

## Cleanup

Clean up analysis artifacts while preserving source code:

```bash
# Clean current directory
/path/to/utils/codeql-test/cleanup.sh

# Clean specific directory
/path/to/utils/codeql-test/cleanup.sh --work-dir /tmp/codeql-work

# Remove everything including CodeQL installation
/path/to/utils/codeql-test/cleanup.sh --all

# Keep the CodeQL bundle (don't prompt)
/path/to/utils/codeql-test/cleanup.sh --keep-bundle
```

## Directory Structure

```
utils/codeql-test/
├── run-codeql-analysis.sh    # Main analysis script
├── analyze-rocm-ui.sh         # ROCm UI quick-start wrapper
├── cleanup.sh                 # Cleanup script
├── configs/
│   ├── rocm-ui.conf          # ROCm UI configuration
│   └── example.conf          # Template configuration
├── suites/
│   └── amd-cpp-must-fix.qls  # AMD custom query suite
└── README.md                 # This file
```

## Working Directory Structure

When you run an analysis, the following structure is created in the work directory:

```
<work-dir>/
├── codeql/                        # CodeQL installation (extracted from bundle)
├── codeql-db-<project-name>/      # CodeQL database for your project
├── codeql-results-<project-name>/ # Analysis results
│   ├── security-and-quality.csv
│   ├── security.csv
│   ├── results.sarif
│   └── SUMMARY.txt
├── codeql-build-<project-name>.sh # Build script (generated)
└── codeql-bundle-linux64.tar.gz   # CodeQL bundle (if downloaded here)
```

## Requirements

- **Operating System**: Linux (tested on Ubuntu, RHEL-based distros)
- **Disk Space**: ~2-3 GB for CodeQL bundle and installation
- **Network**: Required for first-time download of CodeQL bundle
- **Build Tools**: Whatever your project needs (make, cmake, gcc, etc.)

## Exit Codes and CI/CD Integration

The analysis scripts return meaningful exit codes for automation:

- **Exit 0**: Analysis completed successfully with no errors found
- **Exit 1**: Analysis found security errors (severity: "error")

Build artifacts are always cleaned up before exit, regardless of the analysis result.

### CI/CD Example

```bash
# Run analysis and fail build if errors found
./analyze-rocm-ui.sh

# The exit code will be 1 if CodeQL finds errors
# You can also check results directly:
if grep -q '"error"' codeql-results-rocm-ui/security-and-quality.csv; then
    echo "Security errors detected!"
    exit 1
fi
```

### What Triggers Exit Code 1

The script counts **errors** (not warnings or recommendations) in:
- `security-and-quality.csv`
- `security.csv`
- `custom-queries.csv` (if custom query suite is used)

Any line containing `"error"` severity increments the error count. If the total is greater than 0, the script exits with code 1.

## Tips and Best Practices

1. **Reuse CodeQL Bundle**: Keep the bundle file (~800MB) and reuse it across projects
2. **Separate Work Directories**: Use `--work-dir` to keep analyses separate
3. **Config Files**: Store config files in your project repository for repeatability
4. **Build Commands**: Ensure build command does a clean build for accurate analysis
5. **CI/CD Integration**: Use exit codes to fail builds when security errors are detected
6. **Custom Queries**: Create project-specific query suites for focused analysis (optional)

## Understanding CodeQL Analysis

### What CodeQL Detects

CodeQL uses **taint tracking** and **data flow analysis** to find security vulnerabilities. It traces how untrusted data flows through your program.

**Untrusted/Tainted Input Sources** that CodeQL tracks:
- `getenv()` - Environment variables
- Command-line arguments (`argc`, `argv`)
- File input (`fread()`, `fgets()`, etc.)
- Network input (`recv()`, `read()` from sockets)
- User input functions (`scanf()`, `gets()`, etc.)

**What CodeQL May NOT Flag:**
- Buffers with application-defined constants (menu items, string literals)
- Internal data structures with validated bounds
- Dead code that's optimized away by the compiler

CodeQL analyzes the **compiled intermediate representation (IR)**, not raw source code, so:
- Optimized-out code won't be analyzed
- It sees what actually executes, not what's written
- Compiler optimizations affect what CodeQL can detect

### Example: What Gets Detected

```c
// ✅ DETECTED - Tainted input from environment
char buffer[10];
strcpy(buffer, getenv("USER"));  // Buffer overflow!

// ❌ NOT DETECTED - Application-defined constant
char buffer[10];
strcpy(buffer, "MI325X/MI300X");  // CodeQL knows this is safe constant data
```

## Troubleshooting

### "CodeQL executable not found"
- Ensure bundle is downloaded and extracted
- Check permissions on extracted files

### "Build command failed"
- Test your build command independently first
- Ensure all build dependencies are installed
- Use absolute paths in build commands

### "No source files found"
- Verify SOURCE_DIR points to actual source code
- Check that build command successfully compiles code

### "CodeQL found 0 errors but I expected issues"
- Check if the vulnerable code path is actually executed
- Verify the input source is considered "tainted" by CodeQL (use `getenv()`, file I/O, etc.)
- Dead code or optimized-out code won't be analyzed
- Review the SARIF output for warnings or recommendations (not just errors)

## Advanced Usage

### Custom Query Suites

#### Using the AMD Must-Fix Suite

The AMD Must-Fix query suite is automatically enabled for ROCm UI analysis. To use it for other projects:

```bash
# Copy the example config and enable AMD suite
cp configs/example.conf myproject.conf

# Edit myproject.conf and add:
# CUSTOM_QUERY_FILE="$CODEQL_TEST_DIR/suites/amd-cpp-must-fix.qls"

./run-codeql-analysis.sh --config myproject.conf
```

#### Creating Your Own Query Suite

Create a `.qls` file in the `suites/` directory:

```bash
# Create a new query suite
cat > suites/my-critical-checks.qls << 'EOF'
# My Critical Security Checks
- query: Critical/UseAfterFree.ql
- query: Critical/DoubleFree.ql
- query: Security/CWE/CWE-078/ExecTainted.ql
- query: Security/CWE/CWE-089/SqlTainted.ql
EOF

# Use it in your config
CUSTOM_QUERY_FILE="$CODEQL_TEST_DIR/suites/my-critical-checks.qls"
```

Query suite files use relative paths from the CodeQL query pack. Browse available queries in:
- `codeql/qlpacks/codeql/cpp-queries/<version>/`

#### Managing Multiple Suites

Store different suites for different purposes:

```
suites/
├── amd-cpp-must-fix.qls      # AMD critical checks
├── security-only.qls          # Security-focused queries
├── performance.qls            # Performance issues
└── code-quality.qls           # Code quality checks
```

### Using with Different Languages

```bash
# JavaScript/TypeScript project
run-codeql-analysis.sh \
    --source /path/to/js/src \
    --build-cmd "npm install && npm run build" \
    --name myapp \
    --language javascript
```

### Custom CodeQL Bundle Location

```bash
# Specify bundle location (useful for offline environments)
run-codeql-analysis.sh \
    --source /path/to/src \
    --build-cmd "make" \
    --name myproject \
    --bundle /shared/codeql-bundle-linux64.tar.gz
```

### IDE Integration (VS Code)

1. Install SARIF Viewer extension: `code --install-extension MS-SarifVSCode.sarif-viewer`
2. Run analysis to generate results.sarif
3. Open Command Palette (Ctrl+Shift+P)
4. Type "SARIF: Open SARIF file" and select your results.sarif
5. See inline warnings and navigate directly to issues

## Understanding SARIF Output

### What is SARIF?

**SARIF** (Static Analysis Results Interchange Format) is a standardized JSON format for static analysis results. Think of it as a universal report card for your code that any tool can read.

### Why SARIF Matters

**The Problem**: Different analysis tools have different output formats
- CodeQL → CSV files
- ESLint → Custom JSON
- SonarQube → XML format
- Your IDE can't understand them

**The Solution**: SARIF is a universal standard
- One format for all static analysis results
- Works with any IDE (VS Code, IntelliJ, etc.)
- Integrates with GitHub, GitLab, CI/CD pipelines
- Enables cross-tool comparison

### What's in a SARIF File?

Each issue in the SARIF file contains:

1. **Tool Information**: What found the issue (CodeQL, version, etc.)
2. **Location**: Exact file, line, and column
3. **Issue Details**: Type, severity, description
4. **Fix Suggestions**: How to resolve the problem
5. **Context**: Code snippets, documentation links

### Example SARIF Entry

```json
{
  "ruleId": "cpp/local-variable-address-stored",
  "level": "warning",
  "message": {
    "text": "A stack address may be assigned to a non-local variable."
  },
  "locations": [{
    "physicalLocation": {
      "artifactLocation": {
        "uri": "src/myfile.c"
      },
      "region": {
        "startLine": 417,
        "startColumn": 5
      }
    }
  }]
}
```

### Using SARIF Files

**In VS Code:**
```bash
# Install SARIF Viewer extension
code --install-extension MS-SarifVSCode.sarif-viewer

# Open your results
# Ctrl+Shift+P → "SARIF: Open SARIF file" → select results.sarif
```

**On Command Line:**
```bash
# View all issues
jq '.runs[0].results[] | {file: .locations[0].physicalLocation.artifactLocation.uri, line: .locations[0].physicalLocation.region.startLine, message: .message.text}' results.sarif

# Count issues by severity
jq '.runs[0].results | group_by(.level) | map({level: .[0].level, count: length})' results.sarif

# Find critical issues only
jq '.runs[0].results[] | select(.level=="error")' results.sarif
```

**In CI/CD Pipeline:**
```bash
# Run CodeQL analysis
./run-codeql-analysis.sh --config myproject.conf

# Check for critical issues (fail build if found)
if jq -e '.runs[0].results[] | select(.level=="error")' results.sarif >/dev/null 2>&1; then
    echo "Build failed: Critical security issues found!"
    exit 1
fi
```

**On GitHub:**
1. Go to repository → Security tab
2. Click "Code scanning alerts"
3. Upload your `results.sarif` file
4. Get automated security alerts on pull requests

### SARIF vs CSV

**CSV Output** (`security-and-quality.csv`):
- ✅ Easy to read in Excel/LibreOffice
- ✅ Good for reports and sharing with non-technical users
- ✅ Simple grep/search
- ❌ No IDE integration
- ❌ Limited context

**SARIF Output** (`results.sarif`):
- ✅ IDE integration (inline warnings)
- ✅ GitHub/GitLab integration
- ✅ Automated CI/CD checking
- ✅ Rich context (code snippets, documentation links)
- ❌ JSON format harder to read directly

**Best Practice**: Use both formats
- CSV for manual review and reports
- SARIF for automation and tooling

### Severity Levels

| Level | Meaning | Typical Action |
|-------|---------|----------------|
| `error` | Critical security issue | Must fix before release |
| `warning` | Important issue | Should fix, review required |
| `note` | Information or minor issue | Good to address |
| `recommendation` | Code quality improvement | Nice to have |

### Your CodeQL Results

After running analysis, you get:

```
codeql-results-<project>/
├── security-and-quality.csv   # Human-readable (Excel, spreadsheet)
├── security.csv               # Security-focused analysis
├── custom-queries.csv         # Custom query results (if used)
├── results.sarif             # Machine-readable (IDE, GitHub, CI/CD)
└── SUMMARY.txt               # Quick overview with counts
```

## Links

- [CodeQL Documentation](https://codeql.github.com/docs/)
- [CodeQL Query Reference](https://codeql.github.com/codeql-query-help/)
- [GitHub CodeQL](https://github.com/github/codeql)
- [SARIF Specification](https://sarifweb.azurewebsites.net/)
- [SARIF Tutorials](https://github.com/microsoft/sarif-tutorials)
- [VS Code SARIF Viewer](https://marketplace.visualstudio.com/items?itemName=MS-SarifVSCode.sarif-viewer)

## License

Copyright (C) 2024-2026 Advanced Micro Devices, Inc. All rights reserved.
