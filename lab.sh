#!/usr/bin/env bash
set -Eeuo pipefail

readonly COMPLETED_STAGE=4
readonly -a NAMESPACES=(lab-client lab-router lab-fw lab-server)
readonly -a HOST_VETHS=(lab-c lab-r0 lab-r1 lab-f0 lab-f1 lab-s)
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly RUNTIME_DIR="$SCRIPT_DIR/run"
readonly HTTP_PID_FILE="$RUNTIME_DIR/http.pid"
readonly HTTP_LOG="$RUNTIME_DIR/http.log"

usage() {
    cat <<'EOF'
Usage:
  ./lab.sh check
  sudo ./lab.sh up <0|1|2|3|4>
  sudo ./lab.sh test <0|1|2|3|4>
  sudo ./lab.sh nat <off|snat|dnat>
  sudo ./lab.sh status
  sudo ./lab.sh down
EOF
}

check_environment() {
    local -a required=(bash ip sysctl ping iptables curl python3 conntrack)
    local -a optional=(tc iperf3 tcpdump shellcheck)
    local tool
    local missing=0

    printf 'Required tools through Stage 4:\n'
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

    if [[ ! "$stage" =~ ^[01234]$ ]]; then
        printf 'Supported stages: 0 through 4; requested stage: %s\n' "${stage:-<missing>}" >&2
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

is_project_http_pid() {
    local pid=$1
    local command_line

    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1
    command_line=$(tr '\0' ' ' <"/proc/$pid/cmdline")
    [[ "$command_line" == *"python3 -m http.server 8080"* &&
        "$command_line" == *"--directory $SCRIPT_DIR/docs"* ]]
}

stop_http_server() {
    local pid
    local -a pids=()

    if [[ -r "$HTTP_PID_FILE" ]]; then
        pid=$(<"$HTTP_PID_FILE")
        pids+=("$pid")
    fi
    if namespace_exists lab-server; then
        mapfile -t namespace_pids < <(ip netns pids lab-server)
        pids+=("${namespace_pids[@]}")
    fi

    for pid in "${pids[@]}"; do
        if is_project_http_pid "$pid"; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -f "$HTTP_PID_FILE"
}

cleanup_stage_one() {
    local namespace
    local link

    stop_http_server

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

setup_stage_two() {
    trap 'cleanup_stage_one' ERR

    setup_stage_one
    trap 'cleanup_stage_one' ERR

    ip -n lab-client route add default via 10.10.1.1
    ip -n lab-router route add 10.10.3.0/24 via 10.10.2.2
    ip -n lab-fw route add 10.10.1.0/24 via 10.10.2.1
    ip -n lab-server route add default via 10.10.3.1

    ip netns exec lab-router sysctl -qw net.ipv4.ip_forward=1
    ip netns exec lab-fw sysctl -qw net.ipv4.ip_forward=1

    trap - ERR
    printf 'Stage 2 routing is up.\n'
}

configure_stage_three_acl() {
    ip netns exec lab-fw iptables -F
    ip netns exec lab-fw iptables -X
    ip netns exec lab-fw iptables -P INPUT ACCEPT
    ip netns exec lab-fw iptables -P OUTPUT ACCEPT
    ip netns exec lab-fw iptables -P FORWARD DROP

    ip netns exec lab-fw iptables -A FORWARD \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -m comment --comment stage3-established -j ACCEPT
    ip netns exec lab-fw iptables -A FORWARD \
        -p icmp -m comment --comment stage3-icmp -j ACCEPT
    ip netns exec lab-fw iptables -A FORWARD \
        -i eth0 -o eth1 -s 10.10.1.2 -d 10.10.3.2 \
        -p tcp --dport 8080 -m conntrack --ctstate NEW \
        -m comment --comment stage3-http-new -j ACCEPT
    ip netns exec lab-fw iptables -A FORWARD \
        -i eth0 -o eth1 -s 10.10.1.2 -d 10.10.3.2 \
        -p tcp -m comment --comment stage3-reject-other-tcp \
        -j REJECT --reject-with tcp-reset
    ip netns exec lab-fw iptables -A FORWARD \
        -i eth1 -o eth0 -s 10.10.3.2 -d 10.10.1.2 \
        -m conntrack --ctstate NEW \
        -m comment --comment stage3-drop-new -j DROP
}

start_http_server() {
    mkdir -p "$RUNTIME_DIR"
    stop_http_server

    ip netns exec lab-server python3 -m http.server 8080 \
        --bind 10.10.3.2 --directory "$SCRIPT_DIR/docs" \
        >"$HTTP_LOG" 2>&1 &
    printf '%s\n' "$!" >"$HTTP_PID_FILE"
}

wait_for_http_server() {
    local attempt

    for ((attempt = 1; attempt <= 10; attempt++)); do
        if ip netns exec lab-client curl -fsS --max-time 1 \
            http://10.10.3.2:8080/STATE.md >/dev/null; then
            return
        fi
        sleep 0.1
    done

    printf 'HTTP server did not become reachable; see %s.\n' "$HTTP_LOG" >&2
    return 1
}

setup_stage_three() {
    trap 'cleanup_stage_one' ERR

    setup_stage_two
    trap 'cleanup_stage_one' ERR

    configure_stage_three_acl
    start_http_server
    wait_for_http_server

    trap - ERR
    printf 'Stage 3 firewall and HTTP service are up.\n'
}

configure_stage_four_acl() {
    configure_stage_three_acl
    ip netns exec lab-fw iptables -I FORWARD 4 \
        -i eth0 -o eth1 -s 10.10.2.1 -d 10.10.3.2 \
        -p tcp --dport 8080 -m conntrack --ctstate NEW \
        -m comment --comment stage4-snat-http-new -j ACCEPT
}

set_nat_mode() {
    local mode=$1

    case "$mode" in
        off | snat | dnat) ;;
        *)
            printf 'NAT modes: off, snat, or dnat; requested mode: %s\n' "$mode" >&2
            return 2
            ;;
    esac

    ip netns exec lab-router iptables -t nat -F
    ip netns exec lab-router iptables -t nat -X
    ip netns exec lab-router conntrack -F >/dev/null

    case "$mode" in
        snat)
            ip netns exec lab-router iptables -t nat -A POSTROUTING \
                -s 10.10.1.2 -d 10.10.3.2 -o eth1 \
                -p tcp --dport 8080 \
                -m comment --comment stage4-snat \
                -j SNAT --to-source 10.10.2.1
            ;;
        dnat)
            ip netns exec lab-router iptables -t nat -A PREROUTING \
                -i eth0 -d 10.10.1.1 \
                -p tcp --dport 8080 \
                -m comment --comment stage4-dnat \
                -j DNAT --to-destination 10.10.3.2:8080
            ;;
    esac

    printf 'NAT mode: %s\n' "$mode"
}

