#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
HAIRPIN_METRIC=99

IPV4_ENABLED=false
IPV6_ENABLED=false
DNS64_PREFIX=""
POLL_INTERVAL=60

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

A daemon that polls for external IPv4/IPv6 addresses and creates local routes
to mitigate hairpin NAT routing issues.

OPTIONS:
    --ipv4              Enable IPv4 polling and route creation
    --ipv6              Enable IPv6 polling and route creation
    --dns64 PREFIX      Create additional IPv6 route using DNS64 prefix
    --interval SECONDS  Polling interval in seconds (default: 60)
    --help              Show this help message

EXAMPLES:
    $SCRIPT_NAME --ipv4 --ipv6
    $SCRIPT_NAME --ipv4 --dns64 64:ff9b::/96
    $SCRIPT_NAME --ipv6 --interval 30

EOF
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

error() {
    log "ERROR: $*"
    exit 1
}

cleanup() {
    log "Cleaning up routes and exiting..."
    remove_all_routes
    rm -f "$LOCK_FILE"
    exit 0
}

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            error "Another instance is already running (PID: $pid)"
        else
            log "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

get_external_ipv4() {
    curl -s --max-time 10 https://api.ipify.org || echo ""
}

get_external_ipv6() {
    curl -s --max-time 10 https://api64.ipify.org || echo ""
}

is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" -ge 0 && "$octet" -le 255 ]] || return 1
    done
    return 0
}

is_valid_ipv6() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    return 0
}

create_dns64_ipv6() {
    local ipv4="$1"
    local prefix="$2"

    # Remove the /96 suffix if present
    prefix="${prefix%/*}"

    # Convert IPv4 to hex
    IFS='.' read -ra octets <<< "$ipv4"
    local hex_ip
    printf -v hex_ip "%02x%02x:%02x%02x" "${octets[0]}" "${octets[1]}" "${octets[2]}" "${octets[3]}"

    # Combine prefix with hex IP
    echo "${prefix}${hex_ip}"
}

add_route() {
    local ip="$1"
    local family="$2"

    if sudo ip route add local "$ip" dev lo proto static metric "$HAIRPIN_METRIC" 2>/dev/null; then
        log "Added $family route: $ip -> lo"
        return 0
    else
        log "Failed to add $family route: $ip"
        return 1
    fi
}

remove_route() {
    local ip="$1"
    local family="$2"

    if sudo ip route del local "$ip" dev lo proto static metric "$HAIRPIN_METRIC" 2>/dev/null; then
        log "Removed $family route: $ip -> lo"
        return 0
    else
        log "Failed to remove $family route: $ip (may not exist)"
        return 1
    fi
}

get_existing_routes() {
    ip -4 route show table local dev lo proto static metric "$HAIRPIN_METRIC" 2>/dev/null | awk '{print $2}'
    ip -6 route show table local dev lo proto static metric "$HAIRPIN_METRIC" 2>/dev/null | awk '{print $2}'
}

remove_all_routes() {
    local routes
    routes=$(get_existing_routes)
    if [[ -n "$routes" ]]; then
        while IFS= read -r route; do
            [[ -n "$route" ]] && remove_route "$route" "cleanup"
        done <<< "$routes"
    fi
}

get_current_routes() {
    local routes
    routes=$(get_existing_routes)

    LAST_IPV4=""
    LAST_IPV6=""
    LAST_DNS64=""

    while IFS= read -r route; do
        if [[ -n "$route" ]]; then
            if [[ "$route" =~ ^[0-9.]+/32$ ]]; then
                LAST_IPV4="${route%/32}"
            elif [[ "$route" =~ ^[0-9a-fA-F:]+/128$ ]]; then
                local ipv6="${route%/128}"
                if [[ -n "$DNS64_PREFIX" && "$ipv6" =~ ^${DNS64_PREFIX%::} ]]; then
                    LAST_DNS64="$ipv6"
                else
                    LAST_IPV6="$ipv6"
                fi
            fi
        fi
    done <<< "$routes"
}

