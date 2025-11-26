#!/usr/bin/env bash

###############################################
# revert_web.sh - Revert deployed HTML files on front-end server
# Restores .old backups created by deploy_web.sh and deletes current files.
# Logs all actions locally and ships the log to front-end and log server.
# Assumes SSH key-based access to both hosts.
###############################################

# User-configurable variables (match deploy_web.sh)
FRONTEND_HOST="u1-phoenix"
FRONTEND_USER="phoenix"

LOGSERVER_HOST="u4-naruhodo"
LOGSERVER_USER="naruhodo"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL_HTML_DIR="$SCRIPT_DIR/../html"
LOCAL_LOG_DIR="$SCRIPT_DIR/../_logs"

LOGFILE="$LOCAL_LOG_DIR/deploy_web_$(date +%Y%m%d).log"

REMOTE_HTML_DIR="/var/www/html"
REMOTE_LOG_DIR="/home/naruhodo/Desktop/_logs"

# Helper function: log to terminal + logfile
log() {
    echo "$1" | tee -a "$LOGFILE"
}

###############################################
# Start
###############################################
mkdir -p "$LOCAL_LOG_DIR" # Ensure log directory exists
: > "$LOGFILE"         # Create/clear logfile

log "===== Web Revert START at $(date) ====="

###############################################
# 1. Test SSH connection to front end server
###############################################
log "Testing SSH connection to $FRONTEND_HOST..."
if ! ssh -o BatchMode=yes "$FRONTEND_USER@$FRONTEND_HOST" "echo connection OK" &>/dev/null; then
    log "ERROR: Could not connect to $FRONTEND_HOST. Aborting."
    exit 1
fi
log "SSH connection successful."

###############################################
# 2. Determine items that can be reverted
###############################################
log "Scanning for .old backups on the front-end server..."

# Use local html entries as the set of names to check, similar scope as deploy
LOCAL_ITEMS=($(ls -1 "$LOCAL_HTML_DIR"))
REVERTABLE_COUNT=0

for ITEM in "${LOCAL_ITEMS[@]}"; do
    if ssh "$FRONTEND_USER@$FRONTEND_HOST" "[ -e '$REMOTE_HTML_DIR/$ITEM.old' ]"; then
        ((REVERTABLE_COUNT++))
    fi
done

log "Items found locally: ${#LOCAL_ITEMS[@]}"
log "Items with .old backup on server (revertable): $REVERTABLE_COUNT"

if [ "$REVERTABLE_COUNT" -eq 0 ]; then
    log "No .old backups found on the server. Nothing to revert."
    log "===== Web Revert END at $(date) ====="
    exit 0
fi

echo
read -p "Proceed with revert of $REVERTABLE_COUNT item(s)? (yes/no): " CONFIRM

CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]') # normalize to lowercase
[[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]] && log "Aborted by user." && exit 0 # Exit if not confirmed

###############################################
# 3. Revert items — delete new and restore .old
###############################################
log "Reverting files..."

for ITEM in "${LOCAL_ITEMS[@]}"; do
    log "Processing $ITEM..."

    ssh "$FRONTEND_USER@$FRONTEND_HOST" \
        "if [ -e '$REMOTE_HTML_DIR/$ITEM.old' ]; then \
            rm -rf '$REMOTE_HTML_DIR/$ITEM' 2>/dev/null; \
            mv '$REMOTE_HTML_DIR/$ITEM.old' '$REMOTE_HTML_DIR/$ITEM'; \
            echo 'Reverted: $ITEM'; \
        else \
            echo 'Skip (no .old): $ITEM'; \
        fi" \
        2>&1 | tee -a "$LOGFILE"

done

log "Revert operations complete."

###############################################
# 4. Send log file to front-end host and log server
###############################################
# 4a. Front-end host
log "Sending log file to front-end host ($FRONTEND_HOST)..."
if ssh "$FRONTEND_USER@$FRONTEND_HOST" "mkdir -p '$REMOTE_LOG_DIR'"; then
    log "Ensured remote log directory $REMOTE_LOG_DIR on front-end host."
else
    log "WARNING: Could not ensure remote log directory on front-end host!"
fi
if scp "$LOGFILE" "$FRONTEND_USER@$FRONTEND_HOST:$REMOTE_LOG_DIR/"; then
    log "Log file transferred to front-end host successfully."
else
    log "WARNING: Failed to transfer log file to front-end host!"
fi

# 4b. Log server
log "Sending log file to log server ($LOGSERVER_HOST)..."
# Ensure remote log directory on log server (best-effort)
if ssh "$LOGSERVER_USER@$LOGSERVER_HOST" "mkdir -p '$REMOTE_LOG_DIR'"; then
    log "Ensured remote log directory $REMOTE_LOG_DIR on log server."
else
    log "WARNING: Could not ensure remote log directory on log server!"
fi
if scp "$LOGFILE" "$LOGSERVER_USER@$LOGSERVER_HOST:$REMOTE_LOG_DIR/"; then
    log "Log file transferred to log server successfully."
else
    log "WARNING: Failed to transfer log file to log server!"
fi

log "===== Web Revert END at $(date) ====="
