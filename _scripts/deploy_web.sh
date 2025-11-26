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
    echo -- "$@" | tee -a "$LOGFILE"
}

# Helper function: display progress bar
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$(( current * 100 / total ))
    local completed=$(( current * width / total ))
    local remaining=$(( width - completed ))

    # Print progress bar
    printf "\rProgress: ["
    printf "%*s" $completed | tr ' ' '#'
    printf "%*s" $remaining | tr ' ' '-'
    printf "] %d%% (%d/%d)" $percentage $current $total
}

###############################################
# Start
###############################################
mkdir -p "$LOCAL_LOG_DIR" # Ensure log directory exists

log "===== Web Deployment START at $(date) ====="

# Initialize manifest file with headers if it doesn't exist
if [ ! -f "$MANIFESTFILE" ]; then
    echo "timestamp,action,item,type,previous_path" > "$MANIFESTFILE"
fi

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
# 2. Show which items will be created vs overwritten
###############################################
log "Checking for existing items on the front-end server..."

# Collect filenames in local HTML directory
LOCAL_ITEMS=($(ls -1 "$LOCAL_HTML_DIR"))
OVERWRITE_ITEMS=()
CREATE_ITEMS=()

# Check each item and categorize as create or overwrite
for ITEM in "${LOCAL_ITEMS[@]}"; do
    if ssh "$FRONTEND_USER@$FRONTEND_HOST" "[ -e '$REMOTE_HTML_DIR/$ITEM' ]"; then
        OVERWRITE_ITEMS+=("$ITEM")
    else
        CREATE_ITEMS+=("$ITEM")
    fi
done

log "Items found locally: ${#LOCAL_ITEMS[@]}"
log "Items that will be overwritten on server: ${#OVERWRITE_ITEMS[@]}"
if [ ${#OVERWRITE_ITEMS[@]} -gt 0 ]; then
    log "  Files to be overwritten:"
    for item in "${OVERWRITE_ITEMS[@]}"; do
        log "    - $item"
    done
else
    log "  No files will be overwritten."
fi

log "Items that will be created on server: ${#CREATE_ITEMS[@]}"
if [ ${#CREATE_ITEMS[@]} -gt 0 ]; then
    log "  Files to be created:"
    for item in "${CREATE_ITEMS[@]}"; do
        log "    - $item"
    done
else
    log "  No new files will be created."
fi

echo
read -p "Proceed with deployment? (yes/no): " CONFIRM

CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]') # normalize to lowercase
[[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]] && log "Aborted by user." && exit 0 # Exit if not confirmed

###############################################
# 3. Deploy items — rename remote file if exists
###############################################
log "Deploying files..."
TOTAL_ITEMS=${#LOCAL_ITEMS[@]}
CURRENT_ITEM=0

for ITEM in "${LOCAL_ITEMS[@]}"; do
    ((CURRENT_ITEM++))
    show_progress $CURRENT_ITEM $TOTAL_ITEMS

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
    # Include timestamp in manifest entry with cleaner formatting
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$TIMESTAMP,$ACTION,$ITEM,$TYPE,$PREV_PATH" >> "$MANIFESTFILE" # Log to manifest

    # If exists, rename old file
    ssh "$FRONTEND_USER@$FRONTEND_HOST" \
    "if [ -e '$REMOTE_HTML_DIR/$ITEM' ]; then mv '$REMOTE_HTML_DIR/$ITEM' '$REMOTE_HTML_DIR/$ITEM.old'; fi" \
    2>&1 | tee -a "$LOGFILE"

    # Copy new file
    scp "$LOCAL_HTML_DIR/$ITEM" "$FRONTEND_USER@$FRONTEND_HOST:$REMOTE_HTML_DIR/" \
    2>&1 | tee -a "$LOGFILE"

    # Set permissions to 755
    ssh "$FRONTEND_USER@$FRONTEND_HOST" \
    "chmod 755 '$REMOTE_HTML_DIR/$ITEM'" \
    2>&1 | tee -a "$LOGFILE"
done

# Clear progress bar and add completion message
printf "\n"
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
