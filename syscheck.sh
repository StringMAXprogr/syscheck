#!/bin/bash

################################################################################
#                   🔥 UBUNTU SYSTEM CHECKER PRO v2.1 🔥                       #
#              Advanced Hacker-Grade System Monitoring Tool                    #
#                 Built for Linux Power Users & Sys Admins                     #
#                                                                              #
# Robust Edition with Error Handling, Timeouts & Data Validation               #
################################################################################

set -o pipefail
set -u

# Export LC_ALL für konsistentes Parsing
export LC_ALL=C

# Exit codes
readonly EXIT_OK=0
readonly EXIT_WARNING=1
readonly EXIT_CRITICAL=2

# ============================================================================
# COLOR SCHEME & STYLING
# ============================================================================

# Check if terminal supports colors
if [[ -t 1 ]] && [[ -n "${TERM:-}" ]]; then
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[1;34m'
    MAGENTA='\033[1;35m'
    CYAN='\033[1;36m'
    WHITE='\033[1;37m'
    GRAY='\033[0;37m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    WHITE=''
    GRAY=''
    BOLD=''
    DIM=''
    NC=''
fi

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

REPORT_DIR="$HOME/.system_checker"
REPORT_FILE=""
VERBOSE=0
COLORS_ENABLED=1
MODE="full"
START_TIME=$(date +%s)

# System metrics
SYSTEM_HEALTH=100
WARNINGS=0
CRITICAL_ISSUES=0

# Dependency tracking
declare -A DEPENDENCIES
declare -A MISSING_DEPS

# Cache for expensive operations
declare -A CACHE

# Global cached metrics
GLOBAL_CPU_USAGE=0
GLOBAL_CPU_CORES=0
declare -a GLOBAL_CORE_USAGE
GLOBAL_MEM_TOTAL=0
GLOBAL_MEM_FREE=0
GLOBAL_MEM_AVAILABLE=0
GLOBAL_MEM_USED=0
GLOBAL_MEM_PERCENT=0
GLOBAL_SWAP_TOTAL=0
GLOBAL_SWAP_FREE=0
GLOBAL_SWAP_USED=0
GLOBAL_SWAP_PERCENT=0
GLOBAL_UPGRADABLE=0
GLOBAL_SECURITY_UPDATES=0
GLOBAL_FIREWALL_STATUS="unknown"
GLOBAL_ZOMBIE_COUNT=0
GLOBAL_ZOMBIE_LIST=""
GLOBAL_APPARMOR_ENABLED=0

# Config and runtime state
CONFIG_FILE="$HOME/.config/syscheck/syscheck.conf"
HISTORY_FILE="$REPORT_DIR/history.json"
REPORT_JSON_FILE=""
QUIET=0
DEBUG=0
JSON_OUTPUT=0
LIVE_MODE=0
LIVE_INTERVAL=5
UPDATE_CHECK=1
SAVE_HISTORY=1
SHOW_PROFILE=1
RENDER_SECTION_TIMING=1
COMMAND_TIMEOUT=4
SLOW_TIMEOUT=10
CACHE_TTL=300
declare -A SECTION_TIMES

# ============================================================================
# DEPENDENCY MANAGEMENT
# ============================================================================

check_dependencies() {
    local required_deps=("cat" "grep" "awk" "sed" "cut" "head" "tail" "wc" "bc" "date" "timeout" "uname")
    local optional_deps=("sensors" "upower" "dmidecode" "lspci" "lsblk" "numfmt" "ss" "netstat" "snap" "python3")

    for dep in "${required_deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            MISSING_DEPS["$dep"]=1
            stat_warn "Missing required dependency: $dep"
        fi
    done

    for dep in "${optional_deps[@]}"; do
        DEPENDENCIES["$dep"]=$(command -v "$dep" &> /dev/null && echo 1 || echo 0)
    done
}

has_dep() {
    [[ "${DEPENDENCIES[$1]:-0}" == "1" ]]
}

safe_cmd() {
    local timeout_sec=${1:-5}
    shift
    timeout "$timeout_sec" "$@" 2>/dev/null || return 1
}

cache_command() {
    local key="$1"
    shift
    if [[ -n "${CACHE[$key]:-}" ]]; then
        printf '%s' "${CACHE[$key]}"
        return 0
    fi

    local output
    if output=$(timeout "$COMMAND_TIMEOUT" "$@" 2>/dev/null); then
        CACHE[$key]="$output"
        printf '%s' "$output"
        return 0
    fi

    CACHE[$key]=""
    return 1
}

cache_file() {
    local key="$1"
    local file="$2"
    if [[ -n "${CACHE[$key]:-}" ]]; then
        printf '%s' "${CACHE[$key]}"
        return 0
    fi
    if [[ -f "$file" ]]; then
        CACHE[$key]=$(cat "$file" 2>/dev/null || true)
        printf '%s' "${CACHE[$key]}"
        return 0
    fi
    CACHE[$key]=""
    return 1
}

profile_section_start() {
    local name="$1"
    SECTION_TIMES["$name,start"]=$(date +%s)
}

profile_section_end() {
    local name="$1"
    local start=${SECTION_TIMES["$name,start"]:-0}
    if [[ $start -gt 0 ]]; then
        local duration=$(( $(date +%s) - start ))
        SECTION_TIMES["$name,elapsed"]=$duration
        log_debug "Section '$name' took ${duration}s"
    fi
}

run_section() {
    local name="$1"
    shift
    profile_section_start "$name"
    "$@"
    profile_section_end "$name"
}

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'
}

load_config() {
    local config_source=""
    if [[ -f "$CONFIG_FILE" ]]; then
        config_source="$CONFIG_FILE"
    elif [[ -f /etc/syscheck.conf ]]; then
        config_source="/etc/syscheck.conf"
    fi

    if [[ -n "$config_source" ]]; then
        while IFS='=' read -r key value; do
            key=$(echo "$key" | tr -d '[:space:]')
            value=$(echo "$value" | sed 's/[[:space:]]*$//')
            case "$key" in
                update_check) UPDATE_CHECK="$value" ;; 
                live_interval) LIVE_INTERVAL="$value" ;; 
                json_output) JSON_OUTPUT="$value" ;; 
                debug) DEBUG="$value" ;; 
                quiet) QUIET="$value" ;; 
            esac
        done < <(grep -E '^[[:space:]]*[a-zA-Z_]+=' "$config_source" 2>/dev/null)
    fi
}

parse_cli_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_usage
                exit $EXIT_OK
                ;;
            --quick)
                MODE="quick"
                ;;
            --full)
                MODE="full"
                ;;
            --cpu)
                MODE="cpu"
                ;;
            --memory)
                MODE="memory"
                ;;
            --disk)
                MODE="disk"
                ;;
            --network)
                MODE="network"
                ;;
            --security)
                MODE="security"
                ;;
            --verbose)
                VERBOSE=1
                ;;
            --debug)
                VERBOSE=1
                DEBUG=1
                ;;
            --quiet)
                QUIET=1
                ;;
            --json)
                JSON_OUTPUT=1
                ;;
            --live)
                LIVE_MODE=1
                ;;
            --live-interval)
                shift
                LIVE_INTERVAL=${1:-5}
                ;;
            *)
                MODE="$1"
                ;;
        esac
        shift
    done
}

