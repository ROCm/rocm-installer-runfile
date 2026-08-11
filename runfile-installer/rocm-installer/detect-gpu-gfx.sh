#!/bin/bash
#
# detect-gpu-gfx.sh - AMD GPU GFX Architecture Detection Script
#
# This script detects the GFX architecture of AMD GPUs and maps them to
# ROCm package groups for use with the ROCm installer.
#
# Installer Type Detection:
#   - Single-arch installers: Returns coarse families (gfx110x, gfx94x, etc.)
#   - Multi-arch installers: Returns fine-grained archs (gfx1101, gfx942, etc.)
#
# Supported ROCm Package Groups (Single-Arch):
#   gfx908  - MI100 (CDNA1)
#   gfx90a  - MI210, MI250, MI250X (CDNA2)
#   gfx94x  - MI300A, MI300X, MI308X, MI325X (CDNA3)
#   gfx950  - MI350, MI355, MI358 (CDNA4)
#   gfx101x - RX 5000 series (RDNA1)
#   gfx103x - RX 6000 series (RDNA2)
#   gfx110x - RX 7900/7800/7700/7600, Ryzen 7000 APU (RDNA3)
#   gfx115x - Ryzen AI 300/Max series (RDNA3.5)
#   gfx120x - RX 9070 series (RDNA4)
#
# Supported Fine-Grained Archs (Multi-Arch):
#   gfx900, gfx906 (Vega), gfx908 (MI100), gfx90a (MI250/MI210), gfx90c
#   gfx942 (MI300), gfx950 (MI350+)
#   gfx1010, gfx1011, gfx1012 (RDNA1)
#   gfx1030-gfx1036 (RDNA2)
#   gfx1100-gfx1103 (RDNA3)
#   gfx1150-gfx1153 (RDNA3.5)
#   gfx1200, gfx1201 (RDNA4)
#   gfx1250 (RDNA4+)
#
# Detection Methods (in priority order):
#   1. ROCm tools (amd-smi, rocminfo) - most accurate
#   2. Kernel sysfs (/sys/class/drm) - requires driver loaded
#   3. PCI device IDs (lspci) - always available
#
# Exit codes:
#   0 - Successfully detected GFX architecture
#   1 - No AMD GPU detected
#   2 - AMD GPU detected but GFX architecture unknown
#   3 - Multiple different GFX architectures detected
#

set -euo pipefail

# Script version
VERSION="1.0.0"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Options
LIST_MODE=0
FORCE_METHOD=""
OUTPUT_FORMAT=""  # gfx, device-id, revision, name, all
DEDUPLICATE=0     # Deduplicate output when set to 1
SIMULATE=0        # Simulate mode - output hardcoded test data

# Installer type detection
INSTALLER_TYPE=""  # "single" or "multi" - auto-detected

# Global arrays to store detected GPU data
declare -a GPU_NAMES=()
declare -a GPU_DEVICE_IDS=()
declare -a GPU_REVISIONS=()
declare -a GPU_GFX=()

# Add GPU to global arrays
add_gpu() {
    local name="$1"
    local device_id="$2"
    local revision="$3"
    local gfx_arch="$4"

    GPU_NAMES+=("$name")
    GPU_DEVICE_IDS+=("$device_id")
    GPU_REVISIONS+=("$revision")

    # Map to package group
    local pkg_group
    pkg_group=$(map_gfx_to_package_group "$gfx_arch")
    if [[ "$pkg_group" != "unsupported" ]] && [[ "$pkg_group" != "unknown" ]]; then
        GPU_GFX+=("$pkg_group")
    else
        GPU_GFX+=("$gfx_arch")
    fi
}

# Output results based on format
output_results() {
    local format="$1"
    local -a output_lines=()

    for ((i=0; i<${#GPU_NAMES[@]}; i++)); do
        case "$format" in
            name)
                output_lines+=("${GPU_NAMES[$i]}")
                ;;
            device-id)
                output_lines+=("${GPU_DEVICE_IDS[$i]}")
                ;;
            revision)
                output_lines+=("${GPU_REVISIONS[$i]}")
                ;;
            gfx)
                output_lines+=("${GPU_GFX[$i]}")
                ;;
            all)
                # Order: name, device-id, revision, gfx
                output_lines+=("${GPU_NAMES[$i]}"$'\t'"${GPU_DEVICE_IDS[$i]}"$'\t'"${GPU_REVISIONS[$i]}"$'\t'"${GPU_GFX[$i]}")
                ;;
        esac
    done

    # Output with optional deduplication
    if [[ $DEDUPLICATE == 1 ]]; then
        printf '%s\n' "${output_lines[@]}" | sort -u
    else
        printf '%s\n' "${output_lines[@]}"
    fi
}

# Print colored message to stderr (suppressed in --output mode)
print_msg() {
    if [[ -z "$OUTPUT_FORMAT" ]]; then
        echo -e "$1" >&2
    fi
}

print_info() {
    print_msg "${CYAN}[INFO]${NC} $1"
}

print_warn() {
    print_msg "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_success() {
    print_msg "${GREEN}[SUCCESS]${NC} $1"
}

# Show usage information
show_usage() {
    cat << EOF
AMD GPU GFX Architecture Detection Script v${VERSION}

Usage: $0 [OPTIONS]

OPTIONS:
    -h, --help                  Show this help message
    -v, --version               Show version information
    -l, --list                  List all detected AMD GPUs with full details
    -m, --method <method>       Force specific detection method:
                                  rocm     - Use ROCm tools (amd-smi, rocminfo)
                                  sysfs    - Use kernel sysfs
                                  pci      - Use PCI device IDs (lspci)
                                  all      - Try all methods (default)

    -o, --output <format>       Output format for scripting (one value per line):
                                  gfx        - GFX package group (e.g., gfx110x)
                                  device-id  - PCI device ID (e.g., 7448)
                                  revision   - Revision ID (e.g., 00)
                                  name       - Device name
                                  all        - All fields (tab-separated)

    -u, --unique                Deduplicate output (show each unique value once)

    --simulate                  Simulate 4 unique GPUs (no hardware needed)

EXIT CODES:
    0 - Successfully detected GFX architecture
    1 - No AMD GPU detected
    2 - AMD GPU detected but GFX architecture unknown
    3 - Multiple different GFX architectures detected

EXAMPLES:
    # Basic detection (interactive mode)
    $0

    # Get GFX package group for first GPU
    GFX=\$($0 --output gfx | head -1)

    # Get all GFX package groups (multi-GPU)
    $0 --output gfx

    # Get unique GFX package groups (deduplicated)
    $0 --output gfx --unique

    # Get all info for each GPU (tab-separated: device-id, revision, gfx, name)
    $0 --output all

    # Get unique GPU configurations (deduplicated)
    $0 --output all --unique

    # Get device IDs for all GPUs
    $0 --output device-id

    # List all GPUs with full details
    $0 --list

    # Force PCI-based detection
    $0 --method pci

    # Simulate 4 unique GPUs
    $0 --simulate --output all

EOF
}

