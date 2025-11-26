#!/bin/bash

###############################################
# deploy_web.sh - Deploy HTML files to front-end server
# and log the deployment process.
# This script assumes that the front-end server is accessible via SSH.
###############################################


# User-configurable variables
FRONTEND_HOST="u1-phoenix"
FRONTEND_USER="phoenix"

LOGSERVER_HOST="u4-naruhodo"
LOGSERVER_USER="naruhodo"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL_HTML_DIR="$SCRIPT_DIR/../html"
LOCAL_LOG_DIR="$SCRIPT_DIR/../_logs"

LOGFILE="$LOCAL_LOG_DIR/deploy_web_$(date +%Y%m%d).log"
MANIFESTFILE="$LOCAL_LOG_DIR/manifest_web_$(date +%Y%m%d).csv"

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

log "===== Web Deployment START at $(date) ====="

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
# 2. Show number of items that will be overwritten
###############################################
log "Checking for existing items on the front-end server..."

# Collect filenames in local HTML directory
LOCAL_ITEMS=($(ls -1 "$LOCAL_HTML_DIR"))
OVERWRITE_COUNT=0

# Check how many exist on remote server
for ITEM in "${LOCAL_ITEMS[@]}"; do
    if ssh "$FRONTEND_USER@$FRONTEND_HOST" "[ -e '$REMOTE_HTML_DIR/$ITEM' ]"; then
        ((OVERWRITE_COUNT++))
    fi
done

log "Items found locally: ${#LOCAL_ITEMS[@]}"
log "Items that will be overwritten on server: $OVERWRITE_COUNT"

echo
read -p "Proceed with deployment? (yes/no): " CONFIRM

CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]') # normalize to lowercase
[[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]] && log "Aborted by user." && exit 0 # Exit if not confirmed

###############################################
# 3. Deploy items — rename remote file if exists
###############################################
log "Deploying files..."

for ITEM in "${LOCAL_ITEMS[@]}"; do
    log "Processing $ITEM..."
    
    # Determine item type and whether it already exists on remote for manifest
    ITEM_PATH="$LOCAL_HTML_DIR/$ITEM"
    if [ -d "$ITEM_PATH" ]; then TYPE="dir"; else TYPE="file"; fi
    if ssh "$FRONTEND_USER@$FRONTEND_HOST" "[ -e '$REMOTE_HTML_DIR/$ITEM' ]"; then
        ACTION="updated"
        PREV_PATH="$REMOTE_HTML_DIR/$ITEM.old"
    else
        ACTION="created"
        PREV_PATH=""
    fi
    echo "$ACTION,$ITEM,$TYPE,$PREV_PATH" >> "$MANIFESTFILE" # Log to manifest
    
    # If exists, rename old file
    ssh "$FRONTEND_USER@$FRONTEND_HOST" \
        "if [ -e '$REMOTE_HTML_DIR/$ITEM' ]; then mv '$REMOTE_HTML_DIR/$ITEM' '$REMOTE_HTML_DIR/$ITEM.old'; fi" \
        2>&1 | tee -a "$LOGFILE"

    # Copy new file
    scp "$LOCAL_HTML_DIR/$ITEM" "$FRONTEND_USER@$FRONTEND_HOST:$REMOTE_HTML_DIR/" \
        2>&1 | tee -a "$LOGFILE"
done

log "Deployment complete."

###############################################
# 4. Send log file to log server
###############################################

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

# Also send the manifest to the log server
log "Sending manifest to log server ($LOGSERVER_HOST)..."
if scp "$MANIFESTFILE" "$LOGSERVER_USER@$LOGSERVER_HOST:$REMOTE_LOG_DIR/"; then
    log "Manifest transferred to log server successfully."
else
    log "WARNING: Failed to transfer manifest to log server!"
fi

log "===== Web Deployment END at $(date) ====="