quiet_print() {
    [[ $QUIET -eq 1 ]] && return 0
    echo "$@"
}

# ============================================================================
# ROOT CHECK
# ============================================================================

check_root() {
    if [[ $EUID -eq 0 ]]; then
        HAVE_ROOT=1
    elif sudo -n true 2>/dev/null; then
        HAVE_ROOT=1
    else
        HAVE_ROOT=0
    fi
    HAVE_SUDO=$([[ $HAVE_ROOT -eq 1 && $EUID -ne 0 ]] && echo 1 || echo 0)
}

# ============================================================================
# IMPROVED LOGGING & ERROR HANDLING
# ============================================================================

log_debug() {
    [[ $VERBOSE -eq 1 ]] && echo "[DEBUG] $*" >&2
}

log_info() {
    echo "[INFO] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
    log_report "[ERROR] $*"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Initialize report directory
init_report_dir() {
    mkdir -p "$REPORT_DIR"
    REPORT_FILE="$REPORT_DIR/report_$(date +%Y%m%d_%H%M%S).log"
    REPORT_JSON_FILE="$REPORT_DIR/report_$(date +%Y%m%d_%H%M%S).json"
    HISTORY_FILE="$REPORT_DIR/history.json"
    touch "$REPORT_FILE"
}

# Logging function
log_report() {
    echo "$1" >> "$REPORT_FILE"
}

# Print header
print_header() {
    local title="$1"
    local width=76
    echo
    echo -e "${CYAN}${BOLD}┌$(printf '─%.0s' {1..74})┐${NC}"
    printf "${CYAN}${BOLD}│ %-72s │${NC}\n" "$title"
    echo -e "${CYAN}${BOLD}└$(printf '─%.0s' {1..74})┘${NC}"
    echo
    log_report "=== $title ==="
}

# Print section
print_section() {
    echo -e "${BLUE}${BOLD}▸ $1${NC}"
}

# Print status with icon
stat_ok() {
    echo -e "${GREEN}${BOLD}✓${NC} $1"
    log_report "[OK] $1"
}

stat_warn() {
    echo -e "${YELLOW}${BOLD}⚠${NC} $1"
    log_report "[WARN] $1"
    WARNINGS=$((WARNINGS+1))
}

stat_fail() {
    echo -e "${RED}${BOLD}✗${NC} $1"
    log_report "[FAIL] $1"
    CRITICAL_ISSUES=$((CRITICAL_ISSUES+1))
}

stat_info() {
    echo -e "${CYAN}●${NC} $1"
    log_report "[INFO] $1"
}

# Print value pair
print_item() {
    printf "  %-40s : ${CYAN}%s${NC}\n" "$1" "$2"
}

# Progress bar - FIXED: Proper error handling
progress_bar() {
    local current=$1
    local total=$2
    local width=${3:-30}
    
    # Validate inputs
    if ! [[ "$current" =~ ^[0-9]+$ ]]; then current=0; fi
    if ! [[ "$total" =~ ^[0-9]+$ ]]; then total=100; fi
    if [[ $total -eq 0 ]]; then
        printf "N/A"
        return 0
    fi
    
    local percentage=$((current * 100 / total))
    local filled=$((percentage * width / 100))
    
    # Cap values
    [[ $percentage -gt 100 ]] && percentage=100
    [[ $filled -gt $width ]] && filled=$width
    
    # Color based on percentage
    local color=$GREEN
    [[ $percentage -gt 75 ]] && color=$YELLOW
    [[ $percentage -gt 90 ]] && color=$RED
    
    printf "${color}"
    printf '['
    for ((i=0; i<filled; i++)); do printf '█'; done
    for ((i=filled; i<width; i++)); do printf '░'; done
    printf "] %3d%%${NC}" "$percentage"
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ $bytes -lt 1048576 ]]; then
        echo "$((bytes / 1024))KB"
    elif [[ $bytes -lt 1073741824 ]]; then
        echo "$((bytes / 1048576))MB"
    else
        echo "$((bytes / 1073741824))GB"
    fi
}

# ============================================================================
# SYSTEM INFORMATION
# ============================================================================

check_system_info() {
    print_header "🖥️  SYSTEM INFORMATION"
    
    print_item "Hostname" "$(hostname)"
    print_item "OS" "$(lsb_release -ds 2>/dev/null || echo 'Unknown')"
    print_item "Kernel" "$(uname -r)"
    print_item "Architecture" "$(uname -m)"
    print_item "Current Date/Time" "$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Uptime calculation
    local uptime_sec=$(cat /proc/uptime | awk '{print int($1)}')
    local days=$((uptime_sec / 86400))
    local hours=$(((uptime_sec % 86400) / 3600))
    local minutes=$(((uptime_sec % 3600) / 60))
    print_item "Uptime" "${days}d ${hours}h ${minutes}m"
    
    # CPU Info
    local cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
    local cpu_cores=$(grep -c "^processor" /proc/cpuinfo)
    print_item "CPU Model" "$cpu_model"
    print_item "CPU Cores" "$cpu_cores ($(nproc) available)"
    
    # Load average
    local load=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
    print_item "Load Average (1/5/15m)" "$load"
    
    stat_ok "System information retrieved"
}

# ============================================================================
# CPU MONITORING
# ============================================================================

cache_cpu_usage() {
    if [[ ${GLOBAL_CPU_CORES:-0} -gt 0 ]]; then
        return 0
    fi

    local stat1 stat2
    local total1 idle1 total2 idle2
    local core_lines1 core_lines2

    mapfile -t stat1 < <(grep '^cpu' /proc/stat 2>/dev/null)
    sleep 0.3
    mapfile -t stat2 < <(grep '^cpu' /proc/stat 2>/dev/null)

    if [[ ${#stat1[@]} -eq 0 || ${#stat2[@]} -eq 0 ]]; then
        GLOBAL_CPU_USAGE=0
        GLOBAL_CPU_CORES=0
        return 1
    fi

    read -r _ user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 _ < <(echo "${stat1[0]}")
    read -r _ user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 _ < <(echo "${stat2[0]}")

    total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1 + steal1))
    total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2))

    local delta_total=$((total2 - total1))
    local delta_idle=$((idle2 - idle1))
    if [[ $delta_total -gt 0 ]]; then
        GLOBAL_CPU_USAGE=$((100 * (delta_total - delta_idle) / delta_total))
    else
        GLOBAL_CPU_USAGE=0
    fi

    GLOBAL_CPU_CORES=$(grep -c '^cpu[0-9]' /proc/stat 2>/dev/null || echo 0)
    GLOBAL_CORE_USAGE=()
    for i in $(seq 1 $GLOBAL_CPU_CORES); do
        local line1=${stat1[$i]}
        local line2=${stat2[$i]}
        read -r _ cuser1 cnice1 csystem1 cidle1 ciowait1 cirq1 csoftirq1 csteal1 _ < <(echo "$line1")
        read -r _ cuser2 cnice2 csystem2 cidle2 ciowait2 cirq2 csoftirq2 csteal2 _ < <(echo "$line2")
        local ctotal1=$((cuser1 + cnice1 + csystem1 + cidle1 + ciowait1 + cirq1 + csoftirq1 + csteal1))
        local ctotal2=$((cuser2 + cnice2 + csystem2 + cidle2 + ciowait2 + cirq2 + csoftirq2 + csteal2))
        local cdelta_total=$((ctotal2 - ctotal1))
        local cdelta_idle=$((cidle2 - cidle1))
        local cperc=0
        if [[ $cdelta_total -gt 0 ]]; then
            cperc=$((100 * (cdelta_total - cdelta_idle) / cdelta_total))
        fi
        GLOBAL_CORE_USAGE+=($cperc)
    done
}