poll_and_update() {
    local current_ipv4=""
    local current_ipv6=""
    local current_dns64=""
    local routes_changed=false

    # Get current IPs
    if [[ "$IPV4_ENABLED" == "true" ]]; then
        current_ipv4=$(get_external_ipv4)
        if [[ -n "$current_ipv4" ]] && is_valid_ipv4 "$current_ipv4"; then
            log "Detected IPv4: $current_ipv4"
        else
            log "Failed to get valid IPv4 address"
            current_ipv4=""
        fi
    fi

    if [[ "$IPV6_ENABLED" == "true" ]]; then
        current_ipv6=$(get_external_ipv6)
        if [[ -n "$current_ipv6" ]] && is_valid_ipv6 "$current_ipv6"; then
            log "Detected IPv6: $current_ipv6"
        else
            log "Failed to get valid IPv6 address"
            current_ipv6=""
        fi
    fi

    # Create DNS64 address if needed
    if [[ -n "$DNS64_PREFIX" && -n "$current_ipv4" ]]; then
        current_dns64=$(create_dns64_ipv6 "$current_ipv4" "$DNS64_PREFIX")
        log "Generated DNS64 IPv6: $current_dns64"
    fi

    # Check for changes and update routes
    if [[ "$current_ipv4" != "$LAST_IPV4" ]]; then
        if [[ -n "$LAST_IPV4" ]]; then
            remove_route "$LAST_IPV4/32" "IPv4"
        fi
        if [[ -n "$current_ipv4" ]]; then
            add_route "$current_ipv4/32" "IPv4"
        fi
        LAST_IPV4="$current_ipv4"
        routes_changed=true
    fi

    if [[ "$current_ipv6" != "$LAST_IPV6" ]]; then
        if [[ -n "$LAST_IPV6" ]]; then
            remove_route "$LAST_IPV6/128" "IPv6"
        fi
        if [[ -n "$current_ipv6" ]]; then
            add_route "$current_ipv6/128" "IPv6"
        fi
        LAST_IPV6="$current_ipv6"
        routes_changed=true
    fi

    if [[ "$current_dns64" != "$LAST_DNS64" ]]; then
        if [[ -n "$LAST_DNS64" ]]; then
            remove_route "$LAST_DNS64/128" "DNS64"
        fi
        if [[ -n "$current_dns64" ]]; then
            add_route "$current_dns64/128" "DNS64"
        fi
        LAST_DNS64="$current_dns64"
        routes_changed=true
    fi

    # Routes are automatically tracked via route table inspection
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ipv4)
                IPV4_ENABLED=true
                shift
                ;;
            --ipv6)
                IPV6_ENABLED=true
                shift
                ;;
            --dns64)
                DNS64_PREFIX="$2"
                shift 2
                ;;
            --interval)
                POLL_INTERVAL="$2"
                shift 2
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done

    # Validate arguments
    if [[ "$IPV4_ENABLED" == "false" && "$IPV6_ENABLED" == "false" ]]; then
        error "At least one of --ipv4 or --ipv6 must be specified"
    fi

    if [[ -n "$DNS64_PREFIX" && "$IPV4_ENABLED" == "false" ]]; then
        error "--dns64-* requires --ipv4 to be enabled"
    fi

    # Setup
    trap cleanup SIGTERM SIGINT
    acquire_lock

    # Remove any existing routes using the hairpin metric on startup
    log "Checking for and removing any existing hairpin routes on startup..."
    remove_all_routes

    get_current_routes

    log "Starting hairpin daemon (PID: $$)"
    log "IPv4 enabled: $IPV4_ENABLED"
    log "IPv6 enabled: $IPV6_ENABLED"
    [[ -n "$DNS64_PREFIX" ]] && log "DNS64 prefix: $DNS64_PREFIX"
    log "Poll interval: ${POLL_INTERVAL}s"

    # Main loop
    while true; do
        poll_and_update
        sleep "$POLL_INTERVAL"
    done
}

# Initialize state variables
LAST_IPV4=""
LAST_IPV6=""
LAST_DNS64=""

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