show_nat_mode() {
    local rules

    rules=$(ip netns exec lab-router iptables -t nat -S)
    if [[ "$rules" == *"stage4-snat"* ]]; then
        printf 'snat'
    elif [[ "$rules" == *"stage4-dnat"* ]]; then
        printf 'dnat'
    else
        printf 'off'
    fi
}

setup_stage_four() {
    trap 'cleanup_stage_one' ERR

    setup_stage_three
    trap 'cleanup_stage_one' ERR

    configure_stage_four_acl
    set_nat_mode off

    trap - ERR
    printf 'Stage 4 is up with NAT disabled by default.\n'
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

require_stage_four_topology() {
    local rules

    require_stage_one_topology
    rules=$(ip netns exec lab-fw iptables -S FORWARD)
    if [[ "$rules" != *"stage4-snat-http-new"* ]]; then
        printf 'Stage 4 is not active. Run: sudo ./lab.sh up 4\n' >&2
        return 1
    fi
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

assert_forwarding() {
    local namespace=$1
    local expected=$2
    local value

    value=$(ip netns exec "$namespace" sysctl -n net.ipv4.ip_forward)
    if [[ "$value" != "$expected" ]]; then
        printf 'Unexpected IPv4 forwarding in %s: expected %s, got %s.\n' \
            "$namespace" "$expected" "$value" >&2
        return 1
    fi
}

assert_route() {
    local namespace=$1
    local destination=$2
    local expected=$3
    local actual

    actual=$(ip -n "$namespace" route show "$destination")
    if [[ "$actual" != "$expected" ]]; then
        printf 'Unexpected route in %s for %s.\nExpected: %s\nActual:   %s\n' \
            "$namespace" "$destination" "$expected" "${actual:-<missing>}" >&2
        return 1
    fi
}

test_stage_two() {
    require_stage_one_topology

    assert_forwarding lab-client 0
    assert_forwarding lab-router 1
    assert_forwarding lab-fw 1
    assert_forwarding lab-server 0

    assert_route lab-client default 'default via 10.10.1.1 dev eth0'
    assert_route lab-router 10.10.3.0/24 '10.10.3.0/24 via 10.10.2.2 dev eth1'
    assert_route lab-fw 10.10.1.0/24 '10.10.1.0/24 via 10.10.2.1 dev eth0'
    assert_route lab-server default 'default via 10.10.3.1 dev eth0'

    ip netns exec lab-client ping -c 2 -W 1 10.10.3.2
    ip netns exec lab-server ping -c 2 -W 1 10.10.1.2

    printf '\nStage 2 routes:\n'
    ip -n lab-client route show
    ip -n lab-router route show
    ip -n lab-fw route show
    ip -n lab-server route show
}

expect_curl_failure() {
    local namespace=$1
    local url=$2
    local description=$3

    if ip netns exec "$namespace" curl -fsS --connect-timeout 2 \
        --max-time 2 "$url" >/dev/null 2>&1; then
        printf 'Unexpected success: %s.\n' "$description" >&2
        return 1
    fi
    printf '[ok] %s\n' "$description"
}

test_stage_three() {
    local response

    require_stage_one_topology
    assert_forwarding lab-client 0
    assert_forwarding lab-router 1
    assert_forwarding lab-fw 1
    assert_forwarding lab-server 0

    ip netns exec lab-client ping -c 2 -W 1 10.10.3.2

    response=$(ip netns exec lab-client curl -fsS --max-time 3 \
        http://10.10.3.2:8080/STATE.md)
    if [[ "$response" != *"# Project State"* ]]; then
        printf 'Unexpected HTTP response from server.\n' >&2
        return 1
    fi
    printf '[ok] HTTP NEW request and ESTABLISHED response on TCP/8080\n'

    expect_curl_failure lab-client http://10.10.3.2:8081/ \
        'other client-to-server TCP is rejected'
    expect_curl_failure lab-server http://10.10.1.2:8080/ \
        'new server-to-client traffic is dropped'

    printf '\nStage 3 firewall counters:\n'
    ip netns exec lab-fw iptables -L FORWARD -v -n --line-numbers
}

assert_conntrack_contains() {
    local entries=$1
    local expected=$2
    local description=$3

    if [[ "$entries" != *"$expected"* ]]; then
        printf 'Missing conntrack observation for %s: %s\n' \
            "$description" "$expected" >&2
        return 1
    fi
}

test_stage_four() {
    local response
    local entries

    require_stage_four_topology
    trap 'set_nat_mode off' ERR

    set_nat_mode snat
    response=$(ip netns exec lab-client curl -fsS --max-time 3 \
        http://10.10.3.2:8080/STATE.md)
    [[ "$response" == *"# Project State"* ]]
    entries=$(ip netns exec lab-router conntrack -L -p tcp --dport 8080 2>/dev/null)
    assert_conntrack_contains "$entries" 'src=10.10.1.2 dst=10.10.3.2' SNAT
    assert_conntrack_contains "$entries" 'src=10.10.3.2 dst=10.10.2.1' SNAT
    printf '[ok] SNAT changed the reply destination to 10.10.2.1 in conntrack\n'
    ip netns exec lab-router iptables -t nat -L POSTROUTING -v -n --line-numbers
    printf '%s\n' "$entries"

    set_nat_mode dnat
    response=$(ip netns exec lab-client curl -fsS --max-time 3 \
        http://10.10.1.1:8080/STATE.md)
    [[ "$response" == *"# Project State"* ]]
    entries=$(ip netns exec lab-router conntrack -L -p tcp --dport 8080 2>/dev/null)
    assert_conntrack_contains "$entries" 'src=10.10.1.2 dst=10.10.1.1' DNAT
    assert_conntrack_contains "$entries" 'src=10.10.3.2 dst=10.10.1.2' DNAT
    printf '[ok] DNAT mapped 10.10.1.1:8080 to server TCP/8080\n'
    ip netns exec lab-router iptables -t nat -L PREROUTING -v -n --line-numbers
    printf '%s\n' "$entries"

    set_nat_mode off
    trap - ERR
}

show_status() {
    local namespace

    printf 'Completed stage: %s\n' "$COMPLETED_STAGE"
    for namespace in "${NAMESPACES[@]}"; do
        if namespace_exists "$namespace"; then
            printf '\n[%s]\n' "$namespace"
            ip -brief -n "$namespace" address show
            ip -n "$namespace" route show
            printf 'IPv4 forwarding: '
            ip netns exec "$namespace" sysctl -n net.ipv4.ip_forward
        else
            printf '\n[%s] absent\n' "$namespace"
        fi
    done

    if namespace_exists lab-fw; then
        printf '\n[lab-fw filter/FORWARD]\n'
        ip netns exec lab-fw iptables -L FORWARD -v -n --line-numbers
    fi
    if namespace_exists lab-router; then
        printf '\n[lab-router NAT]\n'
        printf 'Mode: '
        show_nat_mode
        printf '\n'
        ip netns exec lab-router iptables -t nat -L -v -n --line-numbers
    fi
    if [[ -r "$HTTP_PID_FILE" ]]; then
        printf '\nHTTP PID: %s\n' "$(<"$HTTP_PID_FILE")"
    fi
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
            case "$stage" in
                1) require_root; setup_stage_one ;;
                2) require_root; setup_stage_two ;;
                3) require_root; setup_stage_three ;;
                4) require_root; setup_stage_four ;;
            esac
            ;;
        test)
            [[ $# -eq 2 ]] || { usage >&2; return 2; }
            stage=$2
            require_supported_stage "$stage"
            check_environment
            case "$stage" in
                1) require_root; test_stage_one ;;
                2) require_root; test_stage_two ;;
                3) require_root; test_stage_three ;;
                4) require_root; test_stage_four ;;
            esac
            ;;
        nat)
            [[ $# -eq 2 ]] || { usage >&2; return 2; }
            require_root
            require_stage_four_topology
            set_nat_mode "$2"
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