check_cpu_detailed() {
    print_header "⚡ CPU PERFORMANCE"

    cache_cpu_usage
    local cpu_usage=$GLOBAL_CPU_USAGE
    [[ ! "$cpu_usage" =~ ^[0-9]+$ ]] && cpu_usage=0

    print_section "Overall CPU Usage"
    printf "  "
    progress_bar "$cpu_usage" 100
    echo

    if [[ $cpu_usage -gt 80 ]]; then
        stat_warn "CPU usage HIGH: ${cpu_usage}%"
    else
        stat_ok "CPU usage normal: ${cpu_usage}%"
    fi
    
    # CPU frequency
    print_section "CPU Frequency"
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]]; then
        local freq_khz
        freq_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0")
        
        if [[ "$freq_khz" =~ ^[0-9]+$ ]] && [[ $freq_khz -gt 0 ]]; then
            local freq_ghz
            freq_ghz=$(echo "scale=2; $freq_khz / 1000000" | bc 2>/dev/null || echo "0")
            print_item "Current Frequency" "${freq_ghz} GHz"
            
            if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]]; then
                local max_khz
                max_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "0")
                if [[ "$max_khz" =~ ^[0-9]+$ ]] && [[ $max_khz -gt 0 ]]; then
                    local max_ghz
                    max_ghz=$(echo "scale=2; $max_khz / 1000000" | bc 2>/dev/null || echo "0")
                    print_item "Max Frequency" "${max_ghz} GHz"
                fi
            fi
        fi
    fi
    
    # Per-core usage - FIXED: Properly read /proc/stat
    print_section "Per-Core Usage"
    if [[ ${#GLOBAL_CORE_USAGE[@]} -gt 0 ]]; then
        for idx in "${!GLOBAL_CORE_USAGE[@]}"; do
            printf "  Core %d: %s%%\n" "$idx" "${GLOBAL_CORE_USAGE[$idx]}"
        done
    else
        stat_info "Could not read per-core usage"
    fi

    # Context switches
    local ctx_switches
    ctx_switches=$(grep ctxt /proc/stat 2>/dev/null | awk '{print $2}' || echo "0")
    if [[ "$ctx_switches" =~ ^[0-9]+$ ]]; then
        print_item "Context Switches" "$(numfmt --to=iec $ctx_switches 2>/dev/null || echo $ctx_switches)"
    fi
    
    log_report "CPU Usage: ${cpu_usage}%"
}

cache_memory_usage() {
    if [[ ${GLOBAL_MEM_TOTAL:-0} -gt 0 ]]; then
        return 0
    fi

    local meminfo
    meminfo=$(cat /proc/meminfo 2>/dev/null) || return 1

    GLOBAL_MEM_TOTAL=$(echo "$meminfo" | awk '/^MemTotal:/ {print $2; exit}' || echo "0")
    GLOBAL_MEM_FREE=$(echo "$meminfo" | awk '/^MemFree:/ {print $2; exit}' || echo "0")
    GLOBAL_MEM_AVAILABLE=$(echo "$meminfo" | awk '/^MemAvailable:/ {print $2; exit}' || echo "0")
    GLOBAL_SWAP_TOTAL=$(echo "$meminfo" | awk '/^SwapTotal:/ {print $2; exit}' || echo "0")
    GLOBAL_SWAP_FREE=$(echo "$meminfo" | awk '/^SwapFree:/ {print $2; exit}' || echo "0")

    for key in GLOBAL_MEM_TOTAL GLOBAL_MEM_FREE GLOBAL_MEM_AVAILABLE GLOBAL_SWAP_TOTAL GLOBAL_SWAP_FREE; do
        if ! [[ "${!key}" =~ ^[0-9]+$ ]]; then
            eval "$key=0"
        fi
    done

    GLOBAL_MEM_USED=$((GLOBAL_MEM_TOTAL - GLOBAL_MEM_FREE))
    if [[ $GLOBAL_MEM_TOTAL -gt 0 ]]; then
        GLOBAL_MEM_PERCENT=$((GLOBAL_MEM_USED * 100 / GLOBAL_MEM_TOTAL))
    else
        GLOBAL_MEM_PERCENT=0
    fi
    GLOBAL_SWAP_USED=$((GLOBAL_SWAP_TOTAL - GLOBAL_SWAP_FREE))
    if [[ $GLOBAL_SWAP_TOTAL -gt 0 ]]; then
        GLOBAL_SWAP_PERCENT=$((GLOBAL_SWAP_USED * 100 / GLOBAL_SWAP_TOTAL))
    else
        GLOBAL_SWAP_PERCENT=0
    fi
}

check_memory_detailed() {
    print_header "💾 MEMORY & SWAP"

    if ! cache_memory_usage; then
        stat_fail "Could not read memory information"
        return 1
    fi

    print_section "Physical RAM"
    echo -n "  "
    progress_bar "$GLOBAL_MEM_USED" "$GLOBAL_MEM_TOTAL"
    echo

    local mem_used_gb
    local mem_total_gb
    local mem_available_gb

    mem_used_gb=$(echo "scale=2; $GLOBAL_MEM_USED / 1048576" | bc 2>/dev/null || echo "0")
    mem_total_gb=$(echo "scale=2; $GLOBAL_MEM_TOTAL / 1048576" | bc 2>/dev/null || echo "0")
    mem_available_gb=$(echo "scale=2; $GLOBAL_MEM_AVAILABLE / 1048576" | bc 2>/dev/null || echo "0")

    print_item "Used" "${mem_used_gb} GB / ${mem_total_gb} GB"
    print_item "Available" "${mem_available_gb} GB"

    if [[ $GLOBAL_MEM_PERCENT -gt 90 ]]; then
        stat_warn "RAM usage CRITICAL: ${GLOBAL_MEM_PERCENT}%"
    elif [[ $GLOBAL_MEM_PERCENT -gt 75 ]]; then
        stat_warn "RAM usage HIGH: ${GLOBAL_MEM_PERCENT}%"
    else
        stat_ok "RAM usage normal: ${GLOBAL_MEM_PERCENT}%"
    fi

    if [[ $GLOBAL_SWAP_TOTAL -gt 0 ]]; then
        print_section "Swap Memory"
        echo -n "  "
        progress_bar "$GLOBAL_SWAP_USED" "$GLOBAL_SWAP_TOTAL"
        echo

        local swap_used_gb
        local swap_total_gb

        swap_used_gb=$(echo "scale=2; $GLOBAL_SWAP_USED / 1048576" | bc 2>/dev/null || echo "0")
        swap_total_gb=$(echo "scale=2; $GLOBAL_SWAP_TOTAL / 1048576" | bc 2>/dev/null || echo "0")

        print_item "Used" "${swap_used_gb} GB / ${swap_total_gb} GB"

        [[ $GLOBAL_SWAP_USED -gt 0 ]] && stat_warn "Swap in use: possible memory pressure" || stat_ok "Swap unused"
    else
        stat_info "No swap configured"
    fi

    print_section "Cache & Buffers"
    local buffers=$(grep '^Buffers:' /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    local cached=$(grep '^Cached:' /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")

    [[ ! "$buffers" =~ ^[0-9]+$ ]] && buffers=0
    [[ ! "$cached" =~ ^[0-9]+$ ]] && cached=0

    local buffers_gb=$(echo "scale=2; $buffers / 1048576" | bc 2>/dev/null || echo "0")
    local cached_gb=$(echo "scale=2; $cached / 1048576" | bc 2>/dev/null || echo "0")

    print_item "Buffers" "${buffers_gb} GB"
    print_item "Cached" "${cached_gb} GB"

    log_report "Memory: ${GLOBAL_MEM_PERCENT}% used"
}

# ============================================================================
# DISK ANALYSIS
# ============================================================================

check_disk_detailed() {
    print_header "💿 DISK USAGE & I/O"

    print_section "Mounted Filesystems"
    local df_data
    df_data=$(cache_command df_h df -h 2>/dev/null) || df_data=""

    printf '%s\n' "$df_data" | tail -n +2 | while read -r line; do
        [[ -z "$line" ]] && continue

        local usage mount device size used
        usage=$(printf '%s\n' "$line" | awk '{print $5}' | tr -d '%' || echo "0")
        mount=$(printf '%s\n' "$line" | awk '{print $6}' || echo "?")
        device=$(printf '%s\n' "$line" | awk '{print $1}' || echo "?")
        size=$(printf '%s\n' "$line" | awk '{print $2}' || echo "?")
        used=$(printf '%s\n' "$line" | awk '{print $3}' || echo "?")

        if ! [[ "$usage" =~ ^[0-9]+$ ]]; then
            usage=0
        fi

        [[ "$device" =~ ^/dev/loop ]] && continue

        printf "  %-30s " "${device:0:30}"
        echo -n "$(progress_bar "$usage" 100 20)"
        printf " %s / %s\n" "$used" "$size"

        if [[ $usage -gt 90 ]]; then
            echo -e "    ${RED}${BOLD}⚠ CRITICAL: ${mount} is ${usage}% full!${NC}"
        elif [[ $usage -gt 80 ]]; then
            echo -e "    ${YELLOW}${BOLD}⚠ WARNING: ${mount} is ${usage}% full${NC}"
        fi
    done

    print_section "Disk I/O Performance"
    if [[ -f /proc/diskstats ]]; then
        stat_info "Reading disk I/O statistics..."
        local read_ops write_ops
        read_ops=$(awk '{sum+=$4} END {print sum+0}' /proc/diskstats 2>/dev/null || echo "0")
        write_ops=$(awk '{sum+=$8} END {print sum+0}' /proc/diskstats 2>/dev/null || echo "0")
        
        print_item "Total Read Operations" "$(numfmt --to=iec $read_ops 2>/dev/null || echo $read_ops)"
        print_item "Total Write Operations" "$(numfmt --to=iec $write_ops 2>/dev/null || echo $write_ops)"
    fi
}

# ============================================================================
# NETWORK ANALYSIS
# ============================================================================

check_network_detailed() {
    print_header "🌐 NETWORK CONFIGURATION"

    local ip_data
    ip_data=$(cache_command ip_data ip -o addr show 2>/dev/null) || ip_data=""
    local ip_route
    ip_route=$(cache_command ip_route ip route 2>/dev/null) || ip_route=""

    print_section "Network Interfaces"
    local prev_iface=""
    printf '%s\n' "$ip_data" | awk '{
        iface=$2; sub(/:$/, "", iface);
        if ($3 == "inet") {
            print iface " IPV4 " $4;
        } else if ($3 == "inet6") {
            print iface " IPV6 " $4;
        }
    }' | while read -r iface type addr; do
        if [[ "$prev_iface" != "$iface" ]]; then
            echo -e "  ${CYAN}${BOLD}${iface}${NC}"
        fi
        if [[ "$type" == "IPV4" ]]; then
            echo "    IPv4: $addr"
        else
            echo "    IPv6: $addr"
        fi
        prev_iface="$iface"
    done || stat_warn "Could not read network interfaces"

    print_section "Network Statistics"
    local net_stats
    net_stats=$(cache_file net_dev /proc/net/dev 2>/dev/null) || net_stats=""
    if [[ -n "$net_stats" ]]; then
        printf '%s\n' "$net_stats" | tail -n +3 | awk '{
            bytes_recv += $2; packets_recv += $3; errs_recv += $4;
            bytes_sent += $10; packets_sent += $11; errs_sent += $12;
        }
        END {
            printf "  Bytes Received   : %.2f MB\n", bytes_recv/1048576
            printf "  Bytes Sent       : %.2f MB\n", bytes_sent/1048576
            printf "  Packets Received : %d\n", packets_recv
            printf "  Packets Sent     : %d\n", packets_sent
            printf "  Errors Received  : %d\n", errs_recv
            printf "  Errors Sent      : %d\n", errs_sent
        }'
    fi

    print_section "Network Connectivity"
    if timeout 2 ping -c 1 8.8.8.8 &> /dev/null; then
        stat_ok "Internet connectivity: ONLINE"
    else
        stat_warn "Internet connectivity: OFFLINE or UNREACHABLE"
    fi

    if [[ -f /etc/resolv.conf ]]; then
        echo -e "  ${BOLD}DNS Servers:${NC}"
        grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print "    " $2}' | head -3 || echo "    (none configured)"
    fi

    local gateway
    gateway=$(printf '%s\n' "$ip_route" | grep default | awk '{print $3}' | head -1 || echo "N/A")
    print_item "Default Gateway" "$gateway"

    print_section "Network Connections"
    local tcp_count=0 udp_count=0
    if has_dep ss; then
        tcp_count=$(timeout 2 ss -tn 2>/dev/null | tail -n +2 | wc -l || echo "0")
        udp_count=$(timeout 2 ss -un 2>/dev/null | tail -n +2 | wc -l || echo "0")
    else
        tcp_count=$(timeout 2 netstat -tn 2>/dev/null | tail -n +3 | wc -l || echo "0")
        udp_count=$(timeout 2 netstat -un 2>/dev/null | tail -n +3 | wc -l || echo "0")
    fi
    print_item "Active TCP Connections" "$tcp_count"
    print_item "Active UDP Connections" "$udp_count"
}

# ============================================================================
# PROCESS ANALYSIS
# ============================================================================

check_processes_detailed() {
    print_header "⚙️  PROCESS & TASK MANAGEMENT"

    local ps_data
    ps_data=$(cache_command ps_aux ps aux 2>/dev/null) || ps_data=""
    local self_pid=$$

    print_section "Process Statistics"
    local proc_count
    local running
    local sleeping

    proc_count=$(printf '%s\n' "$ps_data" | wc -l || echo "0")
    if [[ "$proc_count" =~ ^[0-9]+$ ]] && [[ $proc_count -gt 0 ]]; then
        proc_count=$((proc_count - 1))
    fi
    running=$(printf '%s\n' "$ps_data" | awk '$8 == "R" {count++} END {print count+0}' || echo "0")
    sleeping=$(printf '%s\n' "$ps_data" | awk '$8 == "S" {count++} END {print count+0}' || echo "0")

    print_item "Total Processes" "$proc_count"
    print_item "Running" "$running"
    print_item "Sleeping" "$sleeping"

    print_section "Top 10 CPU Consumers"
    echo
    printf '%s\n' "$ps_data" | tail -n +2 | awk -v selfpid="$self_pid" '$2 != selfpid' | sort -nrk3 | head -10 | \
        awk '{printf "  [%-6.1f%%] %-45s (PID: %5d)\n", $3, substr($11,1,45), $2}' | nl -v1 -w2 -s'. ' || stat_warn "Could not read CPU processes"

    print_section "Top 10 Memory Consumers"
    echo
    printf '%s\n' "$ps_data" | tail -n +2 | awk -v selfpid="$self_pid" '$2 != selfpid' | sort -nrk4 | head -10 | \
        awk '{printf "  [%-6.1f%%] %-45s (PID: %5d)\n", $4, substr($11,1,45), $2}' | nl -v1 -w2 -s'. ' || stat_warn "Could not read memory processes"

    GLOBAL_ZOMBIE_LIST=$(printf '%s\n' "$ps_data" | awk '$8 == "Z" {printf "%s %s\n", $2, $11}')
    GLOBAL_ZOMBIE_COUNT=$(printf '%s\n' "$GLOBAL_ZOMBIE_LIST" | awk 'NF {count++} END {print count+0}' || echo "0")
    if [[ -z "$GLOBAL_ZOMBIE_COUNT" ]] || ! [[ "$GLOBAL_ZOMBIE_COUNT" =~ ^[0-9]+$ ]]; then
        GLOBAL_ZOMBIE_COUNT=0
    fi

    if [[ $GLOBAL_ZOMBIE_COUNT -gt 0 ]]; then
        stat_warn "Found $GLOBAL_ZOMBIE_COUNT zombie process(es)"
        printf '%s\n' "$GLOBAL_ZOMBIE_LIST" | head -3 | while read -r pid name; do
            printf "    PID %s: %s\n" "$pid" "$name"
        done
    else
        stat_ok "No zombie processes"
    fi
}

# ============================================================================
# SECURITY CHECKS
# ============================================================================

check_security_detailed() {
    print_header "🔐 SECURITY & SYSTEM HARDENING"
    
    print_section "Firewall Status"
    GLOBAL_FIREWALL_STATUS="unknown"
    if command -v ufw &> /dev/null; then
        local fw_status
        fw_status=$(sudo -n ufw status 2>/dev/null | head -1 | awk '{print $2}')
        if [[ "$fw_status" == "active" ]]; then
            GLOBAL_FIREWALL_STATUS="active"
            stat_ok "Firewall: ACTIVE"
            echo "    Rules: $(sudo -n ufw status 2>/dev/null | tail -n +3 | wc -l) active"
        else
            GLOBAL_FIREWALL_STATUS="inactive"
            stat_info "Firewall inactive (common on desktops)"
        fi
    else
        GLOBAL_FIREWALL_STATUS="missing"
        stat_info "UFW not installed"
    fi
    
    print_section "SSH Security"
    if systemctl is-active ssh &> /dev/null || systemctl is-active sshd &> /dev/null; then
        stat_ok "SSH Service: RUNNING"
        
        local ssh_port=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
        print_item "SSH Port" "${ssh_port:-22}"
        
        local pwd_auth=$(grep "^PasswordAuthentication" /etc/ssh/sshd_config | awk '{print $2}')
        [[ "$pwd_auth" == "no" ]] && stat_ok "Password auth disabled" || stat_warn "Password authentication enabled"
        
        local root_login=$(grep "^PermitRootLogin" /etc/ssh/sshd_config | awk '{print $2}')
        [[ "$root_login" == "no" ]] && stat_ok "Root login disabled" || stat_warn "Root login enabled"
    else
        stat_warn "SSH Service: STOPPED"
    fi
    
    print_section "Failed Login Attempts"
    if [[ -f /var/log/auth.log ]]; then
        local failed
        failed=$(sudo -n grep -c "Failed password" /var/log/auth.log 2>/dev/null || echo "0")
        if [[ $failed -gt 100 ]]; then
            stat_warn "$failed failed login attempts"
        elif [[ $failed -gt 0 ]]; then
            stat_warn "$failed failed login attempts"
        else
            stat_ok "No failed login attempts"
        fi
    fi
    
    print_section "Sudo Access"
    if sudo -l &> /dev/null 2>&1; then
        stat_ok "Sudo privileges: Available"
    else
        stat_warn "Sudo privileges: Not available"
    fi
    
    print_section "File Integrity"
    # FIXED: Exclude common false positives
    local world_writable
    world_writable=$(timeout 10 find / -type f -perm -002 2>/dev/null | \
        grep -v "^/tmp/" | \
        grep -v "^/proc/" | \
        grep -v "^/sys/" | \
        grep -v "^/run/" | \
        grep -v "^/snap/" | \
        grep -v "^/dev/" | \
        wc -l) || world_writable="0"
    
    if ! [[ "$world_writable" =~ ^[0-9]+$ ]]; then
        world_writable=0
    fi
    
    if [[ $world_writable -gt 50 ]]; then
        stat_fail "Found $world_writable world-writable files (security risk)"
    elif [[ $world_writable -gt 0 ]]; then
        stat_warn "Found $world_writable world-writable files"
    else
        stat_ok "World-writable file count acceptable"
    fi
    
    print_section "SELinux / AppArmor"
    if command -v getenforce &> /dev/null; then
        local selinux=$(getenforce 2>/dev/null || echo "Disabled")
        print_item "SELinux" "$selinux"
    elif aa-status &> /dev/null 2>&1; then
        stat_ok "AppArmor: ENABLED"
    else
        stat_info "SELinux/AppArmor: Not detected (optional)"
    fi
}

# ============================================================================
# PACKAGE & UPDATES
# ============================================================================

check_updates_detailed() {
    print_header "📦 PACKAGE MANAGEMENT & UPDATES"

    if [[ $UPDATE_CHECK -ne 1 ]]; then
        stat_info "Update checks disabled in configuration"
        return 0
    fi

    print_section "Update Status"
    if [[ $MODE == "quick" ]]; then
        stat_info "Skipping full apt update in quick mode"
    elif [[ $HAVE_ROOT -eq 1 ]]; then
        timeout $SLOW_TIMEOUT sudo apt update -qq &>/dev/null || stat_warn "Could not refresh package lists"
    fi

    local upgrade_list
    upgrade_list=$(cache_command apt_upgradable timeout 8 apt list --upgradable 2>/dev/null || echo "")
    GLOBAL_UPGRADABLE=$(printf '%s' "$upgrade_list" | tail -n +2 | wc -l)
    [[ ! "$GLOBAL_UPGRADABLE" =~ ^[0-9]+$ ]] && GLOBAL_UPGRADABLE=0

    if [[ $GLOBAL_UPGRADABLE -eq 0 ]]; then
        stat_ok "System is up-to-date"
    elif [[ $GLOBAL_UPGRADABLE -lt 10 ]]; then
        stat_warn "$GLOBAL_UPGRADABLE packages available for upgrade"
    else
        stat_fail "MANY updates available: $GLOBAL_UPGRADABLE packages"
    fi

    print_section "Security Updates"
    GLOBAL_SECURITY_UPDATES=$(printf '%s' "$upgrade_list" | grep -i security | wc -l 2>/dev/null || echo "0")
    [[ ! "$GLOBAL_SECURITY_UPDATES" =~ ^[0-9]+$ ]] && GLOBAL_SECURITY_UPDATES=0

    if [[ $GLOBAL_SECURITY_UPDATES -gt 0 ]]; then
        stat_warn "$GLOBAL_SECURITY_UPDATES security updates available"
    else
        stat_ok "No outstanding security updates"
    fi
    
    # Package statistics
    print_section "Package Statistics"
    local total_packages
    local held_packages
    
    total_packages=$(dpkg -l 2>/dev/null | grep "^ii" | wc -l) || total_packages="0"
    held_packages=$(timeout 5 apt-mark showhold 2>/dev/null | wc -l) || held_packages="0"
    
    print_item "Total Installed Packages" "$total_packages"
    print_item "Held Packages" "$held_packages"
    
    # Snap packages
    if has_dep snap; then
        local snap_count
        snap_count=$(timeout 5 snap list 2>/dev/null | tail -n +2 | wc -l) || snap_count="0"
        print_item "Snap Packages" "$snap_count"
    fi
}

# ============================================================================
# SERVICES & DAEMONS
# ============================================================================

check_services_detailed() {
    print_header "🔧 SYSTEM SERVICES & DAEMONS"
    
    print_section "Critical System Services"
    
    # FIXED: Use correct service names
    local critical_services=(
        "ssh:SSH Server"
        "sshd:SSH Daemon"
        "cron:Cron Scheduler"
        "systemd-resolved:DNS Resolution"
        "systemd-logind:Login Manager"
        "dbus:System Bus"
        "NetworkManager:Network Manager:optional"
        "rsyslog:System Logging"
    )
    
    for service_entry in "${critical_services[@]}"; do
        IFS=':' read -r service description optional <<< "$service_entry"
        
        if timeout 2 systemctl is-active "$service" &> /dev/null 2>&1; then
            stat_ok "$description: RUNNING"
        else
            if [[ "${optional:-}" == "optional" ]]; then
                stat_info "$description: INACTIVE (optional)"
            else
                stat_warn "$description: STOPPED/INACTIVE"
            fi
        fi
    done
    
    print_section "Service Details"
    timeout 5 systemctl list-units --type=service --state=running --no-pager 2>/dev/null | tail -n +2 | head -15 | awk '{printf "  ✓ %s\n", $1}' | sed 's/\.service//' || stat_info "Could not list services"
}

# ============================================================================
# HARDWARE INFORMATION
# ============================================================================

check_hardware_detailed() {
    print_header "🛠️  HARDWARE INFORMATION"
    
    print_section "CPU Details"
    cat /proc/cpuinfo | head -15 | grep -E "vendor_id|model name|cpu cores|cpu MHz" | awk -F: '{printf "  %-20s: %s\n", substr($1,1,20), $2}'
    
    print_section "Memory Modules"
    if command -v dmidecode &> /dev/null; then
        sudo -n dmidecode -t memory 2>/dev/null | grep -A 2 "Memory Device" | head -10 | sed 's/^/  /'
    else
        stat_info "dmidecode not available (run with sudo for details)"
    fi
    
    print_section "Storage Devices"
    if command -v lsblk &> /dev/null; then
        lsblk -d -o NAME,SIZE,TYPE 2>/dev/null | tail -n +2 | grep -v '^loop' | awk '{printf "  %-15s %8s  %s\n", $1, $2, $3}'
    fi

    print_section "PCI Devices"
    if command -v lspci &> /dev/null; then
        lspci 2>/dev/null | head -8 | awk '{print "  " substr($0, 1, 100)}'
    fi
}

# ============================================================================
# TEMPERATURE & POWER
# ============================================================================

check_temperature_detailed() {
    print_header "🌡️  TEMPERATURE & POWER"
    
    print_section "Thermal Sensors"
    if command -v sensors &> /dev/null; then
        sensors 2>/dev/null | grep "°C" | head -10 | awk '{printf "  %-35s %s\n", substr($1,1,35), $2}' || stat_info "No thermal sensors detected"
    else
        stat_info "lm-sensors not installed (run: sudo apt install lm-sensors)"
    fi
    
    print_section "CPU Throttling"
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        local turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
        [[ $turbo -eq 0 ]] && stat_ok "Turbo boost: ENABLED" || stat_info "Turbo boost: DISABLED"
    fi
    
    print_section "Power Settings"
    if command -v upower &> /dev/null; then
        upower -e 2>/dev/null | grep -E "Device:|percentage:|state:" | head -10 | sed 's/^/  /'
    else
        stat_info "upower not available"
    fi
}

# ============================================================================
# SYSTEM LOGS ANALYSIS
# ============================================================================

check_logs_analysis() {
    print_header "📋 SYSTEM LOG ANALYSIS"

    print_section "Recent Kernel Errors"
    if [[ -f /var/log/kern.log ]]; then
        local kern_errors
        if [[ $HAVE_ROOT -eq 1 ]]; then
            kern_errors=$(timeout 4 sudo -n grep -i "error" /var/log/kern.log 2>/dev/null | tail -5) || kern_errors=""
        else
            kern_errors=$(timeout 4 grep -i "error" /var/log/kern.log 2>/dev/null | tail -5) || kern_errors=""
        fi

        if [[ -n "$kern_errors" ]]; then
            echo "$kern_errors" | head -5 | sed 's/^/  /'
        else
            stat_ok "No recent kernel errors"
        fi
    else
        stat_info "/var/log/kern.log not found"
    fi

    print_section "System Service Failures"
    local journal_errors
    journal_errors=$(cache_command journal_errors journalctl --no-pager -p err..crit -n 10 --since "1 hour ago" 2>/dev/null || echo "")
    if [[ -n "$journal_errors" ]]; then
        printf '%s\n' "$journal_errors" | awk '{print "  " substr($0,1,80)}' | head -10
    else
        stat_info "No critical service failures recorded"
    fi

    print_section "Boot Messages"
    timeout 3 dmesg 2>/dev/null | tail -20 | grep -i "error\|warning" | head -5 | sed 's/^/  /' || stat_ok "No boot warnings/errors detected"
}

# ============================================================================
# SYSTEM PERFORMANCE METRICS
# ============================================================================

check_performance_metrics() {
    print_header "📊 PERFORMANCE METRICS"

    print_section "I/O Wait"
    local top_data
    top_data=$(cache_command top_data top -bn1 2>/dev/null || echo "")
    local io_wait
    io_wait=$(printf '%s\n' "$top_data" | grep "Cpu(s)" | awk '{print $12}' | cut -d's' -f1) || io_wait="0"

    if ! [[ "$io_wait" =~ ^[0-9.]+$ ]]; then
        io_wait="0"
    fi
    print_item "I/O Wait Time" "${io_wait}%"
    if (( $(echo "$io_wait > 20" | bc -l 2>/dev/null || echo 0) )); then
        stat_warn "High I/O wait detected"
    fi

    print_section "Virtual Memory"
    local vmstat_data
    vmstat_data=$(safe_cmd 3 vmstat 1 2 2>/dev/null || true)
    if [[ -n "$vmstat_data" ]]; then
        printf '%s\n' "$vmstat_data" | tail -1 | awk '{
            printf "  %-35s : %s\n", "Free Memory (KB)", $4
            printf "  %-35s : %s\n", "Swap In (blocks/s)", $8
            printf "  %-35s : %s\n", "Swap Out (blocks/s)", $9
        }'
    else
        stat_info "Could not read vmstat"
    fi

    print_section "System Calls (Active Process Info)"
    local proc_count
    local running_procs
    local ps_data
    ps_data=$(cache_command ps_aux ps aux 2>/dev/null) || ps_data=""
    proc_count=$(printf '%s\n' "$ps_data" | wc -l || echo "0")
    running_procs=$(printf '%s\n' "$ps_data" | awk '$8 == "R" {count++} END {print count+0}' || echo "0")

    print_item "Total Processes" "$proc_count"
    print_item "Running Processes" "$running_procs"
}

