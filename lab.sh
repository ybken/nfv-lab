#!/usr/bin/env bash
set -Eeuo pipefail

readonly COMPLETED_STAGE=7
readonly -a NAMESPACES=(lab-client lab-router lab-fw lab-server)
readonly -a HOST_VETHS=(lab-c lab-r0 lab-r1 lab-f0 lab-f1 lab-s)
readonly -a CAPTURE_NAMES=(client router-in router-out fw-in fw-out server)
readonly -a CAPTURE_NAMESPACES=(lab-client lab-router lab-router lab-fw lab-fw lab-server)
readonly -a CAPTURE_INTERFACES=(eth0 eth0 eth1 eth0 eth1 eth0)
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly RUNTIME_DIR="$SCRIPT_DIR/run"
readonly HTTP_PID_FILE="$RUNTIME_DIR/http.pid"
readonly HTTP_LOG="$RUNTIME_DIR/http.log"
readonly IPERF_PID_FILE="$RUNTIME_DIR/iperf3.pid"
readonly IPERF_LOG="$RUNTIME_DIR/iperf3.log"
readonly QOS_PAYLOAD="$RUNTIME_DIR/qos.bin"
readonly QOS_READY_FILE="$RUNTIME_DIR/stage5.ready"
readonly STAGE6_READY_FILE="$RUNTIME_DIR/stage6.ready"
readonly STAGE7_READY_FILE="$RUNTIME_DIR/stage7.ready"
readonly CAPTURE_DIR="$SCRIPT_DIR/captures"
readonly CAPTURE_PID_DIR="$RUNTIME_DIR/capture-pids"

usage() {
    cat <<'EOF'
Usage:
  ./lab.sh check
  sudo ./lab.sh up <0|1|2|3|4|5|6|7>
  sudo ./lab.sh test <0|1|2|3|4|5|6|7>
  sudo ./lab.sh nat <off|snat|dnat>
  sudo ./lab.sh qos off
  sudo ./lab.sh qos set <rate> <delay> <loss>
  sudo ./lab.sh capture <start|stop|status|summary>
  sudo ./lab.sh status
  sudo ./lab.sh down
EOF
}

check_environment() {
    local -a required=(bash ip sysctl ping iptables curl python3 conntrack tc truncate awk tcpdump iperf3)
    local -a optional=(shellcheck)
    local tool
    local missing=0

    printf 'Required tools through Stage 7:\n'
    for tool in "${required[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf '  [ok] %s\n' "$tool"
        else
            printf '  [missing] %s\n' "$tool"
            missing=1
        fi
    done

    printf 'Optional static validation tools:\n'
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

    if [[ ! "$stage" =~ ^[01234567]$ ]]; then
        printf 'Supported stages: 0 through 7; requested stage: %s\n' "${stage:-<missing>}" >&2
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
        "$command_line" == *"--directory $SCRIPT_DIR"* ]]
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

is_project_iperf_pid() {
    local pid=$1
    local command_line

    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1
    command_line=$(tr '\0' ' ' <"/proc/$pid/cmdline")
    [[ "$command_line" == *"iperf3 -s"* ]]
}

stop_iperf_server() {
    local pid
    local -a pids=()

    if [[ -r "$IPERF_PID_FILE" ]]; then
        pid=$(<"$IPERF_PID_FILE")
        pids+=("$pid")
    fi
    if namespace_exists lab-server; then
        mapfile -t namespace_pids < <(ip netns pids lab-server)
        pids+=("${namespace_pids[@]}")
    fi

    for pid in "${pids[@]}"; do
        if is_project_iperf_pid "$pid"; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -f "$IPERF_PID_FILE"
}

is_project_capture_pid() {
    local pid=$1
    local command_line

    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1
    command_line=$(tr '\0' ' ' <"/proc/$pid/cmdline")
    [[ "$command_line" == *"tcpdump"* && "$command_line" == *"$CAPTURE_DIR/"* ]]
}

