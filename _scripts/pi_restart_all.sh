#!/bin/bash

###############################################
# restart_machines.sh - Restart multiple SSH machines
# from arrays of hostnames and users
###############################################

# Array of machines to restart (modify this array with your machines)
MACHINES=(
    "u1-phoenix"
    "u2-apollo"
    "u3-athena"
    "u4-naruhodo"
)

# Array of users for each machine (must match the order in MACHINES array)
USERS=(
    "phoenix"
    "apollo"
    "athena"
    "naruhodo"
)

SSH_PORT=22  # Fixed SSH port

# Logging configuration
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/restart_machines_$(date +%Y%m%d_%H%M%S).log"

# Helper function: log to terminal and file
log() {
    echo -- "[$(date '+%Y-%m-%d %H:%M:%S')] $@" | tee -a "$LOGFILE"
}

# Function to restart a single machine
restart_machine() {
    local host="$1"
    local user="$2"
    local index="$3"

    log "Machine $index: Attempting to restart $user@$host:$SSH_PORT"

    # Test SSH connectivity first
    if ! ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes "$user@$host" "echo 'Connection OK'" &>/dev/null; then
        log "ERROR: Could not connect to $host. Skipping restart."
        return 1
    fi

    log "Connected to $host, initiating restart..."

    # Execute the restart command
    if ssh -p "$SSH_PORT" "$user@$host" "sudo shutdown -r now 'Restart triggered by restart_machines.sh'" &>/dev/null; then
        log "SUCCESS: Restart initiated on $host"
        return 0
    else
        log "ERROR: Failed to initiate restart on $host"
        return 1
    fi
}

log ""
log "============================================="
log "===== Restart Machines Script START ====="
log "============================================="
log "Total machines to restart: ${#MACHINES[@]}"
log ""

# Confirm before proceeding
echo "Ready to restart the following machines:"
for i in "${!MACHINES[@]}"; do
    echo "  $((i+1)). ${USERS[$i]}@${MACHINES[$i]}:$SSH_PORT"
done
echo ""

read -p "Proceed with restart of all machines? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]]; then
    log "Aborted by user."
    exit 0
fi

log ""
log "Starting restart process..."
FAILED_RESTARTS=0

# Restart machines sequentially
for i in "${!MACHINES[@]}"; do
    MACHINE="${MACHINES[$i]}"
    USER="${USERS[$i]}"
    INDEX=$((i+1))

    log ""
    log "Restarting machine $INDEX/${#MACHINES[@]}: $USER@$MACHINE"

    if restart_machine "$MACHINE" "$USER" "$INDEX"; then
        log "Machine $INDEX ($MACHINE) restart initiated successfully"
    else
        log "Machine $INDEX ($MACHINE) failed to restart"
        ((FAILED_RESTARTS++))
    fi

done

log ""
log "============================================="
log "===== Restart Machines Script END ====="
log "============================================="

if [ $FAILED_RESTARTS -gt 0 ]; then
    log "Completed with $FAILED_RESTARTS failed restart(s)"
    exit 1
else
    log "All machines restarted successfully"
    exit 0
fi