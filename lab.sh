#!/usr/bin/env bash
set -Eeuo pipefail

readonly COMPLETED_STAGE=0

usage() {
    cat <<'EOF'
Usage:
  ./lab.sh check
  ./lab.sh up 0
  ./lab.sh test 0
  ./lab.sh status
  ./lab.sh down
EOF
}

check_environment() {
    local -a required=(bash ip sysctl iptables tc ping)
    local -a optional=(curl iperf3 tcpdump conntrack shellcheck)
    local tool
    local missing=0

    printf 'Required tools:\n'
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

require_stage_zero() {
    local stage=${1:-}

    if [[ "$stage" != "0" ]]; then
        printf 'Only Stage 0 is implemented; requested stage: %s\n' "${stage:-<missing>}" >&2
        return 2
    fi
}

main() {
    local command=${1:-}

    case "$command" in
        check)
            [[ $# -eq 1 ]] || { usage >&2; return 2; }
            check_environment
            ;;
        up | test)
            [[ $# -eq 2 ]] || { usage >&2; return 2; }
            require_stage_zero "$2"
            check_environment
            ;;
        status)
            [[ $# -eq 1 ]] || { usage >&2; return 2; }
            printf 'Completed stage: %s\n' "$COMPLETED_STAGE"
            printf 'Active lab resources: none\n'
            ;;
        down)
            [[ $# -eq 1 ]] || { usage >&2; return 2; }
            printf 'Stage 0 creates no resources; nothing to remove.\n'
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
