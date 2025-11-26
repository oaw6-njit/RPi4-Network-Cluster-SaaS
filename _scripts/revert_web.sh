#!/bin/bash

###############################################
# revert_web.sh - Revert deployed HTML files on front-end server
# Uses manifest_web_YYYYMMDD.csv to determine what to revert.
# - For created items: delete current item.
# - For updated items: delete current item, restore <item>.v1
# Logs all actions locally and ships the log to the log server.
###############################################

# Parse command line arguments for logging options and date
LOG_LEVEL="normal"  # Default log level
MANIFEST_DATE="$(date +%Y%m%d)"  # Default to today

# Process arguments
for arg in "$@"; do
  case $arg in
    --quiet|-q)
      LOG_LEVEL="quiet"
      ;;
    --verbose|-v)
      LOG_LEVEL="verbose"
      ;;
    *)
      # If it's not a logging option, treat it as the date
      if [[ $arg =~ ^[0-9]{8}$ ]]; then
        MANIFEST_DATE="$arg"
      fi
      ;;
  esac
done

# Validate manifest date format
if ! [[ "$MANIFEST_DATE" =~ ^[0-9]{8}$ ]]; then
  echo "ERROR: Invalid date format for manifest (expected YYYYMMDD): $MANIFEST_DATE" >&2
  exit 1
fi

# User-configurable variables (matching deploy_web.sh)
FRONTEND_HOST="u1-phoenix"
FRONTEND_USER="phoenix"

LOGSERVER_HOST="u4-naruhodo"
LOGSERVER_USER="naruhodo"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL_HTML_DIR="$SCRIPT_DIR/../html"
LOCAL_LOG_DIR="$SCRIPT_DIR/../_logs"

REMOTE_HTML_DIR="/var/www/html"
REMOTE_LOG_DIR="/home/naruhodo/Desktop/_logs"

LOGFILE="$LOCAL_LOG_DIR/revert_web_${MANIFEST_DATE}.log"
MANIFESTFILE="$LOCAL_LOG_DIR/manifest_web_${MANIFEST_DATE}.csv"

VERSION_LIMIT=3  # Maximum number of versions to keep

# Helper: log to terminal + file (append) based on log level
log() {
  case $LOG_LEVEL in
    "quiet")
      # Only log to file in quiet mode
      echo -- "$@" >> "$LOGFILE"
      ;;
    "normal")
      # Log to both terminal and file in normal mode, but greatly reduce verbosity
      case $1 in
        "  ✓ Successfully reverted updated item: "* | \
        "  ✓ Successfully deleted created item: "* | \
        *"Processing "* | \
        *"Deleting newly created item"* | \
        *"Restoring updated item"*)
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

# Start
mkdir -p "$LOCAL_LOG_DIR"
log ""
log "============================================="
log "===== Web Revert START for date $MANIFEST_DATE at $(date) ====="
log "============================================="

# Check SSH connectivity
log ""
log "---------------------------------------------"
log "Testing SSH connection to $FRONTEND_HOST..."
log "---------------------------------------------"
if ! ssh -o BatchMode=yes "$FRONTEND_USER@$FRONTEND_HOST" "echo connection OK" &>/dev/null; then
  log "ERROR: Could not connect to $FRONTEND_HOST. Aborting."
  exit 1
fi
log "✓ SSH connection to $FRONTEND_HOST successful."

# Check manifest availability
log ""
log "---------------------------------------------"
log "Checking manifest availability..."
log "---------------------------------------------"
if [ ! -f "$MANIFESTFILE" ]; then
  log "ERROR: Manifest not found: $MANIFESTFILE"
  exit 1
fi

log "✓ Manifest file found: $MANIFESTFILE"

# Read manifest and capture the most recent entry per item (last occurrence wins)
# Manifest columns: timestamp,action,item,type,previous_path
declare -A ACT_MAP TYPE_MAP PREV_MAP

log ""
log "Reading manifest entries..."

# Use awk to process last occurrence per item
# We preserve order in ITEMS array for display (by appearance), but last wins.
ITEMS=()
while IFS= read -r line; do
  # skip empty/comment lines and header
  [[ -z "${line//,/}" ]] && continue
  [[ "$line" == "timestamp,action,item,type,previous_path" ]] && continue
  IFS="," read -r timestamp action item type prev <<<"$line"
  # basic field validation
  if [[ -z "${item:-}" ]]; then
    continue
  fi
  ACT_MAP["$item"]="$action"
  TYPE_MAP["$item"]="$type"
  PREV_MAP["$item"]="$prev"
  # maintain seen order
  seen=0
  for existing_item in "${ITEMS[@]}"; do
    if [[ "$existing_item" == "$item" ]]; then
      seen=1
      break
    fi
  done
  if [[ $seen -eq 0 ]]; then
    ITEMS+=("$item")
  fi

done < <(cat "$MANIFESTFILE")

log "✓ Manifest read complete. Found ${#ITEMS[@]} unique items."

# Compute counts
REVERTABLE=0
for item in "${ITEMS[@]}"; do
  case "${ACT_MAP[$item]}" in
    created|updated) REVERTABLE=$((REVERTABLE+1));;
  esac
done

log ""
log "Revert analysis:"
log "  Total unique items in manifest: ${#ITEMS[@]}"
log "  Items that can be reverted: $REVERTABLE"
log "  Items that cannot be reverted (deleted, etc.): $((${#ITEMS[@]} - $REVERTABLE))"

