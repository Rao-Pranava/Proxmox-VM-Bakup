#!/usr/bin/env bash
# Run as root on the coordinator Proxmox host. Wait for configured nodes, run
# their export jobs, verify archives, copy them to shared storage, then run
# the configured replication script.
set -Eeuo pipefail
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

CONFIG_FILE=${CONFIG_FILE:-/etc/proxmox-backup-nodes.conf}
STORAGE_TARGET=${STORAGE_TARGET:-root@backup-storage}
NODE_ROOT=${NODE_ROOT:-/srv/proxmox-backups}
BACKUP_MOUNT=${BACKUP_MOUNT:-/srv}
REPLICATION_SCRIPT=${REPLICATION_SCRIPT:-/usr/local/sbin/replicate-backup.sh}
COLLECTED_RETENTION=${COLLECTED_RETENTION:-8}
POLL_SECONDS=${POLL_SECONDS:-60}
LOG_ROOT=${LOG_ROOT:-/var/log/proxmox-backup-collection}
NTFY_URL=${NTFY_URL:-}
NTFY_TOPIC=${NTFY_TOPIC:-}
NTFY_ENABLED=${NTFY_ENABLED:-0}

[[ -r "$CONFIG_FILE" ]] || { echo "Missing config: $CONFIG_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG_FILE"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
notify() {
    [[ "$NTFY_ENABLED" == 1 ]] || return 0
    [[ -n "$NTFY_URL" && -n "$NTFY_TOPIC" ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    curl --connect-timeout 3 --max-time 10 -fsS -X POST \
        -H "Title: $1" -H "Priority: ${3:-default}" -H 'Tags: floppy_disk' \
        --data-raw "$2" "${NTFY_URL%/}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
}

FAILURE_NOTIFIED=0
CURRENT_PARTIAL_PATH=''
report_unexpected_failure() {
    local rc=$?
    if (( rc != 0 )) && [[ -n "$CURRENT_PARTIAL_PATH" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=5 "$STORAGE_TARGET" "rm -f '$CURRENT_PARTIAL_PATH'" >/dev/null 2>&1 || true
    fi
    if (( rc != 0 && FAILURE_NOTIFIED == 0 )); then
        notify 'Weekly VM backup failed' "Coordinator failed unexpectedly (exit $rc). Check /var/log/proxmox-backup-collection on coordinator." urgent
    fi
    return "$rc"
}
trap report_unexpected_failure EXIT

if [[ $EUID -ne 0 ]]; then echo 'Must run as root on coordinator.' >&2; exit 1; fi
for cmd in ssh scp sha256sum flock; do command -v "$cmd" >/dev/null 2>&1 || { echo "Required command missing: $cmd" >&2; exit 1; }; done
mkdir -p "$LOG_ROOT"
exec 9>/run/lock/collect-proxmox-backups.lock
flock -n 9 || { log 'A collection run is already active.'; exit 1; }

# NODES entries are NODE_NAME|SSH_TARGET|REMOTE_SCRIPT|DESTINATION_SUBFOLDER.
if ((${#NODES[@]} == 0)); then echo 'No nodes are configured in NODES.' >&2; exit 1; fi
RUN_ID=$(date '+%Y-%m-%d_%H-%M-%S')
RUN_DIR="$LOG_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"

# NODE_ROOT is the destination root on the configured storage host.
declare -A TARGETS SCRIPTS FOLDERS PIDS LOGS STARTED
for entry in "${NODES[@]}"; do
    IFS='|' read -r node target remote_script folder <<< "$entry"
    [[ -n "$node" && -n "$target" && -n "$remote_script" && -n "$folder" && "$folder" != */* && "$folder" != . && "$folder" != .. ]] || { echo "Invalid node entry; expected NODE|TARGET|SCRIPT|FOLDER: $entry" >&2; exit 1; }
    TARGETS["$node"]=$target; SCRIPTS["$node"]=$remote_script; FOLDERS["$node"]=$folder; STARTED["$node"]=0
    LOGS["$node"]="$RUN_DIR/$node.log"
done

notify 'Weekly VM backup started' 'coordinator is waiting for all configured Proxmox nodes, then will collect and verify their backups.' default
remaining=${#NODES[@]}
last_wait_notice=$(date +%s)
while (( remaining > 0 )); do
    for entry in "${NODES[@]}"; do
        IFS='|' read -r node target remote_script <<< "$entry"
        [[ "${STARTED[$node]}" == 0 ]] || continue
        if [[ "$target" == LOCAL ]] || ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$target" 'true' >/dev/null 2>&1; then
            log "$node is reachable; starting its backup."
            if [[ "$target" == LOCAL ]]; then
                bash "$remote_script" >"${LOGS[$node]}" 2>&1 &
            else
                ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=120 "$target" "bash '$remote_script'" >"${LOGS[$node]}" 2>&1 &
            fi
            PIDS["$node"]=$!
            STARTED["$node"]=1
            ((remaining-=1))
        fi
    done
    if (( remaining > 0 )); then
        now=$(date +%s)
        if (( now - last_wait_notice >= 1800 )); then
            log "Still waiting for $remaining Proxmox node(s) to become reachable."
            notify 'Waiting for Proxmox node' "$remaining configured node(s) are not reachable yet. Collection will keep waiting." high
            last_wait_notice=$now
        fi
        sleep "$POLL_SECONDS"
    fi
done

FAILED=0
for entry in "${NODES[@]}"; do
    IFS='|' read -r node target remote_script <<< "$entry"
    if wait "${PIDS[$node]}"; then
        archive=$(sed -n 's/^ARCHIVE_PATH=//p' "${LOGS[$node]}" | tail -n 1)
        [[ -n "$archive" ]] || { log "ERROR: $node finished without reporting an archive path. See ${LOGS[$node]}"; FAILED=1; continue; }
        filename=${archive##*/}
        remote_hash=''
        if [[ "$target" == LOCAL ]]; then
            [[ -f "${archive}.sha256" ]] || { log "ERROR: Missing local checksum for $node."; FAILED=1; continue; }
            remote_hash=$(awk 'NR==1 {print $1}' "${archive}.sha256")
        else
            remote_hash=$(ssh -o BatchMode=yes "$target" "cat '${archive}.sha256'" | awk 'NR==1 {print $1}')
        fi
        [[ "$remote_hash" =~ ^[[:xdigit:]]{64}$ ]] || { log "ERROR: Invalid checksum from $node."; FAILED=1; continue; }
        local_hash=''
        if [[ "$target" == LOCAL ]]; then
            local_hash=$(sha256sum "$archive" | awk '{print $1}')
        else
            local_hash=$(ssh -o BatchMode=yes "$target" "sha256sum '${archive}'" | awk 'NR==1 {print $1}')
        fi
        [[ "$local_hash" == "$remote_hash" ]] || { log "ERROR: Source archive checksum mismatch on $node."; FAILED=1; continue; }

        # Wait until the storage host and its destination mount are available.
        last_storage_notice=$(date +%s)
        until ssh -o BatchMode=yes -o ConnectTimeout=5 "$STORAGE_TARGET" "mountpoint -q '$BACKUP_MOUNT'" >/dev/null 2>&1; do
            now=$(date +%s)
            if (( now - last_storage_notice >= 1800 )); then
                log 'Waiting for the storage host and its backup mount to return.'
                notify 'Waiting for backup storage' 'VM backups are ready; waiting for the storage host and backup mount before copying.' high
                last_storage_notice=$now
            fi
            sleep "$POLL_SECONDS"
        done
        dest_dir="$NODE_ROOT/${FOLDERS[$node]}"
        ssh -o BatchMode=yes "$STORAGE_TARGET" "mkdir -p '$dest_dir'"
        log "Copying $node archive $filename to shared backup storage."
        CURRENT_PARTIAL_PATH="$dest_dir/$filename.partial"
        if [[ "$target" == LOCAL ]]; then
            scp -p -o BatchMode=yes "$archive" "$STORAGE_TARGET:'$dest_dir/$filename.partial'"
        else
            scp -3 -p -o BatchMode=yes "$target:$archive" "$STORAGE_TARGET:'$dest_dir/$filename.partial'"
        fi
        copied_hash=$(ssh -o BatchMode=yes "$STORAGE_TARGET" "sha256sum '$dest_dir/$filename.partial'" | awk 'NR==1 {print $1}')
        if [[ "$copied_hash" != "$remote_hash" ]]; then
            ssh -o BatchMode=yes "$STORAGE_TARGET" "rm -f '$dest_dir/$filename.partial'"
            CURRENT_PARTIAL_PATH=''
            log "ERROR: Checksum mismatch for $node/$filename on shared storage."; FAILED=1; continue
        fi
        ssh -o BatchMode=yes "$STORAGE_TARGET" "mv '$dest_dir/$filename.partial' '$dest_dir/$filename' && printf '%s  %s\\n' '$copied_hash' '$filename' > '$dest_dir/$filename.sha256'"
        CURRENT_PARTIAL_PATH=''
        log "Verified $node/$filename on shared storage."
    else
        rc=$?
        log "ERROR: backup command failed on $node (exit $rc). See ${LOGS[$node]}"
        cat "${LOGS[$node]}" >&2
        FAILED=1
    fi
done

if (( FAILED )); then
    notify 'Weekly VM backup incomplete' 'At least one Proxmox backup or copy failed. shared storage to replica sync was not started; inspect coordinator logs.' urgent
    FAILURE_NOTIFIED=1
    exit 1
fi

# Keep a bounded weekly collection on shared storage. The replication script uses
# --backup/--backup-dir, so files removed here are retained in its history.
if [[ "$COLLECTED_RETENTION" =~ ^[0-9]+$ ]] && (( COLLECTED_RETENTION > 0 )); then
    for entry in "${NODES[@]}"; do
        IFS='|' read -r node target remote_script <<< "$entry"
        dest_dir="$NODE_ROOT/${FOLDERS[$node]}"
        ssh -o BatchMode=yes "$STORAGE_TARGET" "bash -s -- '$dest_dir' '$COLLECTED_RETENTION'" <<'REMOTE_PRUNE'
set -euo pipefail
dir=$1
keep=$2
mapfile -t old < <(find "$dir" -maxdepth 1 -type f -name 'vm_exports_*.tar.gz' -printf '%T@\t%p\n' | sort -rn | cut -f2- | tail -n +$((keep + 1)))
for archive in "${old[@]}"; do rm -f -- "$archive" "${archive}.sha256"; done
REMOTE_PRUNE
    done
fi

# Run the configured replication step on the storage host.
log 'All node archives are verified on shared storage; starting replication.'
ssh -o BatchMode=yes "$STORAGE_TARGET" "mountpoint -q '$BACKUP_MOUNT' && '$REPLICATION_SCRIPT'"
log 'Full weekly Proxmox collection and replication completed.'
notify 'Weekly VM backup complete' 'All configured Proxmox backups were copied and verified on shared storage, then shared storage -> replica sync completed.' default
