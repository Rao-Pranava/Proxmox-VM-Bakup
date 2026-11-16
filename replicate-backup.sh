#!/bin/bash

# ============================================================
# source -> destination Backup Script
# Versioned deletion protection + ntfy notifications
# ============================================================

set -u

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

SOURCE="${SOURCE:-/srv/backup-source}"
DEST="${DEST:-/srv/backup-destination}"

HISTORY_DIR="${DEST}/.backup-history"
LOG_DIR="/var/log/replicate-backup"
LOG_FILE="${LOG_DIR}/backup.log"

NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_ENABLED="${NTFY_ENABLED:-0}"

RETENTION_DAYS=7

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

send_ntfy() {
    local TITLE="$1"
    local MESSAGE="$2"
    local PRIORITY="${3:-default}"

    [[ "$NTFY_ENABLED" == 1 && -n "$NTFY_URL" && -n "$NTFY_TOPIC" ]] || return 0
    curl -fsS \
        -X POST \
        -H "Title: ${TITLE}" \
        -H "Priority: ${PRIORITY}" \
        -H "Tags: floppy_disk" \
        --data-raw "${MESSAGE}" \
        "${NTFY_URL}/${NTFY_TOPIC}" \
        >/dev/null 2>&1 || true
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ------------------------------------------------------------
# Preparation
# ------------------------------------------------------------

mkdir -p "$LOG_DIR"

START_TIME=$(date +%s)
DATE=$(date '+%Y-%m-%d')

# The deletion/backup directory for today's run
TODAY_HISTORY="${HISTORY_DIR}/${DATE}"

log "============================================================"
log "Starting source -> destination backup"
log "Source:      ${SOURCE}"
log "Destination: ${DEST}"
log "History:     ${TODAY_HISTORY}"

# ------------------------------------------------------------
# Safety checks
# ------------------------------------------------------------

if ! command -v rsync >/dev/null 2>&1; then
    log "ERROR: rsync is not installed."
    send_ntfy \
        "❌ Backup FAILED" \
        "source-to-destination backup failed: rsync is not installed." \
        "urgent"
    exit 1
fi

# Make absolutely sure the source drive is mounted.
if ! mountpoint -q "$SOURCE"; then
    log "ERROR: Source filesystem is not mounted. Backup ABORTED."
    send_ntfy \
        "🚨 Backup ABORTED" \
        "Source filesystem is not mounted. Backup was NOT performed." \
        "urgent"
    exit 1
fi

# Make absolutely sure the destination drive is mounted.
if ! mountpoint -q "$DEST"; then
    log "ERROR: Destination filesystem is not mounted. Backup ABORTED."
    send_ntfy \
        "🚨 Backup ABORTED" \
        "Destination filesystem is not mounted. Backup was NOT performed." \
        "urgent"
    exit 1
fi

# ------------------------------------------------------------
# Prevent concurrent backup executions
# ------------------------------------------------------------

LOCK_FILE="/run/replicate-backup.lock"

exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    log "ERROR: Another backup process is already running."
    send_ntfy \
        "⚠️ Backup SKIPPED" \
        "Another source-to-destination backup process is already running." \
        "high"
    exit 1
fi

# ------------------------------------------------------------
# Create today's history directory
# ------------------------------------------------------------

mkdir -p "$TODAY_HISTORY"

# ------------------------------------------------------------
# Perform backup
# ------------------------------------------------------------

log "Running rsync..."

RSYNC_OUTPUT=$(mktemp)

if rsync \
    -avh \
    --delete \
    --backup \
    --backup-dir="$TODAY_HISTORY" \
    --stats \
    "$SOURCE" \
    "$DEST" \
    >"$RSYNC_OUTPUT" 2>&1
then
    RSYNC_STATUS=0
else
    RSYNC_STATUS=$?
fi

cat "$RSYNC_OUTPUT" >> "$LOG_FILE"

# ------------------------------------------------------------
# Process result
# ------------------------------------------------------------

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ "$RSYNC_STATUS" -ne 0 ]; then

    log "ERROR: rsync failed with exit code ${RSYNC_STATUS}."
    log "Backup FAILED."

    send_ntfy \
        "❌ Backup FAILED" \
        "source → destination backup failed.
Date: ${DATE}
Exit code: ${RSYNC_STATUS}
Duration: ${DURATION}s
Check: ${LOG_FILE}" \
        "urgent"

    rm -f "$RSYNC_OUTPUT"
    exit "$RSYNC_STATUS"
fi

# ------------------------------------------------------------
# Remove empty history directory
# ------------------------------------------------------------

if [ -d "$TODAY_HISTORY" ] && [ -z "$(find "$TODAY_HISTORY" -mindepth 1 -print -quit)" ]; then
    rmdir "$TODAY_HISTORY"
    log "No deleted/overwritten files were placed into today's history."
fi

# ------------------------------------------------------------
# Delete history older than retention period
# ------------------------------------------------------------

log "Cleaning history older than ${RETENTION_DAYS} days..."

find "$HISTORY_DIR" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -mtime +"$RETENTION_DAYS" \
    -print \
    -exec rm -rf -- {} \; \
    >> "$LOG_FILE" 2>&1

# ------------------------------------------------------------
# Calculate summary
# ------------------------------------------------------------

DELETED_COUNT=0

if [ -d "$TODAY_HISTORY" ]; then
    DELETED_COUNT=$(find "$TODAY_HISTORY" -type f | wc -l)
fi

log "Backup completed successfully."
log "Duration: ${DURATION} seconds"
log "Files preserved in today's history: ${DELETED_COUNT}"

# ------------------------------------------------------------
# ntfy notification
# ------------------------------------------------------------

send_ntfy \
    "✅ Backup Successful" \
    "source → destination backup completed successfully.
Date: ${DATE}
Duration: ${DURATION}s
Files preserved: ${DELETED_COUNT}
Retention: ${RETENTION_DAYS} days" \
    "default"

rm -f "$RSYNC_OUTPUT"

log "Backup job finished."
log "============================================================"

exit 0
