#!/bin/bash

###############################################
# deploy_web.sh - Deploy HTML files to front-end server
# and log the deployment process.
# Uses version rotation system (v1, v2, v3) to maintain backups.
# This script assumes that the front-end server is accessible via SSH.
###############################################

# Parse command line arguments for logging options
LOG_LEVEL="normal"  # Default log level
for arg in "$@"; do
  case $arg in
    --quiet|-q)
      LOG_LEVEL="quiet"
      ;;
    --verbose|-v)
      LOG_LEVEL="verbose"
      ;;
    *)
      # Ignore other arguments
      ;;
  esac
done

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

# Version rotation settings
VERSION_LIMIT=3  # Maximum number of versions to keep

# Helper function: log to terminal + logfile based on log level
log() {
  case $LOG_LEVEL in
    "quiet")
      # Only log to file in quiet mode
      echo -- "$@" >> "$LOGFILE"
      ;;
    "normal")
      # Log to both terminal and file in normal mode, but greatly reduce verbosity
      case $1 in
        "  ✓ Completed processing "* | \
        *"Processing directory "* | \
        *"Processing file "* | \
        *"Copying "* | \
        *"Setting permissions "*)
          # For detailed processing messages, only log to file in normal mode
          echo -- "$@" >> "$LOGFILE"
          ;;
        *)
          # For other messages (important ones), log to both terminal and file
          echo -- "$@" | tee -a "$LOGFILE"
          ;;
      esac
      ;;
    "verbose")
      # In verbose mode, add timestamp to the output
      echo -- "[$(date '+%H:%M:%S')] $@" | tee -a "$LOGFILE"
      ;;
  esac
}

# Helper function: display progress bar (only shown if not in quiet mode)
show_progress() {
  case $LOG_LEVEL in
    "quiet")
      # Don't show progress in quiet mode
      return
      ;;
    *)
      # Show progress in normal and verbose modes
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
      ;;
  esac
}

###############################################
# Start
###############################################
mkdir -p "$LOCAL_LOG_DIR" # Ensure log directory exists

log ""
log "============================================="
log "===== Web Deployment START at $(date) ====="
log "============================================="

# Initialize manifest file with headers if it doesn't exist
if [ ! -f "$MANIFESTFILE" ]; then
    echo "timestamp,action,item,type,previous_path" > "$MANIFESTFILE"
fi

###############################################
# 1. Test SSH connection to front end server
###############################################
log ""
log "---------------------------------------------"
log "Testing SSH connection to $FRONTEND_HOST..."
log "---------------------------------------------"

if ! ssh -o BatchMode=yes "$FRONTEND_USER@$FRONTEND_HOST" "echo connection OK" &>/dev/null; then
    log "ERROR: Could not connect to $FRONTEND_HOST. Aborting."
    exit 1
fi

log "✓ SSH connection to $FRONTEND_HOST successful."

###############################################
# 2. Show which items will be created vs overwritten
###############################################
log ""
log "---------------------------------------------"
log "Scanning local HTML directory: $LOCAL_HTML_DIR"
log "---------------------------------------------"

# Collect filenames in local HTML directory
LOCAL_ITEMS=($(ls -1 "$LOCAL_HTML_DIR"))
log "Found ${#LOCAL_ITEMS[@]} items in local HTML directory: ${LOCAL_ITEMS[*]}"

OVERWRITE_ITEMS=()
CREATE_ITEMS=()

# Check each item and categorize as create or overwrite
log ""
log "Checking existing files on front-end server at $REMOTE_HTML_DIR..."
for ITEM in "${LOCAL_ITEMS[@]}"; do
    if ssh "$FRONTEND_USER@$FRONTEND_HOST" "[ -e '$REMOTE_HTML_DIR/$ITEM' ]"; then
        OVERWRITE_ITEMS+=("$ITEM")
        log "  ✓ $ITEM found on server (will be updated)"
    else
        CREATE_ITEMS+=("$ITEM")
        log "  + $ITEM not found on server (will be created)"
    fi
done

log ""
log "Deployment analysis complete:"
log "  Total items to process: ${#LOCAL_ITEMS[@]}"
log "  Items to be overwritten: ${#OVERWRITE_ITEMS[@]}"
log "  Items to be created: ${#CREATE_ITEMS[@]}"

