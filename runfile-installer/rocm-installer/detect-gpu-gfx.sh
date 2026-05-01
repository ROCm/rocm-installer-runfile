#!/bin/bash
#
# detect-gpu-gfx.sh - AMD GPU GFX Architecture Detection Script
#
# This script detects the GFX architecture of AMD GPUs and maps them to
# ROCm package groups for use with the ROCm installer.
#
# Supported ROCm Package Groups:
#   gfx908  - MI100 (CDNA1)
#   gfx90a  - MI210, MI250, MI250X (CDNA2)
#   gfx94x  - MI300A, MI300X, MI308X, MI325X (CDNA3)
#   gfx950  - MI350, MI355, MI358 (CDNA4)
#   gfx110x - RX 7900/7800/7700/7600, Ryzen 7000 APU (RDNA3)
#   gfx1150 - Ryzen AI 300 Strix Point (Radeon 880M/890M)
#   gfx1151 - Ryzen AI Max Strix Halo (RDNA3.5)
#   gfx1152 - Krackan1 APU (RDNA3.5)
#   gfx120x - RX 9070 series (RDNA4)
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

# Map specific GFX architecture to installer package group
# (e.g., gfx110x covers gfx1100, gfx1101, gfx1102, gfx1103)
map_gfx_to_package_group() {
    local gfx_arch="$1"

    case "$gfx_arch" in
        # CDNA
        gfx940|gfx941|gfx942)  echo "gfx94x" ;;  # MI300 series
        gfx90a)                echo "gfx90a" ;;  # MI250/MI210
        gfx908)                echo "gfx908" ;;  # MI100
        gfx950)                echo "gfx950" ;;  # MI350+

        # RDNA3
        gfx1100|gfx1101|gfx1102|gfx1103) echo "gfx110x" ;;  # RX 7000 series
        gfx1150)               echo "gfx1150" ;;  # Ryzen AI 300
        gfx1151)               echo "gfx1151" ;;  # Ryzen AI Max
        gfx1152)               echo "gfx1152" ;;  # Krackan1 APU

        # RDNA4
        gfx1200|gfx1201)       echo "gfx120x" ;;  # RX 9070 series

        # Legacy/unsupported
        gfx900|gfx906|gfx909)  echo "unsupported" ;;  # Vega
        gfx1010|gfx1011|gfx1012|gfx1013) echo "unsupported" ;;  # RDNA1
        gfx1030|gfx1031|gfx1032|gfx1033|gfx1034|gfx1035|gfx1036) echo "unsupported" ;;  # RDNA2

        *)                     echo "unknown" ;;
    esac

    return 0
}

# Map PCI device ID to GFX architecture
# Device IDs from AMDGPU driver, ROCm metadata, and verified hardware
map_device_id_to_gfx() {
    local device_id="$1"

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
        7448|744c|7449|744a|744b|7470) echo "gfx1100" ;;
        # RDNA3 - RX 7800/7700
        7478|747e|746f|748f) echo "gfx1101" ;;
        # RDNA3 - RX 7600
        7480|7483|7487|745e|7460|7461|7489|7499) echo "gfx1102" ;;

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

        # RDNA4 - RX 9070 series
        7550|7551|7552|7553|7554|7555|7556|7557|7558|7559|755a|755b|755c|755d|755e|755f|7590)
            echo "gfx1200" ;;

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
        gfx_arch=$(map_device_id_to_gfx "$device_id")

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
        local pci_numeric
        pci_numeric=$(lspci -n -s "$pci_addr" 2>/dev/null)
        if [[ -n "$pci_numeric" ]]; then
            rev_id=$(echo "$pci_numeric" | grep -oP '\(rev \K[0-9a-f]{2}(?=\))' || echo "00")
            rev_id=${rev_id^^}
        fi

        local gfx_arch
        gfx_arch=$(map_device_id_to_gfx "$device_id")

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
        # shellcheck disable=SC2034
        while read -r pci_addr _pci_class _pci_vendor _pci_device pci_rest; do
            local rev
            rev=$(echo "$pci_rest" | grep -oP '\(rev \K[0-9a-f]{2}(?=\))' || echo "00")
            pci_revisions["$pci_addr"]="${rev^^}"
        done < <(lspci -n -d 1002: 2>/dev/null | grep -E "03[08]0:")

        while IFS= read -r line; do
            found_any=1
            gpu_count=$((gpu_count + 1))

            local pci_addr
            pci_addr=$(echo "$line" | awk '{print $1}')
            local device_id
            device_id=$(echo "$line" | grep -oP '\[1002:\K[0-9a-f]{4}(?=\])')
            local rev_id="${pci_revisions[$pci_addr]:-00}"
            local gfx_arch
            gfx_arch=$(map_device_id_to_gfx "$device_id" 2>/dev/null || echo "Unknown")
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
        gfx_arch=$(map_device_id_to_gfx "$device_id" 2>/dev/null || echo "Unknown")

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
            rev_id=$(sed 's/0x//' "$card/revision" 2>/dev/null | tr '[:lower:]' '[:upper:]')
        else
            rev_id="00"
        fi

        gfx_arch=$(map_device_id_to_gfx "$device_id" 2>/dev/null || echo "unknown")

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

        local pci_numeric
        pci_numeric=$(lspci -n -s "$pci_addr" 2>/dev/null)
        rev_id=$(echo "$pci_numeric" | grep -oP '\(rev \K[0-9a-f]{2}(?=\))' | tr '[:lower:]' '[:upper:]')
        [[ -z "$rev_id" ]] && rev_id="00"

        gfx_arch=$(map_device_id_to_gfx "$device_id" 2>/dev/null || echo "unknown")

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
    add_gpu "AMD Radeon RX 9070 XT" "7550" "01" "gfx1200"

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