# ============================================================================
# SYSTEM HEALTH SCORE
# ============================================================================

calculate_health_score() {
    print_header "💪 SYSTEM HEALTH SCORE"

    SYSTEM_HEALTH=100
    cache_cpu_usage
    cache_memory_usage

    local cpu_usage=$GLOBAL_CPU_USAGE
    [[ ! "$cpu_usage" =~ ^[0-9]+$ ]] && cpu_usage=0
    local mem_usage=$GLOBAL_MEM_PERCENT
    [[ ! "$mem_usage" =~ ^[0-9]+$ ]] && mem_usage=0
    local upgradeable=$GLOBAL_UPGRADABLE
    [[ ! "$upgradeable" =~ ^[0-9]+$ ]] && upgradeable=0

    local cpu_penalty=0
    local mem_penalty=0
    local disk_penalty=0
    local net_penalty=0
    local update_penalty=0
    local security_penalty=0
    local process_penalty=0

    if [[ $cpu_usage -gt 90 ]]; then
        cpu_penalty=18
    elif [[ $cpu_usage -gt 80 ]]; then
        cpu_penalty=10
    elif [[ $cpu_usage -gt 70 ]]; then
        cpu_penalty=4
    fi

    if [[ $mem_usage -gt 90 ]]; then
        mem_penalty=18
    elif [[ $mem_usage -gt 80 ]]; then
        mem_penalty=10
    elif [[ $mem_usage -gt 70 ]]; then
        mem_penalty=4
    fi

    if [[ $GLOBAL_UPGRADABLE -gt 0 ]]; then
        update_penalty=8
        [[ $GLOBAL_UPGRADABLE -gt 25 ]] && update_penalty=$((update_penalty + 7))
    fi

    if [[ $GLOBAL_SECURITY_UPDATES -gt 0 ]]; then
        security_penalty=14
    fi

    if [[ $GLOBAL_FIREWALL_STATUS == "inactive" ]]; then
        net_penalty=$((net_penalty + 2))
    fi
    if [[ $GLOBAL_FIREWALL_STATUS == "missing" ]]; then
        net_penalty=$((net_penalty + 1))
    fi

    if [[ $GLOBAL_ZOMBIE_COUNT -gt 0 ]]; then
        process_penalty=$((GLOBAL_ZOMBIE_COUNT * 4))
    fi

    SYSTEM_HEALTH=$((SYSTEM_HEALTH - cpu_penalty - mem_penalty - disk_penalty - net_penalty - update_penalty - security_penalty - process_penalty - CRITICAL_ISSUES * 12 - WARNINGS * 2))
    [[ $SYSTEM_HEALTH -lt 0 ]] && SYSTEM_HEALTH=0
    [[ $SYSTEM_HEALTH -gt 100 ]] && SYSTEM_HEALTH=100

    printf "  Overall Health Score: "
    if [[ $SYSTEM_HEALTH -ge 85 ]]; then
        echo -e "${GREEN}${BOLD}$SYSTEM_HEALTH%${NC} - EXCELLENT"
    elif [[ $SYSTEM_HEALTH -ge 70 ]]; then
        echo -e "${GREEN}${BOLD}$SYSTEM_HEALTH%${NC} - GOOD"
    elif [[ $SYSTEM_HEALTH -ge 50 ]]; then
        echo -e "${YELLOW}${BOLD}$SYSTEM_HEALTH%${NC} - FAIR"
    else
        echo -e "${RED}${BOLD}$SYSTEM_HEALTH%${NC} - POOR"
    fi

    echo -n "  "
    progress_bar "$SYSTEM_HEALTH" 100 50
    echo

    echo
    print_section "Summary Statistics"
    print_item "Critical Issues" "$CRITICAL_ISSUES"
    print_item "Warnings" "$WARNINGS"
    print_item "CPU Usage" "$cpu_usage%"
    print_item "Memory Usage" "$mem_usage%"
    print_item "Pending Updates" "$upgradeable"
    print_item "Security Updates" "$GLOBAL_SECURITY_UPDATES"
    print_item "Zombie Processes" "$GLOBAL_ZOMBIE_COUNT"

    log_report ""
    log_report "=== HEALTH SCORE ==="
    log_report "Overall Health: $SYSTEM_HEALTH%"
    log_report "Critical Issues: $CRITICAL_ISSUES"
    log_report "Warnings: $WARNINGS"
}

