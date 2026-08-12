#!/usr/bin/env bash
set -Eeuo pipefail

readonly COMPLETED_STAGE=1
readonly -a NAMESPACES=(lab-client lab-router lab-fw lab-server)
readonly -a HOST_VETHS=(lab-c lab-r0 lab-r1 lab-f0 lab-f1 lab-s)

usage() {
    cat <<'EOF'
Usage:
  ./lab.sh check
  sudo ./lab.sh up <0|1>
  sudo ./lab.sh test <0|1>
  sudo ./lab.sh status
  sudo ./lab.sh down
EOF
}

check_environment() {
    local -a required=(bash ip sysctl ping)
    local -a optional=(iptables tc curl iperf3 tcpdump conntrack shellcheck)
    local tool
    local missing=0

    printf 'Required tools through Stage 1:\n'
    for tool in "${required[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf '  [ok] %s\n' "$tool"
        else
            printf '  [missing] %s\n' "$tool"
            missing=1
        fi
    done

    printf 'Optional tools for later stages:\n'
    for tool in "${optional[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf '  [ok] %s\n' "$tool"
        else
            printf '  [missing] %s\n' "$tool"
        fi
    done

    return "$missing"
}

require_supported_stage() {
    local stage=${1:-}

    if [[ ! "$stage" =~ ^[01]$ ]]; then
        printf 'Supported stages: 0 and 1; requested stage: %s\n' "${stage:-<missing>}" >&2
        return 2
    fi
}

require_root() {
    if ((EUID != 0)); then
        printf 'This command requires root. Run it with sudo.\n' >&2
        return 1
    fi
}

namespace_exists() {
    local namespace=$1
    [[ -e "/run/netns/$namespace" ]]
}

cleanup_stage_one() {
    local namespace
    local link

    for namespace in "${NAMESPACES[@]}"; do
        if namespace_exists "$namespace"; then
            ip netns delete "$namespace"
        fi
    done

    # Remove host-side remnants left by an interrupted setup before netns moves.
    for link in "${HOST_VETHS[@]}"; do
        if ip link show dev "$link" >/dev/null 2>&1; then
            ip link delete "$link"
        fi
    done
}

create_namespaces() {
    local namespace

    for namespace in "${NAMESPACES[@]}"; do
        ip netns add "$namespace"
        ip -n "$namespace" link set lo up
        ip netns exec "$namespace" sysctl -qw net.ipv4.ip_forward=0
    done
}

create_veth_pair() {
    local left_namespace=$1
    local left_host_name=$2
    local left_name=$3
    local right_namespace=$4
    local right_host_name=$5
    local right_name=$6

    ip link add "$left_host_name" type veth peer name "$right_host_name"
    ip link set "$left_host_name" netns "$left_namespace"
    ip link set "$right_host_name" netns "$right_namespace"
    ip -n "$left_namespace" link set "$left_host_name" name "$left_name"
    ip -n "$right_namespace" link set "$right_host_name" name "$right_name"
}

configure_interface() {
    local namespace=$1
    local interface=$2
    local address=$3

    ip -n "$namespace" address add "$address" dev "$interface"
    ip -n "$namespace" link set "$interface" up
}

setup_stage_one() {
    trap 'cleanup_stage_one' ERR

    cleanup_stage_one
    create_namespaces

    create_veth_pair lab-client lab-c eth0 lab-router lab-r0 eth0
    create_veth_pair lab-router lab-r1 eth1 lab-fw lab-f0 eth0
    create_veth_pair lab-fw lab-f1 eth1 lab-server lab-s eth0

    configure_interface lab-client eth0 10.10.1.2/24
    configure_interface lab-router eth0 10.10.1.1/24
    configure_interface lab-router eth1 10.10.2.1/24
    configure_interface lab-fw eth0 10.10.2.2/24
    configure_interface lab-fw eth1 10.10.3.1/24
    configure_interface lab-server eth0 10.10.3.2/24

    trap - ERR
    printf 'Stage 1 topology is up.\n'
}

require_stage_one_topology() {
    local namespace

    for namespace in "${NAMESPACES[@]}"; do
        if ! namespace_exists "$namespace"; then
            printf 'Missing namespace: %s. Run: sudo ./lab.sh up 1\n' "$namespace" >&2
            return 1
        fi
    done
}

test_forwarding_disabled() {
    local namespace
    local value

    for namespace in "${NAMESPACES[@]}"; do
        value=$(ip netns exec "$namespace" sysctl -n net.ipv4.ip_forward)
        if [[ "$value" != "0" ]]; then
            printf 'IPv4 forwarding is enabled unexpectedly in %s.\n' "$namespace" >&2
            return 1
        fi
    done
}

test_stage_one() {
    require_stage_one_topology
    test_forwarding_disabled

    ip netns exec lab-client ping -c 2 -W 1 10.10.1.1
    ip netns exec lab-router ping -c 2 -W 1 10.10.2.2
    ip netns exec lab-fw ping -c 2 -W 1 10.10.3.2

    printf '\nARP/neighbor entries learned during adjacent-node tests:\n'
    ip -n lab-client neighbor show dev eth0
    ip -n lab-router neighbor show dev eth1
    ip -n lab-fw neighbor show dev eth1
}

show_status() {
    local namespace

    printf 'Completed stage: %s\n' "$COMPLETED_STAGE"
    for namespace in "${NAMESPACES[@]}"; do
        if namespace_exists "$namespace"; then
            printf '\n[%s]\n' "$namespace"
            ip -brief -n "$namespace" address show
        else
            printf '\n[%s] absent\n' "$namespace"
        fi
    done
}

main() {
    local command=${1:-}
    local stage

    case "$command" in
        check)
            [[ $# -eq 1 ]] || { usage >&2; return 2; }
            check_environment
            ;;
        up)
            [[ $# -eq 2 ]] || { usage >&2; return 2; }
            stage=$2
            require_supported_stage "$stage"
            check_environment
            if [[ "$stage" == "1" ]]; then
                require_root
                setup_stage_one
            fi
            ;;
        test)
            [[ $# -eq 2 ]] || { usage >&2; return 2; }
            stage=$2
            require_supported_stage "$stage"
            check_environment
            if [[ "$stage" == "1" ]]; then
                require_root
                test_stage_one
            fi
            ;;
        status)
            [[ $# -eq 1 ]] || { usage >&2; return 2; }
            require_root
            show_status
            ;;
        down)
            [[ $# -eq 1 ]] || { usage >&2; return 2; }
            require_root
            cleanup_stage_one
            printf 'Lab resources removed.\n'
            ;;
        -h | --help)
            usage
            ;;
        *)
            usage >&2
            return 2
            ;;
    esac
}

main "$@"
