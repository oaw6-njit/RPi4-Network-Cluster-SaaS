#!/usr/bin/env bash

###############################################
# revert_web.sh - Revert deployed HTML files on front-end server
# Uses manifest_web_YYYYMMDD.csv to determine what to revert.
# - For created items: delete current item.
# - For updated items: delete current item, restore <item>.old.1, then repack backups
#   so .old.2 -> .old.1, .old.3 -> .old.2, ..., keeping up to 5 versions.
# Logs all actions locally and ships the log to the log server.
###############################################

set -euo pipefail

# Locate script dir and load the same config file used by deploy
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deploy_web.ini"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG_FILE"

# Resolve LOCAL_* directories relative to the script dir if they are not absolute
case "$LOCAL_HTML_DIR" in (/*) ;; (*) LOCAL_HTML_DIR="$SCRIPT_DIR/$LOCAL_HTML_DIR" ;; esac
case "$LOCAL_LOG_DIR" in (/*) ;; (*) LOCAL_LOG_DIR="$SCRIPT_DIR/$LOCAL_LOG_DIR" ;; esac

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
  echo "$1" | tee -a "$LOGFILE"
}

# Start
mkdir -p "$LOCAL_LOG_DIR"
log "===== Web Revert START for date $MANIFEST_DATE at $(date) ====="

# Check SSH connectivity
log "Testing SSH connection to $FRONTEND_HOST..."
if ! ssh -o BatchMode=yes "$FRONTEND_USER@$FRONTEND_HOST" "echo connection OK" &>/dev/null; then
  log "ERROR: Could not connect to $FRONTEND_HOST. Aborting."
  exit 1
fi
log "SSH connection successful."

# Check manifest availability
if [ ! -f "$MANIFESTFILE" ]; then
  log "ERROR: Manifest not found: $MANIFESTFILE"
  exit 1
fi

# Read manifest and capture the most recent entry per item (last occurrence wins)
# Manifest columns: action,item,type,previous_path,rotated_to,rotation_performed
declare -A ACT_MAP TYPE_MAP PREV_MAP ROT_MAP ROTFLAG_MAP

# Use awk to process last occurrence per item
# We preserve order in ITEMS array for display (by appearance), but last wins.
ITEMS=()
while IFS= read -r line; do
  # skip empty/comment lines
  [[ -z "${line//,/}" ]] && continue
  IFS="," read -r action item type prev rotated rotflag <<<"$line"
  # basic field validation
  if [[ -z "${item:-}" ]]; then
    continue
  fi
  ACT_MAP["$item"]="$action"
  TYPE_MAP["$item"]="$type"
  PREV_MAP["$item"]="$prev"
  ROT_MAP["$item"]="$rotated"
  ROTFLAG_MAP["$item"]="$rotflag"
  # maintain seen order
  if ! printf '%s
' "${ITEMS[@]}" | grep -qx "$item"; then
    ITEMS+=("$item")
  fi

done < <(cat "$MANIFESTFILE")

# Compute counts
REVERTABLE=0
for item in "${ITEMS[@]}"; do
  case "${ACT_MAP[$item]}" in
    created|updated) REVERTABLE=$((REVERTABLE+1));;
  esac
done

log "Items in manifest (unique): ${#ITEMS[@]}"
log "Items that will be reverted based on manifest: $REVERTABLE"

if [ "$REVERTABLE" -eq 0 ]; then
  log "Nothing to revert per manifest. Exiting."
  log "===== Web Revert END at $(date) ====="
  exit 0
fi

# Show summary and confirm
for item in "${ITEMS[@]}"; do
  printf "- %s: %s (%s)\n" "$item" "${ACT_MAP[$item]}" "${TYPE_MAP[$item]}" | tee -a "$LOGFILE"
done

echo
read -r -p "Proceed with revert of $REVERTABLE item(s) from manifest $MANIFEST_DATE? (yes/no): " CONFIRM
CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
[[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]] && log "Aborted by user." && exit 0

log "Reverting files..."

for item in "${ITEMS[@]}"; do
  action="${ACT_MAP[$item]}"
  type="${TYPE_MAP[$item]}"
  prev="${PREV_MAP[$item]}"   # expected to be /var/www/html/<item>.old.1 for updated, empty for created
  log "Processing $item (action=$action, type=$type)"

  if [[ "$action" == "created" ]]; then
    # Delete current item created during deploy
    ssh "$FRONTEND_USER@$FRONTEND_HOST" \
      "rm -rf '$REMOTE_HTML_DIR/$item' || true" 2>&1 | tee -a "$LOGFILE"
    log "Deleted created item: $item"
    continue
  fi

  if [[ "$action" == "updated" ]]; then
    # Restore from .old.1 and repack backups (shift down .old.2 -> .old.1 ... .old.5 -> .old.4)
    ssh "$FRONTEND_USER@$FRONTEND_HOST" \
      "set -e; \
       # remove current item
       rm -rf '$REMOTE_HTML_DIR/$item' 2>/dev/null || true; \
       # ensure .old.1 exists before restore
       if [ ! -e '$REMOTE_HTML_DIR/$item.old.1' ]; then \
         echo 'WARN: missing $item.old.1, skipping restore'; \
         exit 0; \
       fi; \
       # move .old.1 back to live
       mv '$REMOTE_HTML_DIR/$item.old.1' '$REMOTE_HTML_DIR/$item'; \
       # repack remaining backups downward to keep next-newest at .old.1
       for n in 2 3 4 5; do \
         if [ -e '$REMOTE_HTML_DIR/$item.old.'"$n" ]; then \
           m=$((n-1)); \
           mv '$REMOTE_HTML_DIR/$item.old.'"$n" '$REMOTE_HTML_DIR/$item.old.'"$m"; \
         fi; \
       done" 2>&1 | tee -a "$LOGFILE"
    log "Reverted updated item: $item"
    continue
  fi

  log "Skipping $item: unsupported action '${action}'"
done

log "Revert operations complete."

# Send log to log server only
log "Sending log file to log server ($LOGSERVER_HOST)..."
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