# Detect installer type based on available component directories
# Returns: "single" for single-arch installer, "multi" for multi-arch installer
detect_installer_type() {
    # Detect if installer is multi-arch or single-arch
    # Multi-arch: Has fine-grained architectures (gfx1100, gfx1101, etc.)
    # Single-arch: Has coarse families only (gfx110x, gfx94x, etc.)

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Primary method: Check INSTALLER_BUILD_TYPE from .gfx-lists file
    if [[ -f "$script_dir/component-rocm/.gfx-lists" ]]; then
        # Source the file to get INSTALLER_BUILD_TYPE
        # shellcheck source=/dev/null
        source "$script_dir/component-rocm/.gfx-lists"

        # Check if INSTALLER_BUILD_TYPE is set
        if [[ -n "${INSTALLER_BUILD_TYPE:-}" ]]; then
            if [[ "$INSTALLER_BUILD_TYPE" == "multi-arch" ]]; then
                echo "multi"
                return 0
            elif [[ "$INSTALLER_BUILD_TYPE" == "single-arch" ]]; then
                echo "single"
                return 0
            fi
        fi
    fi

    # Fallback: Infer from directory structure (for older installers without INSTALLER_BUILD_TYPE)
    local content_dir="$script_dir/component-rocm/content"
    if [[ -d "$content_dir" ]]; then
        # Check for fine-grained arch directories
        if [[ -d "$content_dir"/gfx1100 ]] || [[ -d "$content_dir"/gfx1101 ]] || \
           [[ -d "$content_dir"/gfx940 ]] || [[ -d "$content_dir"/gfx941 ]] || \
           [[ -d "$content_dir"/gfx1030 ]] || [[ -d "$content_dir"/gfx1031 ]] || \
           [[ -d "$content_dir"/gfx1200 ]] || [[ -d "$content_dir"/gfx1201 ]] || \
           [[ -d "$content_dir"/gfx90c ]] || [[ -d "$content_dir"/gfx1250 ]]; then
            echo "multi"
            return 0
        fi
    fi

    # Default to single-arch
    echo "single"
    return 0
}

# Map specific GFX architecture to installer package group
# (e.g., gfx110x covers gfx1100, gfx1101, gfx1102, gfx1103)
# For multi-arch installers, returns fine-grained arch as-is
# For single-arch installers, maps to coarse family
map_gfx_to_package_group() {
    local gfx_arch="$1"

    # Detect installer type if not already detected
    if [[ -z "$INSTALLER_TYPE" ]]; then
        INSTALLER_TYPE=$(detect_installer_type)
    fi

    # For multi-arch installers, return fine-grained arch as-is
    # (installer handles fine-grained arch selection)
    if [[ "$INSTALLER_TYPE" == "multi" ]]; then
        case "$gfx_arch" in
            # Return supported fine-grained architectures as-is
            gfx900|gfx906|gfx908|gfx90a|gfx90c|gfx942|gfx950|\
            gfx1010|gfx1011|gfx1012|\
            gfx1030|gfx1031|gfx1032|gfx1033|gfx1034|gfx1035|gfx1036|\
            gfx1100|gfx1101|gfx1102|gfx1103|\
            gfx1150|gfx1151|gfx1152|gfx1153|\
            gfx1200|gfx1201|gfx1250)
                echo "$gfx_arch"
                ;;
            # Unsupported/unknown
            *)
                echo "unknown"
                ;;
        esac
    else
        # For single-arch installers, map to coarse family (existing behavior)
        case "$gfx_arch" in
            # CDNA
            gfx940|gfx941|gfx942)  echo "gfx94x" ;;  # MI300 series
            gfx90a)                echo "gfx90a" ;;  # MI250/MI210
            gfx90c)                echo "gfx90c" ;;  # CDNA2 variant
            gfx908)                echo "gfx908" ;;  # MI100
            gfx950)                echo "gfx950" ;;  # MI350+

            # RDNA3
            gfx1100|gfx1101|gfx1102|gfx1103) echo "gfx110x" ;;  # RX 7000 series
            gfx1150)               echo "gfx1150" ;;  # Ryzen AI 300
            gfx1151)               echo "gfx1151" ;;  # Ryzen AI Max
            gfx1152)               echo "gfx1152" ;;  # Krackan1 APU
            gfx1153)               echo "gfx1153" ;;  # RDNA3.5

            # RDNA4
            gfx1200|gfx1201)       echo "gfx120x" ;;  # RX 9070 series
            gfx1250)               echo "gfx1250" ;;  # RDNA4+

            # RDNA2 (map to family for single-arch)
            gfx1030|gfx1031|gfx1032|gfx1033|gfx1034|gfx1035|gfx1036) echo "gfx103x" ;;

            # RDNA1 (map to family for single-arch)
            gfx1010|gfx1011|gfx1012|gfx1013) echo "gfx101x" ;;

            # Vega (map to family for single-arch)
            gfx900|gfx906|gfx909)  echo "gfx900" ;;

            # Legacy/unsupported
            *)                     echo "unknown" ;;
        esac
    fi

    return 0
}

