#!/bin/bash
#
# edge-bringup.sh — VRF / loopback bring-up + FRR verification
#                   + Docker purge + IPv6 RA/SLAAC lockdown
#                   + VRF l3mdev_accept + IPv6 disable_ipv6 recovery
#                   + aggressive legacy-loopback purge
#                   + data-driven multi-VRF topology
#                   + stale-IP reconciliation on dummy loopbacks
#                   + -l listing mode + interactive confirmation
#
# ============================================================================
# CLI OPTIONS:
#   -l, --list     List all supported environment variables with their
#                  default values and current (effective) values, then exit.
#   -y, --yes      Skip the interactive confirmation prompt.
#   -h, --help     Show usage.
# ============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

############################
# CLI ARG PARSING (before any config evaluation)
############################

MODE_LIST=0
MODE_YES=0

for arg in "$@"; do
    case "$arg" in
        -l|--list)   MODE_LIST=1 ;;
        -y|--yes)    MODE_YES=1 ;;
        -h|--help)
            cat <<EOF
Usage: sudo $SCRIPT_NAME [options]

Options:
  -l, --list     List all supported environment variables (with defaults
                 and effective values) and exit.
  -y, --yes      Skip the interactive confirmation prompt.
  -h, --help     Show this help.

Environment variables:
  Run '$SCRIPT_NAME -l' to see the full list with defaults.

Example:
  sudo MGMT_IFACE=ens224 VRF10_IFACE=ens192 VRF20_IFACE=ens256 \\
       SUBNET_OCTET=110 $SCRIPT_NAME
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Use -h for help." >&2
            exit 2
            ;;
    esac
done

############################
# ENV VAR METADATA (single source of truth)
############################
#
# Each entry describes one overridable variable so that:
#   - '-l' can list it
#   - The confirmation screen can show default vs effective
#   - The script stays self-documenting
#
# Format: "VAR_NAME|DEFAULT|DESCRIPTION"

ENV_VARS_META=(
"MGMT_IFACE|ens224|Management NIC (default route iface). NEVER modified."
"SUBNET_OCTET|110|Third octet used in loopback and NIC addressing (e.g. 110=Madrid, 113=Beijing, 114=Paris)."
"HOST_OCTET|200|Host part for physical NIC addresses (e.g. 192.168.X.200)."
"VRF10_IFACE|-|Physical NIC to place in vrf10 (use '-' or leave unset to skip)."
"VRF10_V4|(auto)|IPv4 for the vrf10 NIC. Auto-derived if not set."
"VRF10_V6|(auto)|IPv6 for the vrf10 NIC. Auto-derived if not set."
"VRF20_IFACE|-|Physical NIC to place in vrf20 (use '-' or leave unset to skip)."
"VRF20_V4|(auto)|IPv4 for the vrf20 NIC. Auto-derived if not set."
"VRF20_V6|(auto)|IPv6 for the vrf20 NIC. Auto-derived if not set."
"VRF30_IFACE|-|Physical NIC to place in vrf30 (use '-' or leave unset to skip)."
"VRF30_V4|(auto)|IPv4 for the vrf30 NIC. Auto-derived if not set."
"VRF30_V6|(auto)|IPv6 for the vrf30 NIC. Auto-derived if not set."
"VRF_EXCLUDE||Space-separated list of VRFs to skip entirely (e.g. 'vrf20')."
"LEGACY_LOOPBACK_REMOVE_FROM_VRF|yes|If 'yes', purge legacy lo0..lo9 even if enslaved to a VRF."
"DOCKER_CLEANUP_MODE|purge|Docker disposition: 'none' | 'stop' | 'purge'."
"FRR_FORCE_RESTART|0|Set to '1' to force restart FRR even if already healthy."
"FRR_PRE_START_WAIT|5|Seconds to wait before starting/verifying FRR."
"FRR_POST_START_WAIT|5|Seconds to wait after starting FRR for daemons to init."
"FRR_DAEMON_CHECK_RETRIES|6|Number of poll attempts per daemon check."
"FRR_DAEMON_CHECK_INTERVAL|2|Seconds between daemon-check polls."
)

############################
# DEFAULTS (applied only if env var is unset)
############################

MGMT_IFACE="${MGMT_IFACE:-ens224}"
SUBNET_OCTET="${SUBNET_OCTET:-110}"
HOST_OCTET="${HOST_OCTET:-200}"

VRF_EXCLUDE="${VRF_EXCLUDE:-}"
LEGACY_LOOPBACK_REMOVE_FROM_VRF="${LEGACY_LOOPBACK_REMOVE_FROM_VRF:-yes}"
DOCKER_CLEANUP_MODE="${DOCKER_CLEANUP_MODE:-purge}"

FRR_FORCE_RESTART="${FRR_FORCE_RESTART:-0}"
FRR_PRE_START_WAIT="${FRR_PRE_START_WAIT:-5}"
FRR_POST_START_WAIT="${FRR_POST_START_WAIT:-5}"
FRR_DAEMON_CHECK_RETRIES="${FRR_DAEMON_CHECK_RETRIES:-6}"
FRR_DAEMON_CHECK_INTERVAL="${FRR_DAEMON_CHECK_INTERVAL:-2}"
FRR_MANDATORY_DAEMONS=(zebra)

# VRF-specific NIC defaults (initialized to '-' and filled in via env overrides)
VRF10_IFACE="${VRF10_IFACE:--}"
VRF20_IFACE="${VRF20_IFACE:--}"
VRF30_IFACE="${VRF30_IFACE:--}"

VRF10_V4="${VRF10_V4:-192.168.${SUBNET_OCTET}.${HOST_OCTET}/24}"
VRF10_V6="${VRF10_V6:-2002:c0a8:$(printf '6e%02x' $SUBNET_OCTET)::${HOST_OCTET}/64}"
VRF20_V4="${VRF20_V4:-172.20.${SUBNET_OCTET}.${HOST_OCTET}/24}"
VRF20_V6="${VRF20_V6:-2002:ac14:$(printf '6e%02x' $SUBNET_OCTET)::${HOST_OCTET}/64}"
VRF30_V4="${VRF30_V4:-172.30.${SUBNET_OCTET}.${HOST_OCTET}/24}"
VRF30_V6="${VRF30_V6:-2002:ac1e:$(printf '71%02x' $SUBNET_OCTET)::${HOST_OCTET}/64}"

############################
# LISTING / CONFIRMATION HELPERS
############################

# Returns the original default value for a given variable name.
# Re-derives auto-derived defaults so that '-l' and the confirmation
# screen show the current effective default.
_default_for() {
    local key=$1
    case "$key" in
        MGMT_IFACE)                         echo "ens224" ;;
        SUBNET_OCTET)                       echo "110" ;;
        HOST_OCTET)                         echo "200" ;;
        VRF10_IFACE|VRF20_IFACE|VRF30_IFACE) echo "-" ;;
        VRF10_V4)                           echo "192.168.110.200/24 (auto)" ;;
        VRF10_V6)                           echo "2002:c0a8:6e6e::200/64 (auto)" ;;
        VRF20_V4)                           echo "172.20.110.200/24 (auto)" ;;
        VRF20_V6)                           echo "2002:ac14:6e6e::200/64 (auto)" ;;
        VRF30_V4)                           echo "172.30.110.200/24 (auto)" ;;
        VRF30_V6)                           echo "2002:ac1e:716e::200/64 (auto)" ;;
        VRF_EXCLUDE)                        echo "(empty)" ;;
        LEGACY_LOOPBACK_REMOVE_FROM_VRF)    echo "yes" ;;
        DOCKER_CLEANUP_MODE)                echo "purge" ;;
        FRR_FORCE_RESTART)                  echo "0" ;;
        FRR_PRE_START_WAIT)                 echo "5" ;;
        FRR_POST_START_WAIT)                echo "5" ;;
        FRR_DAEMON_CHECK_RETRIES)           echo "6" ;;
        FRR_DAEMON_CHECK_INTERVAL)          echo "2" ;;
        *)                                  echo "(unknown)" ;;
    esac
}