# ============================================================================
# REPORT GENERATION
# ============================================================================

generate_final_report() {
    print_section "Generating comprehensive report..."

    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))

    log_report ""
    log_report "=== SCAN COMPLETED ==="
    log_report "Scan Duration: ${duration}s"
    log_report "Final Health Score: $SYSTEM_HEALTH%"
    log_report "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"

    if [[ $JSON_OUTPUT -eq 1 ]]; then
        write_json_report "$duration"
    fi

    if [[ $SAVE_HISTORY -eq 1 ]]; then
        save_history "$duration"
    fi

    echo
    echo -e "${GREEN}${BOLD}✓ Report saved: $REPORT_FILE${NC}"
    echo -e "   ($(wc -l < "$REPORT_FILE") lines)"
    [[ $JSON_OUTPUT -eq 1 ]] && echo -e "   JSON: $REPORT_JSON_FILE"
}

write_json_report() {
    local duration="$1"
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    cat > "$REPORT_JSON_FILE" <<EOF
{
  "timestamp": "$ts",
  "duration_seconds": $duration,
  "health_score": $SYSTEM_HEALTH,
  "warnings": $WARNINGS,
  "critical_issues": $CRITICAL_ISSUES,
  "cpu_usage": $GLOBAL_CPU_USAGE,
  "memory_usage": $GLOBAL_MEM_PERCENT,
  "pending_updates": $GLOBAL_UPGRADABLE,
  "security_updates": $GLOBAL_SECURITY_UPDATES,
  "zombie_processes": $GLOBAL_ZOMBIE_COUNT,
  "firewall_status": "${GLOBAL_FIREWALL_STATUS}",
  "mode": "${MODE}"
}
EOF
}