# Map PCI device ID + revision ID to GFX architecture (revision-aware)
# Some device IDs require revision ID to differentiate between GFX architectures
# Data from radeon-powerbi Excel sheets in GPU-INFO directory
map_device_id_with_revision_to_gfx() {
    local device_id="$1"
    local revision_id="$2"

    # Remove 0x prefix if present
    device_id="${device_id#0x}"
    device_id="${device_id,,}"  # Convert to lowercase

    # Normalize revision ID (lowercase, remove 0x prefix)
    revision_id="${revision_id#0x}"
    revision_id="${revision_id,,}"  # Convert to lowercase

    # Revision-specific mappings (Device ID + Revision ID -> GFX)
    # Format: device_id/revision_id
    # Data sources: radeon-powerbi Excel sheets + amdgpu-gfx-mapping.db
    case "${device_id}/${revision_id}" in
        # Vega (gfx900/gfx906)
        66a1/02) echo "gfx906" ;;  # Radeon Pro VII
        66a1/06) echo "gfx906" ;;  # Radeon Pro VII
        66af/c1) echo "gfx906" ;;
        6861/00) echo "gfx900" ;;  # Radeon Pro WX 9100
        6868/00) echo "gfx900" ;;  # Radeon Pro WX 8200
        687f/c1) echo "gfx900" ;;  # AMD Radeon RX Vega 64
        687f/c7) echo "gfx900" ;;  # AMD Radeon RX Vega 56
        69af/cf) echo "gfx900" ;;  # AMD Radeon RX Vega 20

        # RDNA1 - RX 5000 series (Navi10)
        7312/00) echo "gfx1010" ;;  # AMD Radeon Pro W5700
        731f/c0) echo "gfx1010" ;;
        731f/c1) echo "gfx1010" ;;  # AMD Radeon RX 5700 XT
        731f/c2) echo "gfx1010" ;;  # AMD Radeon RX 5600M
        731f/c3) echo "gfx1010" ;;  # AMD Radeon RX 5700M
        731f/c4) echo "gfx1010" ;;  # AMD Radeon RX 5700
        731f/c5) echo "gfx1010" ;;
        731f/ca) echo "gfx1010" ;;  # AMD Radeon RX 5600 XT
        731f/cb) echo "gfx1010" ;;  # AMD Radeon RX 5600

        # RDNA1 - RX 5000 series (Navi14)
        7340/00) echo "gfx1012" ;;
        7340/c1) echo "gfx1012" ;;  # AMD Radeon RX 5500M
        7340/c3) echo "gfx1012" ;;  # AMD Radeon RX 5300M
        7340/c5) echo "gfx1012" ;;
        7340/c7) echo "gfx1012" ;;  # AMD Radeon RX 5500
        7340/c9) echo "gfx1012" ;;
        7340/cf) echo "gfx1012" ;;  # AMD Radeon RX 5300
        7341/00) echo "gfx1012" ;;  # AMD Radeon Pro W5500
        7347/00) echo "gfx1012" ;;  # AMD Radeon Pro W5500M

        # RDNA2 - RX 6000 series (Navi21)
        73a3/00) echo "gfx1030" ;;  # AMD Radeon PRO W6800 GPU
        73a5/c0) echo "gfx1030" ;;  # AMD Radeon RX 6950 XT
        73af/c0) echo "gfx1030" ;;  # AMD Radeon RX 6900 XT
        73bf/c0) echo "gfx1030" ;;  # AMD Radeon RX 6900 XT
        73bf/c1) echo "gfx1030" ;;  # AMD Radeon RX 6800 XT
        73bf/c3) echo "gfx1030" ;;  # AMD Radeon RX 6800

        # RDNA2 - RX 6000 series (Navi23)
        73e1/00) echo "gfx1032" ;;  # AMD Radeon PRO W6600M GPU
        73e3/00) echo "gfx1032" ;;  # AMD Radeon PRO W6600
        73ef/c0) echo "gfx1032" ;;  # AMD Radeon RX 6800S
        73ef/c1) echo "gfx1032" ;;  # AMD Radeon RX 6650 XT
        73ef/c2) echo "gfx1032" ;;  # AMD Radeon RX 6700S
        73ef/c3) echo "gfx1032" ;;  # AMD Radeon RX 6650M
        73ef/c4) echo "gfx1032" ;;  # AMD Radeon RX 6650M XT
        73ef/c7) echo "gfx1032" ;;  # AMD Radeon RX 6650M 6GB
        73ff/c1) echo "gfx1032" ;;  # AMD Radeon RX 6600 XT
        73ff/c3) echo "gfx1032" ;;  # AMD Radeon RX 6600M
        73ff/c7) echo "gfx1032" ;;  # AMD Radeon RX 6600
        73ff/cb) echo "gfx1032" ;;  # AMD Radeon RX 6600S
        73ff/cf) echo "gfx1032" ;;  # AMD Radeon RX 6600 LE
        73ff/ef) echo "gfx1032" ;;  # AMD Radeon RX 6600M

        # RDNA2 - RX 6000 series (Navi24)
        7421/00) echo "gfx1033" ;;  # AMD Radeon PRO W6500M GPU
        7422/00) echo "gfx1033" ;;  # AMD Radeon PRO W6400 GPU
        7423/00) echo "gfx1033" ;;  # AMD Radeon PRO W6300M
        7423/01) echo "gfx1033" ;;  # AMD Radeon PRO W6300 GPU
        7424/00) echo "gfx1033" ;;  # AMD Radeon RX 6300
        743f/c1) echo "gfx1033" ;;  # AMD Radeon RX 6500 XT
        743f/c3) echo "gfx1033" ;;  # AMD Radeon RX 6500M
        743f/c7) echo "gfx1033" ;;  # AMD Radeon RX 6400
        743f/c8) echo "gfx1033" ;;  # AMD Radeon RX 6550M
        743f/cc) echo "gfx1033" ;;  # AMD Radeon RX 6550S
        743f/ce) echo "gfx1033" ;;  # AMD Radeon RX 6450M
        743f/cf) echo "gfx1033" ;;  # AMD Radeon RX 6300M
        743f/d3) echo "gfx1033" ;;  # AMD Radeon RX 6550M

        # RDNA3 - RX 7000 series (Navi31)
        7448/00) echo "gfx1100" ;;  # AMD Radeon PRO W7900 GPU
        7449/00) echo "gfx1100" ;;  # AMD RadeonTM Pro W7800 48GB
        744a/00) echo "gfx1100" ;;  # AMD Radeon PRO W7900 GPU Dual Slot
        744b/00) echo "gfx1100" ;;  # AMD Radeon PRO W7900D
        744c/c8) echo "gfx1100" ;;  # AMD Radeon RX 7900 XTX
        744c/cc) echo "gfx1100" ;;  # AMD Radeon RX 7900 XT
        744c/ce) echo "gfx1100" ;;  # AMD Radeon RX 7900 GRE
        744c/cf) echo "gfx1100" ;;  # AMD Radeon RX 7900M
        745e/cc) echo "gfx1100" ;;  # AMD Radeon PRO W7800 GPU

        # RDNA3 - RX 7000 series (Navi32)
        7470/00) echo "gfx1101" ;;  # AMD Radeon PRO W7700 GPU
        747e/c8) echo "gfx1101" ;;  # AMD Radeon RX 7800 XT
        747e/c9) echo "gfx1101" ;;  # TBD
        747e/d8) echo "gfx1101" ;;  # AMD Radeon RX 7800M
        747e/db) echo "gfx1101" ;;  # AMD Radeon RX 7700
        747e/ff) echo "gfx1101" ;;  # AMD Radeon RX 7700 XT

        # RDNA3 - RX 7000 series (Navi33)
        7480/00) echo "gfx1102" ;;  # AMD Radeon PRO W7600 GPU
        7480/c0) echo "gfx1102" ;;  # AMD Radeon RX 7600 XT
        7480/c1) echo "gfx1102" ;;  # AMD Radeon RX 7700S
        7480/c2) echo "gfx1102" ;;  # AMD Radeon RX7650GRE
        7480/c3) echo "gfx1102" ;;  # AMD Radeon RX 7600S
        7480/c7) echo "gfx1102" ;;  # AMD Radeon RX 7600M XT
        7480/cf) echo "gfx1102" ;;  # AMD Radeon RX 7600
        7483/cf) echo "gfx1102" ;;  # AMD Radeon RX 7600M
        7487/cf) echo "gfx1102" ;;  # AMD Radeon RX 7500M
        7489/00) echo "gfx1102" ;;  # AMD Radeon PRO W7500 GPU
        7499/00) echo "gfx1102" ;;  # AMD Radeon Pro W7400 GPU
        7499/c0) echo "gfx1102" ;;  # AMD Radeon RX 7400
        7499/c1) echo "gfx1102" ;;  # AMD Radeon RX 7300

        # CRITICAL: Phoenix APU (0x15BF) - Ryzen 7000 series
        # Different revisions map to DIFFERENT GFX architectures:
        # - Specific revisions below -> gfx1100 (discrete-class RDNA3)
        # - Other revisions -> gfx1103 (APU-class RDNA3) via fallback mapping
        15bf/00) echo "gfx1100" ;;
        15bf/02) echo "gfx1100" ;;
        15bf/06) echo "gfx1100" ;;
        15bf/c1) echo "gfx1100" ;;
        15bf/c2) echo "gfx1100" ;;
        15bf/c4) echo "gfx1100" ;;
        15bf/c6) echo "gfx1100" ;;
        15bf/c7) echo "gfx1100" ;;
        15bf/c9) echo "gfx1100" ;;
        15bf/cf) echo "gfx1100" ;;
        15bf/d0) echo "gfx1100" ;;
        15bf/d2) echo "gfx1100" ;;
        15bf/d3) echo "gfx1100" ;;
        15bf/d4) echo "gfx1100" ;;
        15bf/d7) echo "gfx1100" ;;
        15bf/d9) echo "gfx1100" ;;
        15bf/da) echo "gfx1100" ;;
        15bf/dd) echo "gfx1100" ;;

        # CRITICAL: Phoenix APU (0x1900) - Ryzen 7000 series
        # Different revisions map to DIFFERENT GFX architectures:
        # - Specific revisions below -> gfx1100 (discrete-class RDNA3)
        # - Other revisions -> gfx1103 (APU-class RDNA3) via fallback mapping
        1900/01) echo "gfx1100" ;;
        1900/03) echo "gfx1100" ;;
        1900/05) echo "gfx1100" ;;
        1900/06) echo "gfx1100" ;;
        1900/b0) echo "gfx1100" ;;
        1900/b1) echo "gfx1100" ;;
        1900/b2) echo "gfx1100" ;;
        1900/b3) echo "gfx1100" ;;
        1900/b4) echo "gfx1100" ;;
        1900/b5) echo "gfx1100" ;;
        1900/b6) echo "gfx1100" ;;
        1900/b9) echo "gfx1100" ;;
        1900/ba) echo "gfx1100" ;;
        1900/bb) echo "gfx1100" ;;
        1900/c0) echo "gfx1100" ;;
        1900/c2) echo "gfx1100" ;;
        1900/c4) echo "gfx1100" ;;
        1900/c5) echo "gfx1100" ;;
        1900/c7) echo "gfx1100" ;;
        1900/c9) echo "gfx1100" ;;
        1900/cb) echo "gfx1100" ;;
        1900/cc) echo "gfx1100" ;;
        1900/ce) echo "gfx1100" ;;
        1900/d0) echo "gfx1100" ;;
        1900/d2) echo "gfx1100" ;;
        1900/d4) echo "gfx1100" ;;
        1900/d5) echo "gfx1100" ;;
        1900/d7) echo "gfx1100" ;;
        1900/d9) echo "gfx1100" ;;
        1900/db) echo "gfx1100" ;;
        1900/dc) echo "gfx1100" ;;
        1900/de) echo "gfx1100" ;;
        1900/f0) echo "gfx1100" ;;
        1900/f1) echo "gfx1100" ;;
        1900/f2) echo "gfx1100" ;;

        # RDNA4 - RX 9000 series (Navi48 -> gfx1201)
        7550/c0) echo "gfx1201" ;;  # AMD Radeon RX 9070 XT
        7550/c2) echo "gfx1201" ;;  # AMD Radeon 9070 GRE
        7550/c3) echo "gfx1201" ;;  # AMD Radeon RX 9070
        7551/c0) echo "gfx1201" ;;  # AMD Radeon AI PRO R9700
        7551/c1) echo "gfx1201" ;;  # AMD Radeon AI PRO R9700S
        7551/c8) echo "gfx1201" ;;  # AMD Radeon AI PRO R9600D

        # RDNA4 - RX 9000 series (Navi44 -> gfx1200)
        7590/c0) echo "gfx1200" ;;  # AMD Radeon 9060 XT
        7590/c1) echo "gfx1200" ;;  # AMD Radeon RX 9060 XT LP
        7590/c7) echo "gfx1200" ;;  # AMD Radeon 9060
        7590/cf) echo "gfx1200" ;;  # AMD Radeon RX 9050
        7590/df) echo "gfx1200" ;;  # AMD Radeon RX 9050 4GB

        # No revision-specific mapping found
        *) return 1 ;;
    esac

    return 0
}