# Returns 1 if the user explicitly set the variable in the environment
# (i.e. the effective value differs from the compile-time default-of-defaults).
_is_overridden() {
    local key=$1
    # Use env + a canary to check whether the var was set explicitly.
    # Bash parameter expansion lets us detect "set to empty" vs "unset":
    #   "${var+x}" prints "x" if set (even to empty), nothing if unset.
    local -n ref="$key" 2>/dev/null || return 0
    # Fallback: compare against the canonical default string
    local default
    default="$(_default_for "$key")"
    # Strip "(auto)" suffix from default for comparison
    default="${default% (auto)}"
    if [[ "${ref}" == "${default}" ]]; then
        return 1  # not overridden
    fi
    return 0
}

# Print all env vars in aligned columns.
# Arg 1: "show-effective"  → print both default and effective values
#        "simple"          → print only defaults (for -l without overrides)
print_env_vars() {
    local mode=${1:-show-effective}
    local entry key default desc effective marker

    printf "\n%-32s %-28s %-28s %s\n" "VARIABLE" "DEFAULT" "EFFECTIVE" "DESCRIPTION"
    printf "%-32s %-28s %-28s %s\n"   "--------" "-------" "---------" "-----------"

    for entry in "${ENV_VARS_META[@]}"; do
        key=${entry%%|*}
        default=$(_default_for "$key")

        # Read the current effective value indirectly
        effective="${!key-}"
        [[ -z "$effective" ]] && effective="(empty)"
        [[ "$effective" == "-" ]] && effective="-"

        # Mark overridden values
        if [[ "$effective" != "$default" && "$effective" != "${default% (auto)}" ]]; then
            marker=" *"
        else
            marker=""
        fi

        desc=${entry##*|}

        if [[ "$mode" == "show-effective" ]]; then
            printf "%-32s %-28s %-28s %s%s\n" "$key" "$default" "$effective" "$desc" "$marker"
        else
            printf "%-32s %-28s %s\n" "$key" "$default" "$desc"
        fi
    done

    if [[ "$mode" == "show-effective" ]]; then
        echo
        echo "  (* = value differs from default — set via env var)"
    fi
    echo
}

# Return 0 if ANY tracked env var was overridden from its default.
any_overrides() {
    local entry key default effective
    for entry in "${ENV_VARS_META[@]}"; do
        key=${entry%%|*}
        default=$(_default_for "$key")
        default="${default% (auto)}"
        effective="${!key-}"
        if [[ "$effective" != "$default" && "$effective" != "(empty)" && -n "$effective" ]]; then
            # handle empty-default case
            if [[ "$default" == "(empty)" && -z "$effective" ]]; then
                continue
            fi
            return 0
        fi
    done
    return 1
}

# Interactive confirmation. Exits if user declines.
# Skipped if -y/--yes was passed or if stdin is not a TTY.
confirm_or_exit() {
    local override_note="$1"
    echo
    echo "==========================================================================="
    echo "  SCRIPT EXECUTION CONFIRMATION"
    echo "==========================================================================="
    echo
    echo "  Host           : $(hostname)"
    echo "  Script         : $SCRIPT_NAME"
    echo "  Date           : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "  User           : $(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")"
    echo
    if [[ -n "$override_note" ]]; then
        echo "  $override_note"
        echo
    fi
    echo "  Values that will be used:"
    print_env_vars show-effective

    echo "  ACTIONS THIS SCRIPT WILL PERFORM:"
    echo "    • Apply kernel sysctls (ip_forward, rp_filter, IPv6 RA off, l3mdev)"
    echo "    • Persist sysctls to /etc/sysctl.d/90-edge-router.conf"
    case "$DOCKER_CLEANUP_MODE" in
        purge) echo "    • DOCKER: stop + disable + apt purge + remove bridges/artifacts" ;;
        stop)  echo "    • DOCKER: stop + disable (packages left installed)" ;;
        none)  echo "    • DOCKER: untouched" ;;
    esac
    echo "    • Remove legacy loopbacks (lo0..lo9) from GRT${LEGACY_LOOPBACK_REMOVE_FROM_VRF:+ and VRFs}"
    echo "    • Create/verify VRFs: ${ALL_VRFS_PREVIEW:-<computed later>}"
    echo "    • Move physical NICs into their VRFs + re-seat addresses"
    echo "    • Reconcile NIC and loopback IP addresses (stripping stale ones)"
    echo "    • Create/verify dummy loopbacks per VRF"
    echo "    • Start and verify FRR daemons"
    echo

    if [[ "$MODE_YES" == "1" ]]; then
        echo "  -y/--yes flag detected — proceeding without interactive confirmation."
        echo "==========================================================================="
        echo
        return 0
    fi

    if [[ ! -t 0 ]]; then
        echo "  stdin is not a TTY — refusing to proceed without -y/--yes."
        echo "==========================================================================="
        exit 1
    fi

    local reply
    echo -n "  Proceed with these settings? [yes/No]: "
    read -r reply
    echo
    case "${reply,,}" in
        y|yes)
            echo "  Confirmed. Proceeding..."
            echo "==========================================================================="
            echo
            ;;
        *)
            echo "  Aborted by user."
            echo "==========================================================================="
            exit 0
            ;;
    esac
}

############################
# -l HANDLING (exits before any state changes)
############################

if [[ "$MODE_LIST" == "1" ]]; then
    cat <<EOF

==========================================================================
  $SCRIPT_NAME — Supported Environment Variables
==========================================================================

EOF
    print_env_vars show-effective

    cat <<EOF
Example overrides:

  # Madrid
  sudo MGMT_IFACE=ens224 VRF10_IFACE=ens192 VRF20_IFACE=ens256 \\
       SUBNET_OCTET=110 $SCRIPT_NAME

  # Beijing (vrf10 + vrf30, no vrf20)
  sudo MGMT_IFACE=ens224 VRF10_IFACE=ens192 VRF30_IFACE=ens256 \\
       VRF30_V4=172.30.113.200/24 VRF30_V6=2002:ac1e:71c8::200/64 \\
       SUBNET_OCTET=113 VRF_EXCLUDE="vrf20" $SCRIPT_NAME

  # Paris
  sudo MGMT_IFACE=ens160 VRF10_IFACE=ens224 VRF20_IFACE=ens256 \\
       SUBNET_OCTET=114 $SCRIPT_NAME

EOF
    exit 0
fi

############################
# VRF TOPOLOGY BUILD (data-driven)
############################