save_history() {
    local duration="$1"
    local entry
    entry=$(cat <<EOF
{
  "timestamp": "$(date '+%Y-%m-%dT%H:%M:%S%z')",
  "duration_seconds": $duration,
  "health_score": $SYSTEM_HEALTH,
  "cpu_usage": $GLOBAL_CPU_USAGE,
  "memory_usage": $GLOBAL_MEM_PERCENT,
  "pending_updates": $GLOBAL_UPGRADABLE,
  "security_updates": $GLOBAL_SECURITY_UPDATES,
  "zombie_processes": $GLOBAL_ZOMBIE_COUNT
}
EOF
)
    if [[ ! -f "$HISTORY_FILE" ]]; then
        printf '[\n%s\n]' "$entry" > "$HISTORY_FILE"
    else
        python3 - <<PY
import json, pathlib
path = pathlib.Path('$HISTORY_FILE')
try:
    data = json.loads(path.read_text())
except Exception:
    data = []
if not isinstance(data, list):
    data = []
entry = json.loads('''$entry''')
data.append(entry)
path.write_text(json.dumps(data, indent=2))
PY
    fi
}

show_profile_summary() {
    if [[ $SHOW_PROFILE -ne 1 ]]; then
        return
    fi
    echo
    echo -e "${MAGENTA}${BOLD}Section timing summary:${NC}"
    for key in "${!SECTION_TIMES[@]}"; do
        if [[ "$key" == *,elapsed ]]; then
            local section=${key%,elapsed}
            local elapsed=${SECTION_TIMES[$key]}
            printf "  %-18s : %ss\n" "$section" "$elapsed"
        fi
    done | sort -k3 -nr
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

show_banner() {
    clear
    echo -e "${RED}${BOLD}"
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                        ║"
    echo "║        🔥 UBUNTU SYSTEM CHECKER PRO v2.0 - HACKER EDITION 🔥           ║"
    echo "║                 Advanced Linux System Monitoring Tool                  ║"
    echo "║                                                                        ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
}

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --help, -h         Show this help message"
    echo "  --quick            Quick system check (basic metrics)"
    echo "  --full             Full system check (default)"
    echo "  --cpu              CPU analysis only"
    echo "  --memory           Memory analysis only"
    echo "  --disk             Disk analysis only"
    echo "  --network          Network analysis only"
    echo "  --security         Security checks only"
    echo "  --verbose          Verbose output"
    echo "  --debug            Debug mode (verbose + internal tracing)"
    echo "  --quiet            Quiet mode (minimal console output)"
    echo "  --json             Export JSON report"
    echo "  --live             Live mode (repeat every interval)"
    echo "  --live-interval N  Live mode interval in seconds"
    echo ""
    echo "Examples:"
    echo "  sudo $0 --full            # Full check with elevated privileges"
    echo "  $0 --quick               # Faster quick check"
    echo "  $0 --json                # Save JSON summary"
    echo "  $0 --live --live-interval 10  # Live refresh mode"
    echo ""
    echo "Note: Some features require sudo/root privileges:"
    echo "  - Firewall status (ufw)"
    echo "  - SSH configuration"
    echo "  - Kernel logs"
    echo "  - Security updates"
}