# Map PCI device ID to GFX architecture
# Device IDs from AMDGPU driver, ROCm metadata, and verified hardware
# Note: This function is revision-agnostic. For revision-aware mapping,
#       use map_device_id_with_revision_to_gfx() first.
map_device_id_to_gfx() {
    local device_id="$1"
    local revision_id="${2:-}"  # Optional revision ID parameter

    # Try revision-aware mapping first (if revision ID provided)
    if [[ -n "$revision_id" ]]; then
        local gfx_with_rev
        if gfx_with_rev=$(map_device_id_with_revision_to_gfx "$device_id" "$revision_id" 2>/dev/null); then
            echo "$gfx_with_rev"
            return 0
        fi
    fi

    # Fall back to revision-agnostic mapping
    # Remove 0x prefix if present
    device_id="${device_id#0x}"
    device_id="${device_id,,}"  # Convert to lowercase

    case "$device_id" in
        # CDNA3 - MI300 series
        74a0|74a1|74a2|74a3|74a4|74a5|74a6|74a7|74a8|74a9|74aa|74ab|74b4|74b5|74b6|74b9|74bd)
            echo "gfx942" ;;

        # CDNA4 - MI350+ series
        75a0|75a1|75a2|75a3|75a4|75a5|75a6|75a7|75a8|75a9|75aa|75ab|75ac|75ad|75ae|75af|75b0|75b2|75b3|75b8)
            echo "gfx950" ;;

        # CDNA2 - MI250X/MI250/MI210
        740c|740f|7408|7410|1636|1638|164c|15d8|15dd)
            echo "gfx90a" ;;

        # CDNA1 - MI100
        7388|738c|738e|7390)
            echo "gfx908" ;;

        # Vega (GCN5)
        6860|6861|6862|6863|6864|6867|6868|6869|686a|686b|686c|686d|686e|686f|687f|\
        69a0|69a1|69a2|69a3|69af|\
        66a0|66a1|66a2|66a3|66a4|66a7|66af)
            echo "gfx900" ;;

        # RDNA1 - RX 5000 series
        7310|7312|7318|7319|731a|731b|731e|731f) echo "gfx1010" ;;
        7360|7362|7340|7341|7347|734f) echo "gfx1012" ;;

        # RDNA2 - RX 6000 series
        73a0|73a1|73a2|73a3|73a5|73a8|73a9|73ab|73ac|73ad|73ae|73af|73bf) echo "gfx1030" ;;
        73c0|73c1|73c3|73da|73db|73dc|73dd|73de|73df) echo "gfx1031" ;;
        73e0|73e1|73e2|73e3|73e8|73e9|73ea|73eb|73ec|73ed|73ef|73ff) echo "gfx1032" ;;
        7420|7421|7422|7423|7424|743f) echo "gfx1033" ;;

        # RDNA3 - RX 7900 XTX/XT
        7448|744c|7449|744a|744b) echo "gfx1100" ;;
        # RDNA3 - RX 7800/7700
        7478|747e|746f|748f) echo "gfx1101" ;;
        # RDNA3 - RX 7600
        7480|7483|7487|7460|7461|7489|7499) echo "gfx1102" ;;

        # APU - Ryzen 7000 (RDNA3)
        15bf|15c8|1900|1901) echo "gfx1103" ;;
        # APU - Ryzen AI 300 Strix Point (RDNA3.5)
        150e) echo "gfx1150" ;;
        # APU - Ryzen AI Max Strix Halo (RDNA3.5)
        1586) echo "gfx1151" ;;
        # APU - Krackan (RDNA3.5) - Note: 0x17f0 from XDNA/NPU reference
        17f0) echo "gfx1152" ;;
        1114) echo "gfx1152" ;;

        # APU - Ryzen 6000 (RDNA2)
        164d|1681) echo "gfx1035" ;;
        163f) echo "gfx1033" ;;
        164e) echo "gfx1036" ;;

        # RDNA4 - RX 9000 series
        # Note: Navi48 uses gfx1201, Navi44 uses gfx1200
        # Revision ID is required for accurate detection - use revision-aware mapping when available
        7550|7551) echo "gfx1201" ;;  # Navi48: RX 9070 series (default without revision)
        7590) echo "gfx1200" ;;  # Navi44: RX 9060 series

        *) return 1 ;;
    esac

    return 0
}

