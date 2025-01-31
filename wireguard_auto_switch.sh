#!/bin/bash

_wg_conf_dir="/etc/wireguard"
_log_file="/var/log/wireguard_failover.log"
_max_log_size=$((5 * 1024 * 1024))  # 5MB in bytes

# Function to log messages and check log file size
echo_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$_log_file"
    manage_log_size
}

# Function to manage log file size
manage_log_size() {
    if [[ -f "$_log_file" && $(stat -c%s "$_log_file") -ge $_max_log_size ]]; then
        echo_log "Log file exceeded 5MB, truncating..."
        truncate -s 0 "$_log_file"
    fi
}

# Read WireGuard configuration files
readarray -t _wg_confs < <(ls "$_wg_conf_dir"/*.conf 2>/dev/null | awk -F "/" '{print $NF}' | sed 's/.conf//g')

if [[ ${#_wg_confs[@]} -eq 0 ]]; then
    echo_log "No WireGuard configurations found! Exiting script."
    exit 1
fi

# Target IP or domain for connectivity check
_test_ip="8.8.8.8"

# Check interval in seconds
_check_int=10

# Get the currently active WireGuard interface
_curr_iface=$(wg show | grep 'interface:' | awk '{print $2}')

# Determine the index of the currently active interface
_curr_index=-1
for i in "${!_wg_confs[@]}"; do
    if [[ "${_wg_confs[$i]}" == "$_curr_iface" ]]; then
        _curr_index=$i
        break
    fi
done

# If no active WireGuard interface is found, start with the first one
if [[ $_curr_index -eq -1 ]]; then
    echo_log "No active WireGuard connection found. Starting first available configuration..."
    _curr_index=0
    wg-quick up "${_wg_confs[$_curr_index]}" 2>>"$_log_file" || {
        echo_log "Error starting ${_wg_confs[$_curr_index]}"
        exit 1
    }
}

# Function to check connection
check_connection() {
    ping -c 2 -W 3 "$_test_ip" &>/dev/null
    return $?
}

# Function to switch the WireGuard server
switch_server() {
    local next_index=$(( (_curr_index + 1) % ${#_wg_confs[@]} ))
    local next_config="${_wg_confs[$next_index]}"
    echo_log "Connection failed! Switching to server: $next_config"
    
    # Bring down the current connection
    wg-quick down "${_wg_confs[$_curr_index]}" 2>>"$_log_file" || echo_log "Error stopping ${_wg_confs[$_curr_index]}"
    
    # Start new connection
    wg-quick up "$next_config" 2>>"$_log_file" || {
        echo_log "Error starting $next_config"
        exit 1
    }
    
    # Pause after switching
    echo_log "Pausing for 30 seconds after switching..."
    sleep 30
    
    # Update index
    _curr_index=$next_index
}

# Main loop
while true; do
    if ! check_connection; then
        switch_server
    fi
    sleep "$_check_int"
done