run_mode() {
    case "$MODE" in
        quick)
            run_section "System Info" check_system_info
            run_section "CPU" check_cpu_detailed
            run_section "Memory" check_memory_detailed
            ;;
        cpu)
            run_section "System Info" check_system_info
            run_section "CPU" check_cpu_detailed
            ;;
        memory)
            run_section "System Info" check_system_info
            run_section "Memory" check_memory_detailed
            ;;
        disk)
            run_section "Disk" check_disk_detailed
            ;;
        network)
            run_section "Network" check_network_detailed
            ;;
        security)
            run_section "Security" check_security_detailed
            ;;
        full|*)
            run_section "System Info" check_system_info
            run_section "CPU" check_cpu_detailed
            run_section "Memory" check_memory_detailed
            run_section "Disk" check_disk_detailed
            run_section "Network" check_network_detailed
            run_section "Processes" check_processes_detailed
            run_section "Security" check_security_detailed
            run_section "Updates" check_updates_detailed || true
            run_section "Services" check_services_detailed
            run_section "Hardware" check_hardware_detailed || true
            run_section "Temperature" check_temperature_detailed || true
            run_section "Logs" check_logs_analysis || true
            run_section "Performance" check_performance_metrics
            run_section "Health" calculate_health_score
            ;;
    esac
}

main() {
    load_config
    parse_cli_args "$@"
    init_report_dir
    check_dependencies
    check_root

    if [[ $QUIET -eq 0 ]]; then
        show_banner
    fi

    if [[ $VERBOSE -eq 1 ]]; then
        echo -e "${DIM}Dependencies ready. Have root: $HAVE_ROOT, mode: $MODE${NC}\n"
    fi

    if [[ $LIVE_MODE -eq 1 ]]; then
        while true; do
            init_report_dir
            run_mode
            generate_final_report
            show_profile_summary
            sleep "$LIVE_INTERVAL"
        done
        return
    fi
    
    run_mode
    generate_final_report
    show_profile_summary

    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    
    echo
    echo -e "${CYAN}${BOLD}Scan completed in ${duration}s${NC}\n"
    
    # Exit with appropriate code
    if [[ $CRITICAL_ISSUES -gt 0 ]]; then
        exit $EXIT_CRITICAL
    elif [[ $WARNINGS -gt 0 ]]; then
        exit $EXIT_WARNING
    else
        exit $EXIT_OK
    fi
}

# Trap for cleanup
trap 'echo -e "\n${YELLOW}Interrupted by user${NC}"; exit 130' INT TERM

# Run main function
main "$@"