VRF_SPECS=(
"vrf10 10 ${VRF10_IFACE} ${VRF10_V4} ${VRF10_V6} 10.10.${SUBNET_OCTET}. 2002:10:10:${SUBNET_OCTET}:: lo10"
"vrf20 20 ${VRF20_IFACE} ${VRF20_V4} ${VRF20_V6} 10.20.${SUBNET_OCTET}. 2002:10:20:${SUBNET_OCTET}:: lo20"
"vrf30 30 ${VRF30_IFACE} ${VRF30_V4} ${VRF30_V6} 10.30.${SUBNET_OCTET}. 2002:10:30:${SUBNET_OCTET}:: lo30"
)

# If iface is '-', clear the v4/v6 entries (keeps output clean)
_cleaned_specs=()
for spec in "${VRF_SPECS[@]}"; do
    # shellcheck disable=SC2206
    f=($spec)
    if [[ "${f[2]}" == "-" ]]; then
        f[3]="-"
        f[4]="-"
    fi
    _cleaned_specs+=("${f[*]}")
done
VRF_SPECS=("${_cleaned_specs[@]}")

DUMMY_INDICES=(1 2 3 4)
LEGACY_LOOPBACKS=(lo0 lo1 lo2 lo3 lo4 lo5 lo6 lo7 lo8 lo9)

# Build derived arrays
ALL_VRFS=()
declare -A VRF_TABLE
declare -A VRF_IFACE
declare -A VRF_IFACE_V4
declare -A VRF_IFACE_V6
declare -A VRF_LO_V4_BASE
declare -A VRF_LO_V6_BASE
declare -A VRF_LO_NAME_BASE

PROTECTED_IFACES=("${MGMT_IFACE}" lo)
RP_FILTER_OFF_IFACES=()
IPV6_NO_RA_IFACES=()
PHYSICAL_VRF_ASSIGNMENTS=()
PHYSICAL_IFACE_ADDRS=()

for spec in "${VRF_SPECS[@]}"; do
    # shellcheck disable=SC2206
    fields=($spec)
    vname="${fields[0]}"
    vtable="${fields[1]}"
    viface="${fields[2]}"
    vv4="${fields[3]}"
    vv6="${fields[4]}"
    lov4="${fields[5]}"
    lov6="${fields[6]}"
    loname="${fields[7]}"

    if [[ " $VRF_EXCLUDE " == *" $vname "* ]]; then
        continue
    fi

    ALL_VRFS+=("$vname")
    VRF_TABLE[$vname]="$vtable"
    VRF_IFACE[$vname]="$viface"
    VRF_IFACE_V4[$vname]="$vv4"
    VRF_IFACE_V6[$vname]="$vv6"
    VRF_LO_V4_BASE[$vname]="$lov4"
    VRF_LO_V6_BASE[$vname]="$lov6"
    VRF_LO_NAME_BASE[$vname]="$loname"

    if [[ "$viface" != "-" ]]; then
        PHYSICAL_VRF_ASSIGNMENTS+=("$viface $vname")
        RP_FILTER_OFF_IFACES+=("$viface")
        IPV6_NO_RA_IFACES+=("$viface")
        if [[ "$vv4" != "-" || "$vv6" != "-" ]]; then
            PHYSICAL_IFACE_ADDRS+=("$viface $vv4 $vv6")
        fi
    fi
done

ALL_VRFS_PREVIEW="${ALL_VRFS[*]}"

############################
# DOCKER CLEANUP CONFIG
############################

DOCKER_IFACE_PATTERNS=('docker0' 'br-*' 'veth*')
DOCKER_PACKAGES=(
    docker-ce docker-ce-cli docker-ce-rootless-extras
    docker-buildx-plugin docker-compose-plugin
    docker.io containerd.io containerd runc
)
DOCKER_FS_PATHS=(
    /var/lib/docker /var/lib/containerd
    /etc/docker /run/docker /run/docker.sock
    /run/containerd /var/run/docker.sock
    /etc/apparmor.d/docker
)

VRF_L3MDEV_SYSCTLS=(
    "net.ipv4.tcp_l3mdev_accept=1"
    "net.ipv4.udp_l3mdev_accept=1"
    "net.ipv4.raw_l3mdev_accept=1"
    "net.ipv6.tcp_l3mdev_accept=1"
    "net.ipv6.udp_l3mdev_accept=1"
    "net.ipv6.raw_l3mdev_accept=1"
)

############################
# LOGGING
############################

log()  { echo -e "[INFO]  $*"; }
warn() { echo -e "[WARN]  $*"; }
err()  { echo -e "[ERROR] $*" >&2; }

require_root() {
    [[ $EUID -eq 0 ]] || { err "This script must be run as root (use sudo)."; exit 1; }
}
require_root

############################
# CONFIRMATION GATE
############################

if any_overrides; then
    confirm_or_exit "Environment overrides detected. Please review carefully."
else
    confirm_or_exit "Using all default values."
fi

############################
# GENERIC HELPERS
############################

link_exists() { ip link show "$1" &>/dev/null; }

is_protected() {
    local iface=$1 p
    for p in "${PROTECTED_IFACES[@]}"; do
        [[ "$iface" == "$p" ]] && return 0
    done
    return 1
}

current_master() {
    ip -o link show "$1" 2>/dev/null \
        | grep -oE 'master [^ ]+' | awk '{print $2}' || true
}

vrf_table_of() {
    ip -d link show "$1" 2>/dev/null \
        | grep -oE 'vrf table [0-9]+' | awk '{print $3}' || true
}

link_kind() {
    ip -d link show "$1" 2>/dev/null \
        | awk '/^[[:space:]]+[a-z]/ && $1 ~ /^(dummy|vrf|bridge|vxlan|tun|tap|veth|vlan|bond)$/ { print $1; exit }'
}

is_dummy() {
    local iface=$1
    [[ -d /sys/class/net/$iface ]] || return 1
    [[ "$(link_kind "$iface")" == "dummy" ]] && return 0
    if [[ -r /sys/class/net/$iface/uevent ]]; then
        grep -q 'DEVTYPE=dummy' /sys/class/net/$iface/uevent && return 0
    fi
    return 1
}

############################
# PRE-FLIGHT VALIDATION
############################

