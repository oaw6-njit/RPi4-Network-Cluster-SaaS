#!/bin/bash

###############################################
# revert_web.sh - Revert deployed HTML files on front-end server
# Uses manifest_web_YYYYMMDD.csv to determine what to revert.
# - For created items: delete current item.
# - For updated items: delete current item, restore <item>.v1
# Logs all actions locally and ships the log to the log server.
###############################################

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

# Determine manifest date (default today). Optional first arg can be YYYYMMDD.
MANIFEST_DATE="${1:-$(date +%Y%m%d)}"
if ! [[ "$MANIFEST_DATE" =~ ^[0-9]{8}$ ]]; then
  echo "ERROR: Invalid date format for manifest (expected YYYYMMDD): $MANIFEST_DATE" >&2
  exit 1
fi

LOGFILE="$LOCAL_LOG_DIR/revert_web_${MANIFEST_DATE}.log"
MANIFESTFILE="$LOCAL_LOG_DIR/manifest_web_${MANIFEST_DATE}.csv"

# Helper: log to terminal + file (append)
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
    # Restore from versioned backup (v1)
    log "  ✓ Restoring updated item: $item from $item.v1"
    ssh "$FRONTEND_USER@$FRONTEND_HOST" \
      "set -e; \
       # remove current item
       rm -rf '$REMOTE_HTML_DIR/$item' 2>/dev/null || true; \
       # ensure v1 exists before restore
       if [ ! -e '$REMOTE_HTML_DIR/$item.v1' ]; then \
         echo 'WARN: missing $item.v1, skipping restore'; \
         exit 0; \
       fi; \
       # move v1 back to live
       mv '$REMOTE_HTML_DIR/$item.v1' '$REMOTE_HTML_DIR/$item'; \
       # set permissions to 755 after restoring
       chmod 755 '$REMOTE_HTML_DIR/$item'" 2>&1 | tee -a "$LOGFILE"
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