# Detect using ROCm tools (most accurate)
# Returns space-separated list of GFX architectures
detect_from_rocm_tools() {
    print_info "Trying ROCm tools detection..."
    local -a detected_gfx_list=()

    if command -v amd-smi &> /dev/null; then
        while read -r gfx_arch; do
            [[ -n "$gfx_arch" ]] && detected_gfx_list+=("$gfx_arch")
        done < <(amd-smi static --asic 2>/dev/null | grep -oP 'gfx\w+')

        if [[ ${#detected_gfx_list[@]} -gt 0 ]]; then
            print_success "Detected via amd-smi: ${detected_gfx_list[*]}"
            echo "${detected_gfx_list[@]}"
            return 0
        fi
    fi

    if command -v rocminfo &> /dev/null; then
        while read -r gfx_arch; do
            [[ -n "$gfx_arch" ]] && detected_gfx_list+=("$gfx_arch")
        done < <(rocminfo 2>/dev/null | grep -oP 'Name:\s+\Kgfx\w+')

        if [[ ${#detected_gfx_list[@]} -gt 0 ]]; then
            print_success "Detected via rocminfo: ${detected_gfx_list[*]}"
            echo "${detected_gfx_list[@]}"
            return 0
        fi
    fi

    print_warn "ROCm tools not available or failed"
    return 1
}

# Detect using kernel sysfs (requires driver loaded)
# Returns space-separated list of GFX architectures
detect_from_sysfs() {
    print_info "Trying sysfs detection..."
    local -a detected_gfx_list=()
    local -a unknown_devices=()

    for card in /sys/class/drm/card*/device; do
        [[ ! -f "$card/vendor" ]] && continue

        local vendor
        vendor=$(cat "$card/vendor" 2>/dev/null || echo "")
        [[ "$vendor" != "0x1002" ]] && continue

        local device_id
        device_id=$(sed 's/0x//' "$card/device" 2>/dev/null)
        [[ -z "$device_id" ]] && continue

        local rev_id=""
        if [[ -f "$card/revision" ]]; then
            rev_id=$(sed 's/0x//' "$card/revision" 2>/dev/null || echo "")
            rev_id=${rev_id^^}
        fi

        local gfx_arch
        # Pass revision ID to enable revision-aware mapping
        if [[ -n "$rev_id" ]]; then
            gfx_arch=$(map_device_id_to_gfx "$device_id" "$rev_id")
        else
            gfx_arch=$(map_device_id_to_gfx "$device_id")
        fi

        if [[ -n "$gfx_arch" ]]; then
            detected_gfx_list+=("$gfx_arch")
            if [[ -n "$rev_id" ]]; then
                print_success "Detected via sysfs: $gfx_arch (device ID: 0x$device_id, rev: 0x$rev_id)"
            else
                print_success "Detected via sysfs: $gfx_arch (device ID: 0x$device_id)"
            fi
        else
            [[ -n "$rev_id" ]] && unknown_devices+=("0x$device_id:0x$rev_id") || unknown_devices+=("0x$device_id")
        fi
    done

    [[ ${#unknown_devices[@]} -gt 0 ]] && printf '%s\n' "${unknown_devices[@]}" | while read -r dev; do print_warn "Unknown device: $dev"; done

    if [[ ${#detected_gfx_list[@]} -gt 0 ]]; then
        echo "${detected_gfx_list[@]}"
        return 0
    fi

    print_warn "No AMD GPU found in sysfs or failed to map device ID"
    return 1
}

# Detect using lspci (always available)
# Returns space-separated list of GFX architectures
detect_from_pci() {
    print_info "Trying PCI detection..."

    if ! command -v lspci &> /dev/null; then
        print_warn "lspci not available"
        return 1
    fi

    local -a detected_gfx_list=()
    local -a unknown_devices=()

    while IFS= read -r pci_line; do
        local device_id
        device_id=$(echo "$pci_line" | grep -oP '\[1002:\K[0-9a-f]{4}(?=\])')
        [[ -z "$device_id" ]] && continue

        local pci_addr
        pci_addr=$(echo "$pci_line" | awk '{print $1}')
        local rev_id=""
        local pci_verbose
        pci_verbose=$(lspci -v -s "$pci_addr" 2>/dev/null)
        if [[ -n "$pci_verbose" ]]; then
            rev_id=$(echo "$pci_verbose" | grep -oP '\(rev \K[0-9a-f]{2}(?=\))' || echo "00")
            rev_id=${rev_id^^}
        fi

        local gfx_arch
        # Pass revision ID to enable revision-aware mapping
        if [[ -n "$rev_id" && "$rev_id" != "00" ]]; then
            gfx_arch=$(map_device_id_to_gfx "$device_id" "$rev_id")
        else
            gfx_arch=$(map_device_id_to_gfx "$device_id")
        fi

        if [[ -n "$gfx_arch" ]]; then
            detected_gfx_list+=("$gfx_arch")
            if [[ -n "$rev_id" ]]; then
                print_success "Detected via lspci: $gfx_arch (device ID: 0x$device_id, rev: 0x$rev_id)"
            else
                print_success "Detected via lspci: $gfx_arch (device ID: 0x$device_id)"
            fi
        else
            if [[ -n "$rev_id" ]]; then
                unknown_devices+=("0x$device_id:0x$rev_id")
                print_warn "Unknown device ID: 0x$device_id, rev: 0x$rev_id"
            else
                unknown_devices+=("0x$device_id")
                print_warn "Unknown device ID: 0x$device_id"
            fi
        fi
    done < <(lspci -nn -d 1002: 2>/dev/null | grep -E "VGA|Display|3D|Processing accelerators")

    if [[ ${#detected_gfx_list[@]} -gt 0 ]]; then
        echo "${detected_gfx_list[@]}"
        return 0
    elif [[ ${#unknown_devices[@]} -gt 0 ]]; then
        print_warn "Found AMD GPU(s) but could not map to GFX architecture"
        return 2
    fi

    print_warn "No AMD GPU found via lspci"
    return 1
}

# List all detected AMD GPUs
list_gpus() {
    echo "================================================================="
    echo "AMD GPU Detection Report"
    echo "================================================================="
    echo ""

    local found_any=0

    # Try lspci first for comprehensive list
    if command -v lspci &> /dev/null; then
        echo "PCI Devices (lspci):"
        echo "-----------------------------------------------------------------"

        local gpu_count=0
        local -A pci_revisions
        # Build revision lookup table from lspci -v output
        while IFS= read -r line; do
            if [[ "$line" =~ ^([0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]).*\(rev\ ([0-9a-f]{2})\) ]]; then
                local addr="${BASH_REMATCH[1]}"
                local rev="${BASH_REMATCH[2]}"
                pci_revisions["$addr"]="${rev^^}"
            fi
        done < <(lspci -v -d 1002: 2>/dev/null | grep -E "VGA|Display|3D|Processing accelerators")

        while IFS= read -r line; do
            found_any=1
            gpu_count=$((gpu_count + 1))

            local pci_addr
            pci_addr=$(echo "$line" | awk '{print $1}')
            local device_id
            device_id=$(echo "$line" | grep -oP '\[1002:\K[0-9a-f]{4}(?=\])')
            local rev_id="${pci_revisions[$pci_addr]:-00}"
            local gfx_arch
            # Pass revision ID to enable revision-aware mapping
            if [[ -n "$rev_id" && "$rev_id" != "00" ]]; then
                gfx_arch=$(map_device_id_to_gfx "$device_id" "$rev_id" 2>/dev/null || echo "Unknown")
            else
                gfx_arch=$(map_device_id_to_gfx "$device_id" 2>/dev/null || echo "Unknown")
            fi
            local pkg_group=""
            [[ "$gfx_arch" != "Unknown" ]] && pkg_group=$(map_gfx_to_package_group "$gfx_arch")

            echo "GPU #$gpu_count:"
            echo "  PCI Info: $line"
            echo "  Device ID: 0x$device_id"
            echo "  Revision ID: 0x$rev_id"
            echo "  GFX Arch: $gfx_arch"
            if [[ -n "$pkg_group" && "$pkg_group" != "unknown" ]]; then
                [[ "$pkg_group" == "unsupported" ]] && \
                    echo "  Package Group: Not supported" || \
                    echo "  Package Group: $pkg_group (use: gfx=$pkg_group)"
            fi
            echo ""
        done < <(lspci -nn -d 1002: 2>/dev/null | grep -E "VGA|Display|3D|Processing accelerators")

        if [[ $gpu_count == 0 ]]; then
            echo "  No AMD GPUs detected"
        fi
    else
        echo "lspci not available - skipping PCI enumeration"
    fi

    echo ""
    echo "Kernel Sysfs:"
    echo "-----------------------------------------------------------------"

    local card_count=0
    for card in /sys/class/drm/card*/device; do
        if [[ ! -f "$card/vendor" ]]; then
            continue
        fi

        local vendor
        vendor=$(cat "$card/vendor" 2>/dev/null || echo "")
        if [[ "$vendor" != "0x1002" ]]; then
            continue
        fi

        found_any=1
        card_count=$((card_count + 1))

        local device_id
        device_id=$(cat "$card/device" 2>/dev/null || echo "unknown")

        local rev_id
        if [[ -f "$card/revision" ]]; then
            rev_id=$(sed 's/0x//' "$card/revision" 2>/dev/null || echo "00")
            rev_id=${rev_id^^}
        else
            rev_id="N/A"
        fi

        local product_name
        product_name=$(cat "$card/product_name" 2>/dev/null || echo "N/A")

        local gfx_arch
        # Pass revision ID to enable revision-aware mapping
        if [[ -n "$rev_id" && "$rev_id" != "N/A" ]]; then
            gfx_arch=$(map_device_id_to_gfx "$device_id" "$rev_id" 2>/dev/null || echo "Unknown")
        else
            gfx_arch=$(map_device_id_to_gfx "$device_id" 2>/dev/null || echo "Unknown")
        fi

        # Map to package group
        local pkg_group=""
        if [[ "$gfx_arch" != "Unknown" ]]; then
            pkg_group=$(map_gfx_to_package_group "$gfx_arch")
        fi

        echo "Card #$card_count ($(basename "$(dirname "$card")"))"
        echo "  Device ID: $device_id"
        if [[ "$rev_id" != "N/A" ]]; then
            echo "  Revision ID: 0x$rev_id"
        else
            echo "  Revision ID: N/A"
        fi
        echo "  Product Name: $product_name"
        echo "  GFX Arch: $gfx_arch"
        if [[ -n "$pkg_group" && "$pkg_group" != "unknown" ]]; then
            if [[ "$pkg_group" == "unsupported" ]]; then
                echo "  Package Group: Not supported"
            else
                echo "  Package Group: $pkg_group (use: gfx=$pkg_group)"
            fi
        fi
        echo ""
    done

    if [[ $card_count == 0 ]]; then
        echo "  No AMD GPUs in sysfs (driver may not be loaded)"
    fi

    echo ""
    echo "ROCm Tools:"
    echo "-----------------------------------------------------------------"

    if command -v amd-smi &> /dev/null; then
        echo "amd-smi output:"
        amd-smi static --asic 2>/dev/null || echo "  amd-smi failed"
    else
        echo "  amd-smi not available"
    fi

    echo ""

    if command -v rocminfo &> /dev/null; then
        echo "rocminfo output (GPUs only):"
        rocminfo 2>/dev/null | grep -A 5 "Name:.*gfx" || echo "  No GPUs detected by rocminfo"
    else
        echo "  rocminfo not available"
    fi

    echo ""
    echo "================================================================="

    if [[ $found_any == 0 ]]; then
        return 1
    fi

    return 0
}

# Main detection (tries all methods in priority order)
detect_gfx_architecture() {
    local gfx_results=""

    case "$FORCE_METHOD" in
        rocm)   gfx_results=$(detect_from_rocm_tools) || return $? ;;
        sysfs)  gfx_results=$(detect_from_sysfs) || return $? ;;
        pci)    gfx_results=$(detect_from_pci) || return $? ;;
        all|"")
            gfx_results=$(detect_from_rocm_tools) && { echo "$gfx_results"; return 0; }
            gfx_results=$(detect_from_sysfs) && { echo "$gfx_results"; return 0; }
            gfx_results=$(detect_from_pci) || return $?
            ;;
        *)
            print_error "Unknown detection method: $FORCE_METHOD"
            return 1
            ;;
    esac

    [[ -n "$gfx_results" ]] && { echo "$gfx_results"; return 0; }
    return 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -v|--version)
            echo "AMD GPU GFX Detection Script v${VERSION}"
            exit 0
            ;;
        -o|--output)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -l|--list)
            LIST_MODE=1
            shift
            ;;
        -m|--method)
            FORCE_METHOD="$2"
            shift 2
            ;;
        -u|--unique)
            DEDUPLICATE=1
            shift
            ;;
        --simulate)
            SIMULATE=1
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Collect GPU data from ROCm tools (amd-smi)
collect_from_amd_smi() {
    command -v amd-smi &> /dev/null || return 1

    local output
    output=$(amd-smi static 2>/dev/null) || return 1
    [[ -z "$output" ]] && return 1

    local -a device_ids=()
    local -a rev_ids=()
    local -a gfx_archs=()
    local -a names=()

    # Try both old and new amd-smi output formats
    mapfile -t device_ids < <(echo "$output" | grep -oP '(?:DEVICE_ID|Device ID):\s+0x\K[0-9a-fA-F]+')
    mapfile -t rev_ids < <(echo "$output" | grep -oP '(?:REV_ID|Rev ID):\s+0x\K[0-9a-fA-F]+' | tr '[:lower:]' '[:upper:]')
    mapfile -t gfx_archs < <(echo "$output" | grep -oP 'gfx\w+')
    mapfile -t names < <(echo "$output" | grep -oP '(?:MARKET_NAME|Product Name):\s+\K.+' | sed 's/[[:space:]]*$//')

    local count=${#gfx_archs[@]}
    [[ $count -eq 0 ]] && return 1

    for ((i=0; i<count; i++)); do
        add_gpu "${names[$i]:-N/A}" "${device_ids[$i]:-N/A}" "${rev_ids[$i]:-00}" "${gfx_archs[$i]}"
    done

    return 0
}

# Collect GPU data from sysfs
collect_from_sysfs() {
    local found=0

    for card in /sys/class/drm/card*/device; do
        [[ ! -f "$card/vendor" ]] && continue

        local vendor
        vendor=$(cat "$card/vendor" 2>/dev/null || echo "")
        [[ "$vendor" != "0x1002" ]] && continue

        local device_id rev_id gfx_arch name

        device_id=$(sed 's/0x//' "$card/device" 2>/dev/null || echo "N/A")

        if [[ -f "$card/revision" ]]; then
            rev_id=$(sed 's/0x//' "$card/revision" 2>/dev/null || echo "")
            rev_id=${rev_id^^}
        else
            rev_id="00"
        fi

        # Pass revision ID to enable revision-aware mapping
        if [[ -n "$rev_id" && "$rev_id" != "00" ]]; then
            gfx_arch=$(map_device_id_to_gfx "$device_id" "$rev_id" 2>/dev/null || echo "unknown")
        else
            gfx_arch=$(map_device_id_to_gfx "$device_id" 2>/dev/null || echo "unknown")
        fi

        name="AMD GPU"
        if [[ -f "$card/product_name" ]]; then
            local product_name
            product_name=$(cat "$card/product_name" 2>/dev/null)
            [[ -n "$product_name" && "$product_name" != "N/A" ]] && name="$product_name"
        fi

        add_gpu "$name" "$device_id" "$rev_id" "$gfx_arch"
        found=1
    done

    [[ $found == 1 ]]
}

# Collect GPU data from lspci
collect_from_lspci() {
    command -v lspci &> /dev/null || return 1

    local found=0

    while IFS= read -r pci_line; do
        local pci_addr device_id rev_id gfx_arch name

        pci_addr=$(echo "$pci_line" | awk '{print $1}')
        device_id=$(echo "$pci_line" | grep -oP '\[1002:\K[0-9a-f]{4}(?=\])')
        [[ -z "$device_id" ]] && continue

        local pci_verbose
        pci_verbose=$(lspci -v -s "$pci_addr" 2>/dev/null)
        rev_id=$(echo "$pci_verbose" | grep -oP '\(rev \K[0-9a-f]{2}(?=\))' | tr '[:lower:]' '[:upper:]')
        [[ -z "$rev_id" ]] && rev_id="00"

        # Pass revision ID to enable revision-aware mapping
        if [[ -n "$rev_id" && "$rev_id" != "00" ]]; then
            gfx_arch=$(map_device_id_to_gfx "$device_id" "$rev_id" 2>/dev/null || echo "unknown")
        else
            gfx_arch=$(map_device_id_to_gfx "$device_id" 2>/dev/null || echo "unknown")
        fi

        name=$(lspci -s "$pci_addr" 2>/dev/null | head -1 | sed -E 's/^[0-9a-f:.]+\s+[^:]+:\s+//')
        [[ -z "$name" ]] && name=$(echo "$pci_line" | sed -E 's/^[0-9a-f:.]+\s+[^:]+:\s+//' | sed 's/\s*\[.*$//')

        add_gpu "$name" "$device_id" "$rev_id" "$gfx_arch"
        found=1
    done < <(lspci -nn -d 1002: 2>/dev/null | grep -E "VGA|Display|3D|Processing accelerators")

    [[ $found == 1 ]]
}

# Collect all GPU data using available methods
collect_gpu_data() {
    collect_from_amd_smi && return 0
    collect_from_sysfs && return 0
    collect_from_lspci && return 0
    return 1
}

# Simulate GPU data for testing (4 unique GPUs)
simulate_gpu_data() {
    # GPU 1: MI300X (CDNA3)
    add_gpu "AMD Instinct MI300X" "74a0" "00" "gfx942"

    # GPU 2: MI250X (CDNA2)
    add_gpu "AMD Instinct MI250X" "740f" "00" "gfx90a"

    # GPU 3: RX 7900 XTX (RDNA3)
    add_gpu "AMD Radeon RX 7900 XTX" "7448" "00" "gfx1100"

    # GPU 4: RX 9070 XT (RDNA4)
    add_gpu "AMD Radeon RX 9070 XT" "7550" "01" "gfx1201"

    return 0
}

if [[ $LIST_MODE == 1 ]]; then
    list_gpus
    exit $?
fi

# Handle --output modes
if [[ -n "$OUTPUT_FORMAT" ]]; then
    # Use simulated data if requested, otherwise collect real data
    if [[ $SIMULATE == 1 ]]; then
        simulate_gpu_data
    else
        if ! collect_gpu_data; then
            exit 1
        fi
    fi

    case "$OUTPUT_FORMAT" in
        all|gfx|device-id|revision|name)
            # Output the results
            output_results "$OUTPUT_FORMAT"

            # Determine correct exit code based on unique GFX architectures
            unique_gfx=()
            for gfx in "${GPU_GFX[@]}"; do
                # Check for unknown/unsupported architectures
                if [[ "$gfx" == "unknown" ]]; then
                    exit 2  # AMD GPU detected but architecture unknown
                fi

                # Build unique GFX list
                if [[ $DEDUPLICATE == 1 ]]; then
                    # With --unique, we already deduplicated in output, so check the actual unique count
                    pattern=" $gfx "
                    if [[ ! " ${unique_gfx[*]} " =~ $pattern ]]; then
                        unique_gfx+=("$gfx")
                    fi
                else
                    # Without --unique, count all GPUs
                    unique_gfx+=("$gfx")
                fi
            done

            # Determine exit code
            if [[ ${#unique_gfx[@]} -eq 0 ]]; then
                exit 1  # No GPU detected
            elif [[ $DEDUPLICATE == 1 && ${#unique_gfx[@]} -gt 1 ]]; then
                exit 3  # Multiple different architectures (after deduplication)
            else
                exit 0  # Success (single unique arch, or multiple GPUs without deduplication)
            fi
            ;;
        *)
            print_error "Unknown output format: $OUTPUT_FORMAT"
            print_error "Valid formats: gfx, device-id, revision, name, all"
            exit 1
            ;;
    esac
fi

# Detect GFX architecture (interactive mode)
print_info "Starting AMD GPU GFX architecture detection..."

gfx_result=$(detect_gfx_architecture)
exit_code=$?

if [[ $exit_code == 0 ]]; then
    read -ra gfx_array <<< "$gfx_result"

    # Deduplicate architectures
    unique_gfx=()
    for gfx in "${gfx_array[@]}"; do
        pattern=" $gfx "
        if [[ ! " ${unique_gfx[*]} " =~ $pattern ]]; then
            unique_gfx+=("$gfx")
        fi
    done

    if [[ ${#unique_gfx[@]} -eq 1 ]]; then
        # Single architecture or all GPUs have same architecture
        gfx_arch="${unique_gfx[0]}"
        pkg_group=$(map_gfx_to_package_group "$gfx_arch")

        if [[ -z "$OUTPUT_FORMAT" ]]; then
            echo ""
            echo "================================================================="
            if [[ ${#gfx_array[@]} -gt 1 ]]; then
                echo -e "${GREEN}Detected ${#gfx_array[@]} GPU(s), all with GFX Architecture: $gfx_arch${NC}"
            else
                echo -e "${GREEN}Detected GFX Architecture: $gfx_arch${NC}"
            fi

            if [[ "$pkg_group" == "unsupported" ]]; then
                echo -e "${YELLOW}Package Group: Not supported in this installer${NC}"
                echo -e "${YELLOW}This GPU architecture may not have ROCm packages available${NC}"
            elif [[ "$pkg_group" == "unknown" ]]; then
                echo -e "${YELLOW}Package Group: Unknown${NC}"
            else
                echo -e "${CYAN}Package Group: $pkg_group${NC}"
                echo ""
                echo "Use with installer: gfx=$pkg_group"
            fi
            echo "================================================================="
        fi
        exit 0
    else
        # Multiple different architectures
        print_warn "Multiple GFX architectures: ${unique_gfx[*]}"
        pkg_groups=()
        for gfx in "${unique_gfx[@]}"; do
            pkg=$(map_gfx_to_package_group "$gfx")
            if [[ "$pkg" != "unsupported" ]] && [[ "$pkg" != "unknown" ]]; then
                pattern=" $pkg "
                if [[ ! " ${pkg_groups[*]} " =~ $pattern ]]; then
                    pkg_groups+=("$pkg")
                fi
            fi
        done

        if [[ -z "$OUTPUT_FORMAT" ]]; then
            echo ""
            echo "================================================================="
            echo -e "${YELLOW}Multiple GFX Architectures Detected${NC}"
            echo "================================================================="
            echo ""
            echo "Detected architectures:"
            for gfx in "${unique_gfx[@]}"; do
                pkg=$(map_gfx_to_package_group "$gfx")
                echo "  - $gfx → $pkg"
            done
            echo ""
            if [[ ${#pkg_groups[@]} -gt 0 ]]; then
                combined_pkg=$(IFS=,; echo "${pkg_groups[*]}")
                echo -e "${CYAN}To install packages for all detected GPUs:${NC}"
                echo "  gfx=$combined_pkg"
            else
                echo -e "${YELLOW}No supported package groups found${NC}"
            fi
            echo "================================================================="
        fi
        exit 3
    fi
elif [[ $exit_code == 2 ]]; then
    print_error "AMD GPU detected but GFX architecture is unknown"
    print_error "This GPU may not be supported by the installer"
    print_info "Run '$0 --list' to see detailed GPU information"
    exit 2
else
    print_error "No AMD GPU detected in the system"
    print_info "Possible reasons:"
    print_info "  - No AMD GPU installed"
    print_info "  - AMDGPU driver not loaded"
    print_info "  - Insufficient permissions"
    print_info ""
    print_info "Run '$0 --list' to see detailed information"
    exit 1
fi