if [ "$REVERTABLE" -eq 0 ]; then
  log "Nothing to revert per manifest. Exiting."
  log ""
  log "============================================="
  log "===== Web Revert END at $(date) ====="
  log "============================================="
  exit 0
fi

log ""
log "Items to be processed:"
for item in "${ITEMS[@]}"; do
  printf -- "  - %s: %s (%s)\n" "$item" "${ACT_MAP[$item]}" "${TYPE_MAP[$item]}" | tee -a "$LOGFILE"
done

echo ""
read -r -p "Proceed with revert of $REVERTABLE item(s) from manifest $MANIFEST_DATE? (yes/no): " CONFIRM
CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
[[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]] && log "Aborted by user." && exit 0

log ""
log "============================================="
log "Starting revert of ${#ITEMS[@]} items..."
log "============================================="
TOTAL_ITEMS=${#ITEMS[@]}
CURRENT_ITEM=0

for item in "${ITEMS[@]}"; do
  ((CURRENT_ITEM++))
  show_progress $CURRENT_ITEM $TOTAL_ITEMS

  log ""
  action="${ACT_MAP[$item]}"
  type="${TYPE_MAP[$item]}"
  prev="${PREV_MAP[$item]}"   # expected to be /var/www/html/<item> (the original file before update), now revert to v1
  log "Processing $item (${CURRENT_ITEM}/${TOTAL_ITEMS}) - action: $action, type: $type"

  if [[ "$action" == "created" ]]; then
    # Delete current item created during deploy
    log "  ✓ Deleting newly created item: $item"
    ssh "$FRONTEND_USER@$FRONTEND_HOST" \
      "rm -rf '$REMOTE_HTML_DIR/$item' || true" 2>&1 | tee -a "$LOGFILE"
    log "  ✓ Successfully deleted created item: $item"
    continue
  fi

  if [[ "$action" == "updated" ]]; then
    # Restore from versioned backup with proper rotation: live->tmp, v1->live, v2->v1, etc.
    log "  ✓ Restoring updated item: $item from $item.v1"

    # Safe revert process:
    # 1. Rename live file to .tmp (preserve current version as backup)
    # 2. Rename v1 to live (this is the version we're reverting to)
    # 3. Rename v2 to v1, v3 to v2, etc. (shift all remaining backups down)

    remote_cmd="set -e; "

    # First, save the current live file to a temporary location (for safety)
    remote_cmd="${remote_cmd}if [ -e '$REMOTE_HTML_DIR/$item' ]; then mv '$REMOTE_HTML_DIR/$item' '$REMOTE_HTML_DIR/$item.tmp'; fi; "

    # Check that v1 backup exists before proceeding with the revert
    remote_cmd="${remote_cmd}if [ ! -e '$REMOTE_HTML_DIR/$item.v1' ]; then echo 'WARN: missing $item.v1 backup, skipping restore'; exit 0; fi; "

    # Rename v1 to live (perform the actual revert)
    remote_cmd="${remote_cmd}mv '$REMOTE_HTML_DIR/$item.v1' '$REMOTE_HTML_DIR/$item'; "

    # Now shift remaining versions down: v2->v1, v3->v2, etc.
    # Process from lowest to highest to avoid overwriting issues
    for ((i = 1; i <= VERSION_LIMIT - 1; i++)); do
        j=$((i + 1))
        remote_cmd="${remote_cmd}if [ -e '$REMOTE_HTML_DIR/$item.v$j' ]; then mv '$REMOTE_HTML_DIR/$item.v$j' '$REMOTE_HTML_DIR/$item.v$i'; fi; "
    done

    # Set permissions on the new live file
    remote_cmd="${remote_cmd}chmod 755 '$REMOTE_HTML_DIR/$item';"

    ssh "$FRONTEND_USER@$FRONTEND_HOST" "$remote_cmd" 2>&1 | tee -a "$LOGFILE"

    # Now delete the temporary file (the previous live version) after the revert is complete
    cleanup_cmd="rm -f '$REMOTE_HTML_DIR/$item.tmp';"
    ssh "$FRONTEND_USER@$FRONTEND_HOST" "$cleanup_cmd" 2>&1 | tee -a "$LOGFILE"

    log "  ✓ Successfully reverted updated item: $item"
    continue
  fi

  log "  Skipping $item: unsupported action '${action}'"
done

# Clear progress bar and add completion message
printf "\n"
log ""
log "============================================="
log "Revert operations completed successfully. Processed $TOTAL_ITEMS items."
log "============================================="

# Send log to log server
log ""
log "---------------------------------------------"
log "Sending files to log server ($LOGSERVER_HOST)..."
log "---------------------------------------------"

log "Ensuring remote log directory exists..."
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

# Also send the manifest to the log server (to maintain consistency with deploy)
log "Transferring manifest file..."
if scp "$MANIFESTFILE" "$LOGSERVER_USER@$LOGSERVER_HOST:$REMOTE_LOG_DIR/"; then
  log "✓ Manifest transferred to log server successfully."
else
  log "WARNING: Failed to transfer manifest to log server!"
fi

log ""
log "============================================="
log "===== Web Revert END at $(date) ====="
log "============================================="
echo ""