if [ ${#OVERWRITE_ITEMS[@]} -gt 0 ]; then
    log ""
    log "  Files that will be overwritten:"
    for item in "${OVERWRITE_ITEMS[@]}"; do
        log "    - $item"
    done
elif [ ${#CREATE_ITEMS[@]} -gt 0 ]; then
    log "  No existing files will be overwritten."
fi

if [ ${#CREATE_ITEMS[@]} -gt 0 ]; then
    log ""
    log "  New files that will be created:"
    for item in "${CREATE_ITEMS[@]}"; do
        log "    - $item"
    done
elif [ ${#OVERWRITE_ITEMS[@]} -gt 0 ]; then
    log "  No new files will be created."
fi

echo
echo ""
read -p "Proceed with deployment? (yes/no): " CONFIRM

CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]') # normalize to lowercase
[[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]] && log "Aborted by user." && exit 0 # Exit if not confirmed

###############################################
# 3. Deploy items — rename remote file if exists
###############################################
log "Starting deployment of ${#LOCAL_ITEMS[@]} items..."
TOTAL_ITEMS=${#LOCAL_ITEMS[@]}
CURRENT_ITEM=0

for ITEM in "${LOCAL_ITEMS[@]}"; do
    ((CURRENT_ITEM++))
    show_progress $CURRENT_ITEM $TOTAL_ITEMS

    # Determine item type and whether it already exists on remote for manifest
    ITEM_PATH="$LOCAL_HTML_DIR/$ITEM"
    if [ -d "$ITEM_PATH" ]; then
        TYPE="dir"
        log "Processing directory $ITEM (${CURRENT_ITEM}/${TOTAL_ITEMS}) - type: directory"
    else
        TYPE="file"
        log "Processing file $ITEM (${CURRENT_ITEM}/${TOTAL_ITEMS}) - type: file"
    fi

    if ssh "$FRONTEND_USER@$FRONTEND_HOST" "[ -e '$REMOTE_HTML_DIR/$ITEM' ]"; then
        ACTION="updated"
        # For manifest purposes, we'll record the file that will be backed up (current file)
        PREV_PATH="$REMOTE_HTML_DIR/$ITEM"
        log "  $ITEM already exists on server, will be updated"

        # Record the manifest entry before rotation, then update PREV_PATH after rotation
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$TIMESTAMP,$ACTION,$ITEM,$TYPE,$PREV_PATH" >> "$MANIFESTFILE" # Log to manifest

        # Implement version rotation system
        # Rotate existing versions (v3 becomes v4, v2 becomes v3, v1 becomes v2)
        for ((i = VERSION_LIMIT - 1; i >= 1; i--)); do
            j=$((i + 1))
            ssh "$FRONTEND_USER@$FRONTEND_HOST" \
            "if [ -e '$REMOTE_HTML_DIR/$ITEM.v$i' ]; then mv '$REMOTE_HTML_DIR/$ITEM.v$i' '$REMOTE_HTML_DIR/$ITEM.v$j'; fi" \
            2>&1 | tee -a "$LOGFILE"
        done

        # Move current file to v1
        ssh "$FRONTEND_USER@$FRONTEND_HOST" \
        "if [ -e '$REMOTE_HTML_DIR/$ITEM' ]; then mv '$REMOTE_HTML_DIR/$ITEM' '$REMOTE_HTML_DIR/$ITEM.v1'; fi" \
        2>&1 | tee -a "$LOGFILE"

        log "  Renamed existing $ITEM to $ITEM.v1 and rotated older versions"

        # Update PREV_PATH to reflect the new backup format
        PREV_PATH="$REMOTE_HTML_DIR/$ITEM.v1"

    else
        ACTION="created"
        PREV_PATH=""
        log "  $ITEM is new, will be created"

        # Record the manifest entry for new files
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$TIMESTAMP,$ACTION,$ITEM,$TYPE,$PREV_PATH" >> "$MANIFESTFILE" # Log to manifest
    fi

    # Copy new file
    log "  Copying $ITEM to server..."
    scp "$LOCAL_HTML_DIR/$ITEM" "$FRONTEND_USER@$FRONTEND_HOST:$REMOTE_HTML_DIR/" \
    2>&1 | tee -a "$LOGFILE"

    # Set permissions to 755
    log "  Setting permissions to 755 for $ITEM"
    ssh "$FRONTEND_USER@$FRONTEND_HOST" \
    "chmod 755 '$REMOTE_HTML_DIR/$ITEM'" \
    2>&1 | tee -a "$LOGFILE"

    log "  ✓ Completed processing $ITEM"
done

# Clear progress bar and add completion message
printf "\n"
log "Deployment completed successfully. Processed $TOTAL_ITEMS items."

###############################################
# 4. Send log file to log server
###############################################

log ""
log "---------------------------------------------"
log "Sending files to log server ($LOGSERVER_HOST)..."
log "---------------------------------------------"

log "Ensuring remote log directory exists..."
# Ensure remote log directory on log server (best-effort)
if ssh "$LOGSERVER_USER@$LOGSERVER_HOST" "mkdir -p '$REMOTE_LOG_DIR'"; then
    log "✓ Ensured remote log directory $REMOTE_LOG_DIR on log server."
else
    log "WARNING: Could not ensure remote log directory on log server!"
fi

log "Transferring log file..."
if scp "$LOGFILE" "$LOGSERVER_USER@$LOGSERVER_HOST:$REMOTE_LOG_DIR/"; then
    log "✓ Log file transferred to log server successfully."
else
    log "WARNING: Failed to transfer log file to log server!"
fi

# Also send the manifest to the log server
log "Transferring manifest file..."
if scp "$MANIFESTFILE" "$LOGSERVER_USER@$LOGSERVER_HOST:$REMOTE_LOG_DIR/"; then
    log "✓ Manifest transferred to log server successfully."
else
    log "WARNING: Failed to transfer manifest to log server!"
fi

log ""
log "============================================="
log "===== Web Deployment END at $(date) ====="
log "============================================="