stop_captures() {
    local pid_file
    local pid
    local namespace
    local -a pids=()

    if [[ -d "$CAPTURE_PID_DIR" ]]; then
        for pid_file in "$CAPTURE_PID_DIR"/*.pid; do
            [[ -e "$pid_file" ]] || continue
            pid=$(<"$pid_file")
            pids+=("$pid")
            rm -f "$pid_file"
        done
        rmdir "$CAPTURE_PID_DIR" 2>/dev/null || true
    fi

    for namespace in "${NAMESPACES[@]}"; do
        if namespace_exists "$namespace"; then
            mapfile -t namespace_pids < <(ip netns pids "$namespace")
            pids+=("${namespace_pids[@]}")
        fi
    done

    for pid in "${pids[@]}"; do
        if is_project_capture_pid "$pid"; then
            kill -INT "$pid" 2>/dev/null || true
        fi
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

cleanup_stage_one() {
    local namespace
    local link

    stop_captures
    stop_iperf_server
    stop_http_server
    rm -f "$QOS_PAYLOAD" "$QOS_READY_FILE" "$STAGE6_READY_FILE" "$STAGE7_READY_FILE"

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

verify_cleanup() {
    local namespace
    local link

    for namespace in "${NAMESPACES[@]}"; do
        if namespace_exists "$namespace"; then
            printf 'Cleanup failed; namespace remains: %s\n' "$namespace" >&2
            return 1
        fi
    done
    for link in "${HOST_VETHS[@]}"; do
        if ip link show dev "$link" >/dev/null 2>&1; then
            printf 'Cleanup failed; host link remains: %s\n' "$link" >&2
            return 1
        fi
    done
    if [[ -e "$HTTP_PID_FILE" || -e "$IPERF_PID_FILE" || -d "$CAPTURE_PID_DIR" ||
        -e "$QOS_PAYLOAD" || -e "$QOS_READY_FILE" ||
        -e "$STAGE6_READY_FILE" || -e "$STAGE7_READY_FILE" ]]; then
        printf 'Cleanup failed; a project PID record remains.\n' >&2
        return 1
    fi
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
        --bind 10.10.3.2 --directory "$SCRIPT_DIR" \
        >"$HTTP_LOG" 2>&1 &
    printf '%s\n' "$!" >"$HTTP_PID_FILE"
}

wait_for_http_server() {
    local attempt

    for ((attempt = 1; attempt <= 10; attempt++)); do
        if ip netns exec lab-client curl -fsS --max-time 1 \
            http://10.10.3.2:8080/docs/STATE.md >/dev/null; then
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

validate_qos_parameters() {
    local rate=$1
    local delay=$2
    local loss=$3

    [[ "$rate" =~ ^[1-9][0-9]*(kbit|mbit|gbit)$ ]] || {
        printf 'Invalid rate: %s (example: 4mbit).\n' "$rate" >&2
        return 2
    }
    [[ "$delay" =~ ^[0-9]+(us|ms|s)$ ]] || {
        printf 'Invalid delay: %s (example: 50ms).\n' "$delay" >&2
        return 2
    }
    [[ "$loss" =~ ^([0-9]|[1-9][0-9])([.][0-9]+)?%$|^100([.]0+)?%$ ]] || {
        printf 'Invalid loss: %s (range: 0%% through 100%%).\n' "$loss" >&2
        return 2
    }
}

set_qos() {
    local rate=$1
    local delay=$2
    local loss=$3

    validate_qos_parameters "$rate" "$delay" "$loss"
    ip netns exec lab-fw tc qdisc replace dev eth0 root handle 1: \
        tbf rate "$rate" burst 32kbit latency 400ms
    ip netns exec lab-fw tc qdisc replace dev eth0 parent 1:1 handle 10: \
        netem delay "$delay" loss "$loss"
    printf 'QoS: rate=%s delay=%s loss=%s\n' "$rate" "$delay" "$loss"
}

remove_qos() {
    ip netns exec lab-fw tc qdisc delete dev eth0 root 2>/dev/null || true
    printf 'QoS: off\n'
}

setup_stage_five() {
    trap 'cleanup_stage_one' ERR

    setup_stage_four
    trap 'cleanup_stage_one' ERR

    truncate -s 2M "$QOS_PAYLOAD"
    touch "$QOS_READY_FILE"
    remove_qos

    trap - ERR
    printf 'Stage 5 is up with QoS disabled by default.\n'
}

setup_stage_six() {
    trap 'cleanup_stage_one' ERR

    setup_stage_five
    trap 'cleanup_stage_one' ERR

    mkdir -p "$RUNTIME_DIR"
    touch "$STAGE6_READY_FILE"
    stop_captures

    trap - ERR
    printf 'Stage 6 is up with packet capture stopped.\n'
}

configure_stage_seven_acl() {
    configure_stage_four_acl
    ip netns exec lab-fw iptables -I FORWARD 5 \
        -i eth0 -o eth1 -s 10.10.1.2 -d 10.10.3.2 \
        -p tcp --dport 5201 -m conntrack --ctstate NEW \
        -m comment --comment stage7-iperf-new -j ACCEPT
}

start_iperf_server() {
    mkdir -p "$RUNTIME_DIR"
    stop_iperf_server

    ip netns exec lab-server iperf3 -s >"$IPERF_LOG" 2>&1 &
    printf '%s\n' "$!" >"$IPERF_PID_FILE"
    sleep 0.2
    if ! is_project_iperf_pid "$!"; then
        printf 'iperf3 server failed to start; see %s.\n' "$IPERF_LOG" >&2
        return 1
    fi
}

setup_stage_seven() {
    trap 'cleanup_stage_one' ERR

    setup_stage_six
    trap 'cleanup_stage_one' ERR

    configure_stage_seven_acl
    start_iperf_server
    touch "$STAGE7_READY_FILE"

    trap - ERR
    printf 'Stage 7 lab is up; NAT, QoS, and capture are off.\n'
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

require_stage_five_topology() {
    require_stage_four_topology
    if [[ ! -f "$QOS_READY_FILE" || ! -f "$QOS_PAYLOAD" ]]; then
        printf 'Stage 5 is not active. Run: sudo ./lab.sh up 5\n' >&2
        return 1
    fi
}

require_stage_six_topology() {
    require_stage_five_topology
    if [[ ! -f "$STAGE6_READY_FILE" ]]; then
        printf 'Stage 6 is not active. Run: sudo ./lab.sh up 6\n' >&2
        return 1
    fi
}

require_stage_seven_topology() {
    local pid
    local rules

    require_stage_six_topology
    rules=$(ip netns exec lab-fw iptables -S FORWARD)
    if [[ ! -f "$STAGE7_READY_FILE" || "$rules" != *"stage7-iperf-new"* ]]; then
        printf 'Stage 7 is not active. Run: sudo ./lab.sh up 7\n' >&2
        return 1
    fi
    if [[ ! -r "$IPERF_PID_FILE" ]]; then
        printf 'iperf3 PID file is missing. Run: sudo ./lab.sh up 7\n' >&2
        return 1
    fi
    pid=$(<"$IPERF_PID_FILE")
    if ! is_project_iperf_pid "$pid"; then
        printf 'iperf3 server is not running. Run: sudo ./lab.sh up 7\n' >&2
        return 1
    fi
}

start_captures() {
    local index
    local name
    local namespace
    local interface
    local pid

    stop_captures
    mkdir -p "$CAPTURE_DIR" "$CAPTURE_PID_DIR"

    for index in "${!CAPTURE_NAMES[@]}"; do
        name=${CAPTURE_NAMES[$index]}
        namespace=${CAPTURE_NAMESPACES[$index]}
        interface=${CAPTURE_INTERFACES[$index]}
        rm -f "$CAPTURE_DIR/$name.pcap" "$CAPTURE_DIR/$name.log"
        ip netns exec "$namespace" tcpdump -U -n -i "$interface" -s 0 \
            -w "$CAPTURE_DIR/$name.pcap" \
            'icmp or tcp port 8080' >"$CAPTURE_DIR/$name.log" 2>&1 &
        pid=$!
        printf '%s\n' "$pid" >"$CAPTURE_PID_DIR/$name.pid"
    done

    sleep 0.3
    for name in "${CAPTURE_NAMES[@]}"; do
        pid=$(<"$CAPTURE_PID_DIR/$name.pid")
        if ! is_project_capture_pid "$pid"; then
            printf 'Capture failed to start: %s; see %s.\n' \
                "$name" "$CAPTURE_DIR/$name.log" >&2
            stop_captures
            return 1
        fi
    done
    printf 'Packet capture started in %s.\n' "$CAPTURE_DIR"
}

show_capture_status() {
    local name
    local pid

    for name in "${CAPTURE_NAMES[@]}"; do
        if [[ -r "$CAPTURE_PID_DIR/$name.pid" ]]; then
            pid=$(<"$CAPTURE_PID_DIR/$name.pid")
            if is_project_capture_pid "$pid"; then
                printf '%-10s running pid=%s\n' "$name" "$pid"
                continue
            fi
        fi
        printf '%-10s stopped\n' "$name"
    done
}

summarize_captures() {
    local name
    local capture

    for name in "${CAPTURE_NAMES[@]}"; do
        capture="$CAPTURE_DIR/$name.pcap"
        if [[ ! -s "$capture" ]]; then
            printf 'Missing or empty capture: %s\n' "$capture" >&2
            return 1
        fi
        printf '\n[%s]\n' "$name"
        tcpdump -e -n -r "$capture" -c 8 2>/dev/null
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

assert_interface() {
    local namespace=$1
    local interface=$2
    local address=$3
    local link
    local addresses

    link=$(ip -o -n "$namespace" link show dev "$interface")
    addresses=$(ip -o -4 -n "$namespace" address show dev "$interface")
    if [[ "$link" != *"<"*",UP,"* && "$link" != *"<UP,"* ]]; then
        printf 'Interface is not up: %s/%s.\n' "$namespace" "$interface" >&2
        return 1
    fi
    if [[ "$addresses" != *"inet $address "* ]]; then
        printf 'Missing address %s on %s/%s.\n' \
            "$address" "$namespace" "$interface" >&2
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
        http://10.10.3.2:8080/docs/STATE.md)
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
        http://10.10.3.2:8080/docs/STATE.md)
    [[ "$response" == *"# Project State"* ]]
    entries=$(ip netns exec lab-router conntrack -L -p tcp --dport 8080 2>/dev/null)
    assert_conntrack_contains "$entries" 'src=10.10.1.2 dst=10.10.3.2' SNAT
    assert_conntrack_contains "$entries" 'src=10.10.3.2 dst=10.10.2.1' SNAT
    printf '[ok] SNAT changed the reply destination to 10.10.2.1 in conntrack\n'
    ip netns exec lab-router iptables -t nat -L POSTROUTING -v -n --line-numbers
    printf '%s\n' "$entries"

    set_nat_mode dnat
    response=$(ip netns exec lab-client curl -fsS --max-time 3 \
        http://10.10.1.1:8080/docs/STATE.md)
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

test_stage_five() {
    local qdiscs
    local speed

    require_stage_five_topology
    trap 'remove_qos' ERR

    set_qos 4mbit 50ms 1%
    qdiscs=$(ip netns exec lab-fw tc qdisc show dev eth0)
    [[ "$qdiscs" == *"qdisc tbf 1:"* && "$qdiscs" == *"rate 4Mbit"* ]]
    [[ "$qdiscs" == *"qdisc netem 10:"* && "$qdiscs" == *"delay 50ms"* &&
        "$qdiscs" == *"loss 1%"* ]]

    speed=$(ip netns exec lab-client curl -fsS --max-time 15 \
        -o /dev/null -w '%{speed_download}' \
        http://10.10.3.2:8080/run/qos.bin)
    if ! awk -v speed="$speed" 'BEGIN { exit !(speed > 0 && speed <= 700000) }'; then
        printf 'Unexpected download rate: %s bytes/s.\n' "$speed" >&2
        return 1
    fi
    printf '[ok] Download limited to %s bytes/s\n' "$speed"
    ip netns exec lab-client ping -c 3 -W 2 10.10.3.2
    ip netns exec lab-fw tc -s qdisc show dev eth0

    remove_qos
    qdiscs=$(ip netns exec lab-fw tc qdisc show dev eth0)
    if [[ "$qdiscs" == *" tbf "* || "$qdiscs" == *" netem "* ]]; then
        printf 'QoS qdisc remains after removal.\n' >&2
        return 1
    fi
    trap - ERR
}

test_stage_six() {
    local name

    require_stage_six_topology
    trap 'stop_captures' ERR

    start_captures
    ip netns exec lab-client ping -c 2 -W 1 10.10.3.2
    ip netns exec lab-client curl -fsS --max-time 3 \
        http://10.10.3.2:8080/docs/STATE.md >/dev/null
    sleep 0.2
    stop_captures

    for name in "${CAPTURE_NAMES[@]}"; do
        if [[ ! -s "$CAPTURE_DIR/$name.pcap" ]]; then
            printf 'Capture is empty: %s.pcap\n' "$name" >&2
            return 1
        fi
        tcpdump -n -r "$CAPTURE_DIR/$name.pcap" -c 1 >/dev/null 2>&1
    done
    summarize_captures
    trap - ERR
}

test_stage_seven() {
    local qdiscs

    require_stage_seven_topology
    trap 'set_nat_mode off; remove_qos; stop_captures' ERR

    assert_interface lab-client eth0 10.10.1.2/24
    assert_interface lab-router eth0 10.10.1.1/24
    assert_interface lab-router eth1 10.10.2.1/24
    assert_interface lab-fw eth0 10.10.2.2/24
    assert_interface lab-fw eth1 10.10.3.1/24
    assert_interface lab-server eth0 10.10.3.2/24

    test_stage_two
    test_stage_three

    printf '\n[iperf3]\n'
    ip netns exec lab-client iperf3 -c 10.10.3.2 -t 2

    test_stage_four
    test_stage_five
    test_stage_six

    [[ "$(show_nat_mode)" == "off" ]]
    qdiscs=$(ip netns exec lab-fw tc qdisc show dev eth0)
    [[ "$qdiscs" != *" tbf "* && "$qdiscs" != *" netem "* ]]
    [[ ! -d "$CAPTURE_PID_DIR" ]]

    trap - ERR
    printf '\nStage 7 full test passed; optional modes restored to off.\n'
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
    if namespace_exists lab-fw; then
        printf '\n[lab-fw QoS on eth0]\n'
        ip netns exec lab-fw tc -s qdisc show dev eth0
    fi
    if [[ -r "$HTTP_PID_FILE" ]]; then
        pid=$(<"$HTTP_PID_FILE")
        if is_project_http_pid "$pid"; then
            printf '\nHTTP: running pid=%s\n' "$pid"
        else
            printf '\nHTTP: stale pid=%s\n' "$pid"
        fi
    fi
    if [[ -r "$IPERF_PID_FILE" ]]; then
        pid=$(<"$IPERF_PID_FILE")
        if is_project_iperf_pid "$pid"; then
            printf 'iperf3: running pid=%s\n' "$pid"
        else
            printf 'iperf3: stale pid=%s\n' "$pid"
        fi
    fi
    if [[ -f "$STAGE6_READY_FILE" ]]; then
        printf '\n[packet capture]\n'
        show_capture_status
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
                5) require_root; setup_stage_five ;;
                6) require_root; setup_stage_six ;;
                7) require_root; setup_stage_seven ;;
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
                5) require_root; test_stage_five ;;
                6) require_root; test_stage_six ;;
                7) require_root; test_stage_seven ;;
            esac
            ;;
        nat)
            [[ $# -eq 2 ]] || { usage >&2; return 2; }
            require_root
            require_stage_four_topology
            set_nat_mode "$2"
            ;;
        qos)
            require_root
            require_stage_five_topology
            case "${2:-}" in
                off)
                    [[ $# -eq 2 ]] || { usage >&2; return 2; }
                    remove_qos
                    ;;
                set)
                    [[ $# -eq 5 ]] || { usage >&2; return 2; }
                    set_qos "$3" "$4" "$5"
                    ;;
                *)
                    usage >&2
                    return 2
                    ;;
            esac
            ;;
        capture)
            [[ $# -eq 2 ]] || { usage >&2; return 2; }
            require_root
            require_stage_six_topology
            case "$2" in
                start) start_captures ;;
                stop) stop_captures ;;
                status) show_capture_status ;;
                summary) summarize_captures ;;
                *)
                    usage >&2
                    return 2
                    ;;
            esac
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
            verify_cleanup
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