preflight_check() {
    local fatal=0 default_iface _legacy spec vname viface

    for _legacy in "${LEGACY_LOOPBACKS[@]}"; do
        if [[ "$_legacy" == "lo" ]]; then
            err "CRITICAL: 'lo' cannot appear in LEGACY_LOOPBACKS. Aborting."
            exit 1
        fi
    done

    if [[ -z "$MGMT_IFACE" ]] || ! link_exists "$MGMT_IFACE"; then
        err "MGMT_IFACE='$MGMT_IFACE' is unset or does not exist."
        fatal=1
    fi

    if [[ ${#ALL_VRFS[@]} -eq 0 ]]; then
        err "No VRFs to manage (VRF_EXCLUDE excluded all, or none configured)."
        fatal=1
    fi

    for spec in "${VRF_SPECS[@]}"; do
        # shellcheck disable=SC2206
        fields=($spec)
        vname="${fields[0]}"
        viface="${fields[2]}"
        [[ " $VRF_EXCLUDE " == *" $vname "* ]] && continue

        if [[ "$viface" != "-" ]]; then
            if is_protected "$viface"; then
                err "$viface (for $vname) conflicts with PROTECTED_IFACES."
                fatal=1
            fi
            if ! link_exists "$viface"; then
                err "$viface declared for $vname but does not exist."
                fatal=1
            fi
        fi
    done

    default_iface=$(ip -o route show default 2>/dev/null \
        | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [[ -n "$default_iface" ]] && ! is_protected "$default_iface"; then
        err "IPv4 default route via '$default_iface' — not in PROTECTED_IFACES."
        err "Add to PROTECTED_IFACES or fix MGMT_IFACE."
        fatal=1
    fi

    if [[ $fatal -eq 1 ]]; then
        err "Pre-flight check FAILED. Fix config and retry."
        exit 1
    fi

    log "Pre-flight config check: PASSED ✓"
    log "  Management (protected) : ${PROTECTED_IFACES[*]}"
    log "  VRFs to manage         : ${ALL_VRFS[*]}"
    local v
    for v in "${ALL_VRFS[@]}"; do
        log "    $v (table ${VRF_TABLE[$v]}): iface=${VRF_IFACE[$v]}"
        log "       NIC v4=${VRF_IFACE_V4[$v]}  NIC v6=${VRF_IFACE_V6[$v]}"
        log "       Loopbacks: ${VRF_LO_NAME_BASE[$v]}{1..4} → ${VRF_LO_V4_BASE[$v]}{1..4}/32, ${VRF_LO_V6_BASE[$v]}{1..4}/128"
    done
    log "  Subnet octet           : ${SUBNET_OCTET}"
    log "  Host octet             : ${HOST_OCTET}"
    log "  Docker cleanup mode    : ${DOCKER_CLEANUP_MODE}"
    log "  Legacy-loopback VRF rm : ${LEGACY_LOOPBACK_REMOVE_FROM_VRF}"
    [[ -n "$VRF_EXCLUDE" ]] && log "  Excluded VRFs          : ${VRF_EXCLUDE}"
}

############################
# IPv6 HELPERS
############################

ensure_ipv6_enabled() {
    local iface=$1
    local path=/proc/sys/net/ipv6/conf/$iface/disable_ipv6
    [[ -e "$path" ]] || return 0
    if [[ "$(cat "$path")" != "0" ]]; then
        warn "  IPv6 was DISABLED on $iface — re-enabling"
        sysctl -w "net.ipv6.conf.$iface.disable_ipv6=0" >/dev/null 2>&1 || true
    fi
}

disable_ipv6_ra() {
    local iface=$1
    [[ -d /proc/sys/net/ipv6/conf/$iface ]] || return 0
    ensure_ipv6_enabled "$iface"
    sysctl -w "net.ipv6.conf.$iface.accept_ra=0"    >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.$iface.autoconf=0"     >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.$iface.use_tempaddr=0" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.$iface.forwarding=1"   >/dev/null 2>&1 || true
    log "  net.ipv6.conf.$iface: disable_ipv6=0 accept_ra=0 autoconf=0 use_tempaddr=0 forwarding=1"
}

flush_slaac_addrs() {
    local iface=$1
    [[ -d /sys/class/net/$iface ]] || return 0
    local addr
    while read -r addr; do
        [[ -z "$addr" ]] && continue
        [[ "$addr" == fe80:* ]] && continue
        if [[ "$addr" =~ :[0-9a-f]{1,4}ff:fe[0-9a-f]{1,4}: ]]; then
            warn "  removing SLAAC IPv6 $addr from $iface"
            ip -6 addr del "$addr" dev "$iface" 2>/dev/null || true
        fi
    done < <(ip -o -6 addr show dev "$iface" | awk '{print $4}')
}

persist_sysctls() {
    local file=/etc/sysctl.d/90-edge-router.conf
    log "Writing persistent sysctls to $file..."
    {
        echo "# Managed by $SCRIPT_NAME — do not edit by hand"
        echo
        echo "# --- Global forwarding + RP filter ---"
        echo "net.ipv4.ip_forward=1"
        echo "net.ipv4.conf.all.rp_filter=0"
        echo "net.ipv4.conf.default.rp_filter=0"
        echo "net.ipv6.conf.all.forwarding=1"
        echo "net.ipv6.conf.all.accept_ra=0"
        echo "net.ipv6.conf.default.accept_ra=0"
        echo "net.ipv6.conf.all.autoconf=0"
        echo "net.ipv6.conf.default.autoconf=0"
        echo
        echo "# --- VRF l3mdev (only if kernel supports) ---"
        local kv key
        for kv in "${VRF_L3MDEV_SYSCTLS[@]}"; do
            key=${kv%=*}
            [[ -e "/proc/sys/${key//.//}" ]] && echo "$kv"
        done
        echo
        echo "# --- Per-interface settings ---"
        local iface
        for iface in "${RP_FILTER_OFF_IFACES[@]}"; do
            echo "net.ipv4.conf.$iface.rp_filter=0"
        done
        for iface in "${IPV6_NO_RA_IFACES[@]}"; do
            echo "net.ipv6.conf.$iface.disable_ipv6=0"
            echo "net.ipv6.conf.$iface.accept_ra=0"
            echo "net.ipv6.conf.$iface.autoconf=0"
            echo "net.ipv6.conf.$iface.use_tempaddr=0"
            echo "net.ipv6.conf.$iface.forwarding=1"
        done
    } > "$file"
    chmod 0644 "$file"
    log "  persistent sysctls written"
}

############################
# DOCKER REMOVAL
############################

is_docker_iface() {
    local iface=$1 pat
    for pat in "${DOCKER_IFACE_PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        [[ $iface == $pat ]] && return 0
    done
    return 1
}

list_docker_ifaces() {
    local all name
    mapfile -t all < <(ip -br link show 2>/dev/null | awk '{print $1}' | sed 's/@.*//')
    for name in "${all[@]}"; do
        is_docker_iface "$name" && echo "$name"
    done
}

remove_docker_iface() {
    local iface=$1
    is_protected "$iface" && { warn "Refusing: $iface protected"; return 0; }
    link_exists "$iface"  || return 0

    log "  -> flushing IPs on $iface"
    ip    addr flush dev "$iface" 2>/dev/null || true
    ip -6 addr flush dev "$iface" 2>/dev/null || true
    log "  -> bringing $iface down"
    ip link set "$iface" down 2>/dev/null || true

    local master
    master=$(current_master "$iface")
    [[ -n "$master" ]] && { log "  -> detaching $iface from '$master'"; ip link set "$iface" nomaster 2>/dev/null || true; }

    log "  -> deleting $iface"
    if ip link del "$iface" 2>/dev/null; then
        log "  ✓ $iface removed"
    else
        warn "  could not delete $iface"
    fi
}

stop_and_disable_docker_services() {
    local any=0 unit
    for unit in docker.service docker.socket containerd.service; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}"; then
            if systemctl is-active --quiet "$unit"; then
                log "Stopping $unit..."
                systemctl stop "$unit" 2>/dev/null || warn "  failed to stop $unit"
                any=1
            else
                log "$unit: already stopped"
            fi
            if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
                log "Disabling $unit..."
                systemctl disable "$unit" 2>/dev/null || warn "  failed to disable $unit"
                systemctl mask    "$unit" 2>/dev/null || true
                any=1
            else
                log "$unit: already disabled"
            fi
        fi
    done

    if pgrep -x dockerd >/dev/null 2>&1 || pgrep -x containerd >/dev/null 2>&1; then
        warn "Docker/containerd still running — forcing kill..."
        pkill -TERM dockerd containerd 2>/dev/null || true
        sleep 2
        pkill -KILL dockerd containerd 2>/dev/null || true
    fi

    [[ $any -eq 1 ]] && sleep 2
    return 0
}

purge_docker_packages() {
    command -v apt-get >/dev/null 2>&1 || { warn "apt-get not found."; return 0; }

    local installed=() pkg
    for pkg in "${DOCKER_PACKAGES[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' \
            && installed+=("$pkg")
    done

    if [[ ${#installed[@]} -eq 0 ]]; then
        log "No Docker packages installed — nothing to purge."
        return 0
    fi

    log "Purging Docker packages: ${installed[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}" \
        || warn "apt-get purge returned non-zero."

    log "Narrow follow-up purge of Docker-only deps..."
    local doc_deps=(pigz slirp4netns libslirp0 docker-scan-plugin
                    docker-ce-rootless-extras containerd containerd.io runc)
    local to_remove=() dep
    for dep in "${doc_deps[@]}"; do
        dpkg-query -W -f='${Status}' "$dep" 2>/dev/null | grep -q 'install ok installed' \
            && to_remove+=("$dep")
    done
    if [[ ${#to_remove[@]} -gt 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${to_remove[@]}" \
            || warn "dep purge returned non-zero."
    else
        log "  no Docker deps need removing."
    fi
}

remove_docker_iptables_artifacts() {
    command -v iptables >/dev/null 2>&1 || return 0
    log "Cleaning Docker iptables rules..."
    local table chain
    for table in nat filter mangle; do
        for chain in DOCKER DOCKER-ISOLATION DOCKER-ISOLATION-STAGE-1 \
                     DOCKER-ISOLATION-STAGE-2 DOCKER-USER DOCKER-INGRESS; do
            if iptables -t "$table" -L "$chain" >/dev/null 2>&1; then
                iptables -t "$table" -F "$chain" 2>/dev/null || true
                iptables -t "$table" -X "$chain" 2>/dev/null || true
            fi
        done
    done
    if command -v ip6tables >/dev/null 2>&1; then
        for table in nat filter mangle; do
            for chain in DOCKER DOCKER-ISOLATION DOCKER-ISOLATION-STAGE-1 \
                         DOCKER-ISOLATION-STAGE-2 DOCKER-USER DOCKER-INGRESS; do
                if ip6tables -t "$table" -L "$chain" >/dev/null 2>&1; then
                    ip6tables -t "$table" -F "$chain" 2>/dev/null || true
                    ip6tables -t "$table" -X "$chain" 2>/dev/null || true
                fi
            done
        done
    fi
}

remove_docker_filesystem_artifacts() {
    local path override
    for path in "${DOCKER_FS_PATHS[@]}"; do
        [[ -e "$path" ]] && { log "Removing $path"; rm -rf "$path" 2>/dev/null || warn "  could not remove $path"; }
    done
    for override in /etc/systemd/system/docker.service.d \
                    /etc/systemd/system/docker.socket.d \
                    /etc/systemd/system/containerd.service.d; do
        [[ -d "$override" ]] && { log "Removing $override"; rm -rf "$override" || true; }
    done
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed  2>/dev/null || true
}

docker_cleanup() {
    case "$DOCKER_CLEANUP_MODE" in
        none)       log "DOCKER_CLEANUP_MODE=none — skipping."; return 0 ;;
        stop|purge) ;;
        *)          err "Invalid DOCKER_CLEANUP_MODE='$DOCKER_CLEANUP_MODE'."; return 1 ;;
    esac

    log "Docker cleanup mode: $DOCKER_CLEANUP_MODE"
    stop_and_disable_docker_services

    local -a dockers
    mapfile -t dockers < <(list_docker_ifaces)
    if [[ ${#dockers[@]} -eq 0 ]]; then
        log "No Docker interfaces currently present."
    else
        log "Found Docker interfaces: ${dockers[*]}"
        local d
        for d in "${dockers[@]}"; do
            log "Removing Docker interface: $d"
            remove_docker_iface "$d"
        done
    fi

    local line
    while read -r line; do
        [[ -z "$line" ]] && continue
        log "Removing stale Docker route: $line"
        # shellcheck disable=SC2086
        ip route del $line 2>/dev/null || true
    done < <(ip route show 2>/dev/null | awk '/dev docker[0-9]+|dev br-/{print}')

    if [[ "$DOCKER_CLEANUP_MODE" == "purge" ]]; then
        purge_docker_packages
        remove_docker_iptables_artifacts
        remove_docker_filesystem_artifacts
    fi

    mapfile -t dockers < <(list_docker_ifaces)
    local still_installed=0 pkg
    for pkg in "${DOCKER_PACKAGES[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' \
            && still_installed=$((still_installed+1))
    done

    echo
    log "===== DOCKER REMOVAL SUMMARY ====="
    [[ ${#dockers[@]} -eq 0 ]] && log "  Interfaces             : ✓ none remaining" \
                              || warn "  Interfaces remaining   : ${dockers[*]}"
    systemctl is-active  --quiet docker 2>/dev/null && warn "  docker.service         : still active" \
                                                    || log  "  docker.service         : ✓ stopped"
    systemctl is-enabled --quiet docker 2>/dev/null && warn "  docker.service         : still enabled" \
                                                    || log  "  docker.service         : ✓ disabled"
    if [[ "$DOCKER_CLEANUP_MODE" == "purge" ]]; then
        [[ $still_installed -eq 0 ]] && log "  Packages               : ✓ all purged" \
                                     || warn "  Packages still present : $still_installed"
    fi
    echo
}

############################
# LEGACY LOOPBACK PURGE
############################

remove_legacy_loopback() {
    local name=$1

    [[ "$name" == "lo" ]] && { warn "Refusing to touch real 'lo'."; return 0; }
    is_protected "$name" && { warn "Refusing protected: $name"; return 0; }
    link_exists "$name" || { log "Legacy $name: not present — nothing to do."; return 0; }

    local master
    master=$(current_master "$name")
    if [[ -n "$master" ]]; then
        if [[ "$LEGACY_LOOPBACK_REMOVE_FROM_VRF" != "yes" ]]; then
            warn "Legacy $name is in VRF '$master' — skipping."
            return 0
        fi
        log "Legacy $name is in VRF '$master' — detaching (aggressive)."
        ip link set "$name" nomaster 2>/dev/null || warn "  nomaster failed"
    fi

    if ! is_dummy "$name"; then
        ip link set "$name" up 2>/dev/null || true
        sleep 0.2
        if ! is_dummy "$name"; then
            local kind
            kind=$(link_kind "$name")
            warn "Legacy $name is type '${kind:-unknown}' (not dummy) — refusing."
            return 0
        fi
    fi

    log "Purging legacy loopback: $name"

    local v4_addrs v6_addrs
    mapfile -t v4_addrs < <(ip -o -4 addr show dev "$name" 2>/dev/null | awk '{print $4}')
    mapfile -t v6_addrs < <(ip -o -6 addr show dev "$name" 2>/dev/null | awk '$4 !~ /^fe80/ {print $4}')
    [[ ${#v4_addrs[@]} -gt 0 ]] && log "  IPv4 to remove: ${v4_addrs[*]}"
    [[ ${#v6_addrs[@]} -gt 0 ]] && log "  IPv6 to remove: ${v6_addrs[*]}"

    ip link set "$name" down 2>/dev/null || true
    ip    addr flush dev "$name" 2>/dev/null || true
    ip -6 addr flush dev "$name" 2>/dev/null || true

    local tables_seen=() table_id
    mapfile -t tables_seen < <(
        {
            ip -4 route show table all 2>/dev/null | awk -v dev="$name" '$0 ~ ("dev " dev "([[:space:]]|$)") {for (i=1;i<=NF;i++) if ($i=="table") print $(i+1)}'
            ip -6 route show table all 2>/dev/null | awk -v dev="$name" '$0 ~ ("dev " dev "([[:space:]]|$)") {for (i=1;i<=NF;i++) if ($i=="table") print $(i+1)}'
        } | sort -u
    )
    for table_id in "${tables_seen[@]}"; do
        [[ -z "$table_id" ]] && continue
        ip    route flush dev "$name" table "$table_id" 2>/dev/null || true
        ip -6 route flush dev "$name" table "$table_id" 2>/dev/null || true
    done
    ip    route flush dev "$name" 2>/dev/null || true
    ip -6 route flush dev "$name" 2>/dev/null || true

    if ip link del "$name" 2>/dev/null; then
        log "  ✓ $name removed"
        return 0
    fi

    ip link del dev "$name" 2>/dev/null || ip link delete "$name" 2>/dev/null || true
    if link_exists "$name"; then
        warn "  could not delete $name"
        return 1
    else
        log "  ✓ $name removed (fallback)"
        return 0
    fi
}

############################
# VRF + NIC MANAGEMENT
############################

ensure_vrf() {
    local name=$1 want_table=$2

    if link_exists "$name"; then
        local have_table
        have_table=$(vrf_table_of "$name")
        if [[ "$have_table" == "$want_table" ]]; then
            log "VRF $name already exists with table $want_table — keeping it."
        else
            err "VRF $name has wrong table '$have_table' (expected $want_table)."
            exit 1
        fi
    else
        log "Creating VRF $name (table $want_table)"
        ip link add "$name" type vrf table "$want_table"
    fi
    ip link set "$name" up
}

ensure_iface_in_vrf() {
    local iface=$1 vrf=$2

    is_protected "$iface" && { err "Refusing: $iface protected"; return 1; }
    link_exists "$iface"  || { warn "$iface not present — skip."; return 0; }
    link_exists "$vrf"    || { err "$vrf missing"; return 1; }

    local table
    table=$(vrf_table_of "$vrf")

    local cur moved=0
    cur=$(current_master "$iface")
    if [[ "$cur" == "$vrf" ]]; then
        log "$iface already in $vrf — ok"
    else
        [[ -n "$cur" ]] && warn "$iface in '$cur', moving to '$vrf'." \
                       || log  "$iface in GRT, moving to '$vrf'."
        ip link set "$iface" nomaster 2>/dev/null || true
        ip link set "$iface" master "$vrf"
        ip link set "$iface" up
        moved=1
        [[ "$(current_master "$iface")" == "$vrf" ]] || { err "Failed to move $iface into $vrf."; return 1; }
        log "$iface now enslaved to $vrf ✓"
    fi

    ensure_ipv6_enabled "$iface"

    local need_reseat_v4=0 need_reseat_v6=0 has_v4 has_v6
    has_v4=$(ip -o -4 addr show dev "$iface" | awk '{print $4}' | head -1 || true)
    has_v6=$(ip -o -6 addr show dev "$iface" | awk '$6 != "link" && $4 !~ /^fe80/ {print $4}' | head -1 || true)

    [[ -n "$has_v4" ]] && ! ip route show table "$table" dev "$iface" 2>/dev/null \
        | grep -q 'proto kernel scope link' && need_reseat_v4=1
    [[ -n "$has_v6" ]] && ! ip -6 route show table "$table" dev "$iface" 2>/dev/null \
        | grep -qE 'proto kernel.*pref medium' && need_reseat_v6=1

    if [[ $moved -eq 1 || $need_reseat_v4 -eq 1 || $need_reseat_v6 -eq 1 ]]; then
        log "Re-seating addresses on $iface..."

        local addr
        while read -r addr; do
            [[ -z "$addr" ]] && continue
            ip addr del "$addr" dev "$iface" 2>/dev/null || true
            ip addr add "$addr" dev "$iface" 2>/dev/null || warn "  re-add IPv4 $addr failed"
        done < <(ip -o -4 addr show dev "$iface" | awk '{print $4}')

        while read -r addr; do
            [[ -z "$addr" ]] && continue
            [[ "$addr" == fe80:* ]] && continue
            ip -6 addr del "$addr" dev "$iface" 2>/dev/null || true
            ip -6 addr add "$addr" dev "$iface" 2>/dev/null || warn "  re-add IPv6 $addr failed"
        done < <(ip -o -6 addr show dev "$iface" | awk '$6 != "link" {print $4}')

        sleep 1

        local stale_v6
        while read -r stale_v6; do
            [[ -z "$stale_v6" ]] && continue
            ip -6 route del "$stale_v6" dev "$iface" 2>/dev/null || true
        done < <(ip -6 route show dev "$iface" \
            | awk '/proto kernel/ && $1 !~ /^fe80/ && $1 !~ /^ff00/ {print $1}')

        ip route show table "$table" dev "$iface" | grep -q 'proto kernel scope link' \
            && log "  ✓ IPv4 connected route for $iface in table $table" \
            || warn "  ✗ IPv4 connected route missing"
        ip -6 route show table "$table" dev "$iface" | grep -qE 'proto kernel.*pref medium' \
            && log "  ✓ IPv6 connected route for $iface in table $table" \
            || warn "  ✗ IPv6 connected route missing"
    fi

    [[ -d /proc/sys/net/ipv4/conf/$iface ]] && \
        sysctl -w "net.ipv4.conf.$iface.rp_filter=0" >/dev/null 2>&1 || true
    [[ -d /proc/sys/net/ipv6/conf/$iface ]] && \
        sysctl -w "net.ipv6.conf.$iface.forwarding=1" >/dev/null 2>&1 || true
    return 0
}

reconcile_iface_addrs() {
    local iface=$1 desired_v4=$2 desired_v6=$3

    is_protected "$iface" && { err "Refusing: $iface protected"; return 1; }
    link_exists "$iface"  || { warn "$iface not present — skip."; return 0; }
    ensure_ipv6_enabled "$iface"

    log "Reconciling addresses on $iface (desired v4=$desired_v4, v6=$desired_v6)..."

    if [[ "$desired_v4" != "-" ]]; then
        if ! ip -4 addr show dev "$iface" | grep -qw "$desired_v4"; then
            log "  adding IPv4 $desired_v4 on $iface"
            ip addr add "$desired_v4" dev "$iface"
        else
            log "  IPv4 $desired_v4 already present on $iface"
        fi
        local current
        while read -r current; do
            [[ -z "$current" || "$current" == "$desired_v4" ]] && continue
            warn "  removing stale IPv4 $current from $iface"
            ip addr del "$current" dev "$iface" 2>/dev/null || warn "    failed"
        done < <(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}')
    fi

    if [[ "$desired_v6" != "-" ]]; then
        if ! ip -6 addr show dev "$iface" | grep -qw "$desired_v6"; then
            log "  adding IPv6 $desired_v6 on $iface"
            ip -6 addr add "$desired_v6" dev "$iface" || warn "    failed"
        else
            log "  IPv6 $desired_v6 already present on $iface"
        fi
        local entry current scope
        while read -r entry; do
            current=${entry%%|*}
            scope=${entry##*|}
            [[ -z "$current" || "$scope" == "link" || "$current" == fe80:* || "$current" == "$desired_v6" ]] && continue
            warn "  removing stale IPv6 $current from $iface"
            ip -6 addr del "$current" dev "$iface" 2>/dev/null || warn "    failed"
        done < <(ip -o -6 addr show dev "$iface" 2>/dev/null | awk '{print $4 "|" $6}')
    fi

    log "  final addresses on $iface:"
    ip -br addr show dev "$iface" | awk '{for(i=3;i<=NF;i++) printf "    %s\n", $i}'
}

ensure_lo() {
    local name=$1 ipv4=$2 ipv6=$3 vrf=$4

    is_protected "$name" && { err "Refusing: $name protected"; exit 1; }

    if ! link_exists "$name"; then
        log "Creating dummy $name"
        ip link add "$name" type dummy
    fi

    local cur
    cur=$(current_master "$name")
    if [[ -n "$cur" && "$cur" != "$vrf" ]]; then
        warn "$name currently in $cur, moving to $vrf"
        ip link set "$name" nomaster
    fi

    ip link set "$name" up
    ensure_ipv6_enabled "$name"

    if ! ip -4 addr show dev "$name" | grep -qw "$ipv4/32"; then
        log "  adding IPv4 $ipv4/32 on $name"
        ip addr add "$ipv4/32" dev "$name"
    else
        log "  IPv4 $ipv4/32 already present on $name"
    fi
    local current
    while read -r current; do
        [[ -z "$current" || "$current" == "$ipv4/32" ]] && continue
        warn "  removing stale IPv4 $current from $name"
        ip addr del "$current" dev "$name" 2>/dev/null || warn "    failed"
    done < <(ip -o -4 addr show dev "$name" 2>/dev/null | awk '{print $4}')

    if ! ip -6 addr show dev "$name" | grep -qw "$ipv6/128"; then
        log "  adding IPv6 $ipv6/128 on $name"
        ip -6 addr add "$ipv6/128" dev "$name"
    else
        log "  IPv6 $ipv6/128 already present on $name"
    fi
    local entry current6 scope
    while read -r entry; do
        current6=${entry%%|*}
        scope=${entry##*|}
        [[ -z "$current6" || "$scope" == "link" || "$current6" == fe80:* || "$current6" == "$ipv6/128" ]] && continue
        warn "  removing stale IPv6 $current6 from $name"
        ip -6 addr del "$current6" dev "$name" 2>/dev/null || warn "    failed"
    done < <(ip -o -6 addr show dev "$name" 2>/dev/null | awk '{print $4 "|" $6}')

    cur=$(current_master "$name")
    if [[ "$cur" != "$vrf" ]]; then
        log "  attaching $name to $vrf"
        ip link set "$name" master "$vrf"
    else
        log "  $name already in $vrf — ok"
    fi
}

############################
# FRR HELPERS
############################

frr_is_installed() {
    systemctl cat frr.service >/dev/null 2>&1 && return 0
    [[ -x /usr/lib/frr/frrinit.sh || -x /usr/lib/frr/zebra ]] && return 0
    systemctl is-active --quiet frr 2>/dev/null && return 0
    return 1
}
frr_is_active() { systemctl is-active --quiet frr 2>/dev/null; }

get_enabled_frr_daemons() {
    local conf=/etc/frr/daemons
    [[ -r "$conf" ]] || return 0
    local skip_regex='^(vtysh_enable|watchfrr_enable|frr_global_options|frr_profile|zebra_profile|bgpd_profile|ospfd_profile|ospf6d_profile|ripd_profile|ripngd_profile|isisd_profile|pimd_profile|pim6d_profile|ldpd_profile|nhrpd_profile|eigrpd_profile|babeld_profile|sharpd_profile|pbrd_profile|bfdd_profile|staticd_profile|fabricd_profile|vrrpd_profile|pathd_profile|mgmtd_profile)$'
    awk -F= '/^[[:space:]]*#/ {next}
             NF==2 { gsub(/[[:space:]]/,"",$1); gsub(/[[:space:]]/,"",$2);
                     if ($2=="yes") print $1 }' "$conf" \
        | grep -vE '_options$' | grep -vE "$skip_regex" || true
}

get_watchfrr_daemons() {
    local cmd
    cmd=$(pgrep -af 'watchfrr' 2>/dev/null | head -1) || true
    [[ -z "$cmd" ]] && return 0
    echo "$cmd" | sed -E 's#^[^ ]+ +##; s#^/usr/lib/frr/watchfrr +##; s#-d +##' \
        | tr ' ' '\n' \
        | grep -E '^(mgmtd|zebra|bfdd|bgpd|ripd|ripngd|ospfd|ospf6d|isisd|babeld|pimd|pim6d|ldpd|nhrpd|eigrpd|pbrd|staticd|fabricd|vrrpd|pathd|sharpd)$' || true
}

daemon_installed() { [[ -x "/usr/lib/frr/$1" ]]; }
daemon_running()   { pgrep -f "/usr/lib/frr/$1\b" >/dev/null 2>&1; }

wait_for_daemon() {
    local d=$1 i
    for ((i=0; i<FRR_DAEMON_CHECK_RETRIES; i++)); do
        daemon_running "$d" && return 0
        sleep "$FRR_DAEMON_CHECK_INTERVAL"
    done
    return 1
}

vtysh_can_reach() { vtysh -d "$1" -c "show version" >/dev/null 2>&1; }

start_and_verify_frr() {
    log "Waiting ${FRR_PRE_START_WAIT}s for kernel/VRF state to settle..."
    sleep "$FRR_PRE_START_WAIT"

    if ! frr_is_installed; then
        err "FRR is not installed."
        return 1
    fi
    log "FRR is installed ✓"

    if frr_is_active; then
        if [[ "$FRR_FORCE_RESTART" == "1" ]]; then
            log "FRR active — forced restart requested..."
            systemctl restart frr
        else
            log "FRR already active — leaving it running."
        fi
    else
        log "Starting FRR..."
        systemctl start frr
    fi

    log "Waiting ${FRR_POST_START_WAIT}s for daemons to initialize..."
    sleep "$FRR_POST_START_WAIT"

    if ! frr_is_active; then
        err "FRR systemd unit is not active."
        journalctl -u frr -n 40 --no-pager || true
        return 1
    fi
    log "FRR systemd unit: ACTIVE ✓"

    local expected
    mapfile -t expected < <(get_enabled_frr_daemons)
    [[ ${#expected[@]} -eq 0 ]] && {
        warn "/etc/frr/daemons empty — falling back to watchfrr list."
        mapfile -t expected < <(get_watchfrr_daemons)
    }
    local d
    for d in "${FRR_MANDATORY_DAEMONS[@]}"; do
        printf '%s\n' "${expected[@]}" | grep -qx "$d" || expected+=("$d")
    done
    [[ ${#expected[@]} -eq 0 ]] && expected=(zebra)

    log "Expected FRR daemons (${#expected[@]}): ${expected[*]}"

    local all_ok=1 missing_optional=0
    declare -a state_proc state_vty
    for d in "${expected[@]}"; do
        if ! daemon_installed "$d"; then
            state_proc+=("NOT-INSTALLED"); state_vty+=("N/A")
            missing_optional=$((missing_optional+1)); continue
        fi
        wait_for_daemon "$d" && state_proc+=("RUNNING") \
                            || { state_proc+=("NOT-RUNNING"); state_vty+=("NOT-RUNNING"); all_ok=0; continue; }
        case "$d" in
            watchfrr|mgmtd) state_vty+=("SKIPPED") ;;
            *) vtysh_can_reach "$d" && state_vty+=("RESPONSIVE") \
                                    || { state_vty+=("UNRESPONSIVE"); all_ok=0; } ;;
        esac
    done

    echo
    log "===== FRR DAEMON STATUS ====="
    printf "  %-12s %-16s %s\n" "DAEMON" "PROCESS" "VTYSH"
    printf "  %-12s %-16s %s\n" "------" "-------" "-----"
    local i
    for ((i=0; i<${#expected[@]}; i++)); do
        printf "  %-12s %-16s %s\n" "${expected[i]}" "${state_proc[i]}" "${state_vty[i]}"
    done
    echo

    [[ $missing_optional -gt 0 ]] && warn "$missing_optional daemon(s) missing binary — cosmetic."
    for d in "${FRR_MANDATORY_DAEMONS[@]}"; do
        daemon_running "$d" || { err "MANDATORY daemon '$d' not running."; all_ok=0; }
    done

    [[ $all_ok -eq 1 ]] && { log "All FRR daemons healthy ✓"; return 0; }
    err "One or more FRR daemons are not healthy."
    return 1
}

############################
# ============ MAIN ============
############################

# 0. PRE-FLIGHT
preflight_check

# 1. KERNEL HARDENING
log "Applying global sysctl tuning..."
sysctl -w net.ipv4.ip_forward=1             >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0     >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1    >/dev/null

log "Applying VRF l3mdev_accept sysctls..."
for kv in "${VRF_L3MDEV_SYSCTLS[@]}"; do
    key=${kv%=*}
    val=${kv#*=}
    if [[ -e "/proc/sys/${key//.//}" ]]; then
        sysctl -w "$kv" >/dev/null 2>&1 && log "  $key = $val" || warn "  could not set $kv"
    else
        log "  $key : not supported by this kernel (skipping)"
    fi
done

log "Applying per-interface rp_filter=0 on data-plane NICs..."
for iface in "${RP_FILTER_OFF_IFACES[@]}"; do
    if [[ -d /proc/sys/net/ipv4/conf/$iface ]]; then
        sysctl -w "net.ipv4.conf.$iface.rp_filter=0" >/dev/null
        log "  net.ipv4.conf.$iface.rp_filter = 0"
    fi
done

log "Disabling IPv6 RA/autoconf and ensuring IPv6 is enabled..."
sysctl -w net.ipv6.conf.all.accept_ra=0     >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.accept_ra=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.autoconf=0      >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.autoconf=0  >/dev/null 2>&1 || true
for iface in "${IPV6_NO_RA_IFACES[@]}"; do
    ensure_ipv6_enabled "$iface"
    disable_ipv6_ra    "$iface"
    flush_slaac_addrs  "$iface"
done

persist_sysctls

log "Cleaning up Docker..."
docker_cleanup

log "Removing legacy loopbacks (${LEGACY_LOOPBACKS[*]}) (VRF-aware=${LEGACY_LOOPBACK_REMOVE_FROM_VRF})..."
for legacy in "${LEGACY_LOOPBACKS[@]}"; do
    remove_legacy_loopback "$legacy"
done

log "Ensuring VRFs exist with correct table IDs..."
for v in "${ALL_VRFS[@]}"; do
    ensure_vrf "$v" "${VRF_TABLE[$v]}"
done

log "Ensuring physical NIC -> VRF assignments..."
for mapping in "${PHYSICAL_VRF_ASSIGNMENTS[@]}"; do
    # shellcheck disable=SC2086
    ensure_iface_in_vrf $mapping
done

log "Reconciling physical interface addresses..."
for iface in "${IPV6_NO_RA_IFACES[@]}"; do
    ensure_ipv6_enabled "$iface"
    flush_slaac_addrs "$iface"
done
for entry in "${PHYSICAL_IFACE_ADDRS[@]}"; do
    # shellcheck disable=SC2086
    reconcile_iface_addrs $entry
done

log "Verifying connected routes for persistently-configured NICs..."
for mapping in "${PHYSICAL_VRF_ASSIGNMENTS[@]}"; do
    iface=$(echo "$mapping" | awk '{print $1}')
    vrf=$(echo   "$mapping" | awk '{print $2}')
    if link_exists "$iface" && [[ "$(current_master "$iface")" == "$vrf" ]]; then
        ensure_iface_in_vrf "$iface" "$vrf"
    fi
done

log "Ensuring dummy loopbacks per VRF..."
for v in "${ALL_VRFS[@]}"; do
    v4base="${VRF_LO_V4_BASE[$v]}"
    v6base="${VRF_LO_V6_BASE[$v]}"
    nbase="${VRF_LO_NAME_BASE[$v]}"
    for i in "${DUMMY_INDICES[@]}"; do
        loname="${nbase}${i}"
        v4="${v4base}${i}"
        v6="${v6base}${i}"
        ensure_lo "$loname" "$v4" "$v6" "$v"
    done
done

# VALIDATION
echo
log "VRF devices:"
ip -br link show type vrf
echo
log "Dummy loopbacks:"
ip -br link show type dummy | grep -E '^lo[0-9]' || true
echo
log "Physical NICs in VRFs:"
for entry in "${PHYSICAL_IFACE_ADDRS[@]}"; do
    iface=$(echo "$entry" | awk '{print $1}')
    ip -br addr show dev "$iface" 2>/dev/null || true
done
echo
log "Slaves per VRF:"
for v in "${ALL_VRFS[@]}"; do
    echo "  $v:"
    ip -br link show master "$v" 2>/dev/null | awk '{print "    " $1}'
done
echo
log "Routes in VRF tables:"
for v in "${ALL_VRFS[@]}"; do
    t=${VRF_TABLE[$v]}
    echo "--- $v (table $t) IPv4 ---"; ip    route show table "$t" || true
    echo "--- $v (table $t) IPv6 ---"; ip -6 route show table "$t" || true
done

echo
set +e
start_and_verify_frr
FRR_STATUS=$?
set -e

cat <<EOF

================== VALIDATION COMMANDS ==================

Interfaces & VRFs:
  sudo vtysh -c "show interface brief"
$(for v in "${ALL_VRFS[@]}"; do echo "  ip -br link show master $v"; done)

Legacy loopbacks (should be empty):
  ip -br link show | grep -E '^lo[0-9] '

Ping tests:
$(for v in "${ALL_VRFS[@]}"; do
    nic="${VRF_IFACE[$v]}"
    if [[ "$nic" != "-" ]]; then
        v4="${VRF_IFACE_V4[$v]}"
        v6="${VRF_IFACE_V6[$v]}"
        [[ "$v4" != "-" ]] && echo "  sudo ip vrf exec $v ping  -c 3 ${v4%/*}"
        [[ "$v6" != "-" ]] && echo "  sudo ip vrf exec $v ping6 -c 3 ${v6%/*}"
    fi
done)

OSPF / BGP:
  sudo vtysh -c "show ip ospf neighbor"
  sudo vtysh -c "show ipv6 ospf6 neighbor"
  sudo vtysh -c "show bgp summary"
$(for v in "${ALL_VRFS[@]}"; do echo "  sudo vtysh -c \"show bgp vrf $v summary\""; done)

=========================================================
EOF

if [[ $FRR_STATUS -ne 0 ]]; then
    err "Script finished with FRR verification FAILED."
    exit 1
fi

log "Script finished successfully — all resources clean and healthy."