#!/usr/bin/env bash
# Back up QEMU VMs and LXC containers one guest at a time. A guest that was
# running is gracefully stopped only for its own backup and restarted before
# the next guest is processed. Guests already stopped remain stopped.
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

BACKUP_ROOT=${BACKUP_ROOT:-/srv/proxmox-backups}
CONFIG_FILE=${CONFIG_FILE:-/etc/proxmox-backup.conf}
SHUTDOWN_TIMEOUT=${SHUTDOWN_TIMEOUT:-900}
RETENTION_COUNT=${RETENTION_COUNT:-4}
NTFY_URL=${NTFY_URL:-}
NTFY_TOPIC=${NTFY_TOPIC:-}
NTFY_ENABLED=${NTFY_ENABLED:-0}

[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

NODE=$(hostname -s)
SAFE_NODE=$(printf '%s' "$NODE" | tr -c 'A-Za-z0-9_.-' '_')
STAMP=$(date '+%Y-%m-%d_%H-%M-%S')
RUN_ID="${SAFE_NODE}_${STAMP}"
STAGE_NAME="vm_export_${RUN_ID}"
STAGE_DIR="${BACKUP_ROOT}/.${STAGE_NAME}.work"
LOCK_FILE=/run/lock/export-all-vms.lock

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
notify() {
    [[ "$NTFY_ENABLED" == 1 ]] || return 0
    [[ -n "$NTFY_URL" && -n "$NTFY_TOPIC" ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    curl --connect-timeout 3 --max-time 10 -fsS -X POST \
        -H "Title: $1" -H "Priority: ${3:-default}" -H 'Tags: floppy_disk' \
        --data-raw "$2" "${NTFY_URL%/}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
}

guest_status() {
    local kind=$1 id=$2
    if [[ "$kind" == vm ]]; then
        qm status "$id" | awk '{print $2}'
    else
        pct status "$id" | awk '{print $2}'
    fi
}

guest_start() {
    local kind=$1 id=$2
    if [[ "$kind" == vm ]]; then qm start "$id"; else pct start "$id"; fi
}

if [[ $EUID -ne 0 ]]; then echo 'Must run as root on a Proxmox node.' >&2; exit 1; fi
for cmd in qm pct vzdump pvesh python3 tar sha256sum flock; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Required command missing: $cmd" >&2; exit 1; }
done
mkdir -p "$BACKUP_ROOT"
exec 9>"$LOCK_FILE"
flock -n 9 || { log 'Another guest export is already running.'; exit 1; }

# Wait for an existing Proxmox backup task before beginning our sequential run.
LAST_VZDUMP_NOTICE=$(date +%s)
while true; do
    ACTIVE_VZDUMP=$(pvesh get "/nodes/$NODE/tasks" --source active --typefilter vzdump --output-format json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
    [[ "$ACTIVE_VZDUMP" =~ ^[0-9]+$ ]] || { log 'ERROR: Could not determine active Proxmox backup tasks.'; exit 1; }
    (( ACTIVE_VZDUMP == 0 )) && break
    log "Waiting for $ACTIVE_VZDUMP active Proxmox backup task(s)."
    now=$(date +%s)
    if (( now - LAST_VZDUMP_NOTICE >= 1800 )); then
        notify 'Guest backup waiting' "$NODE has an active Proxmox backup; the sequential guest run is waiting for it to finish." high
        LAST_VZDUMP_NOTICE=$now
    fi
    sleep 60
done

VM_LIST=$(qm list) || { log 'ERROR: Could not list QEMU VMs.'; exit 1; }
CT_LIST=$(pct list) || { log 'ERROR: Could not list LXC containers.'; exit 1; }
mapfile -t GUEST_ROWS < <(
    printf '%s\n' "$VM_LIST" | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print "vm|" $1 "|" $3}'
    printf '%s\n' "$CT_LIST" | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print "ct|" $1 "|" $2}'
)
for row in "${GUEST_ROWS[@]}"; do
    IFS='|' read -r kind id listed_state <<< "$row"
    if [[ "$listed_state" != running && "$listed_state" != stopped ]]; then
        log "ERROR: $kind $id is listed in unsupported state '$listed_state'; refusing to start a partial run."
        exit 1
    fi
done

CURRENT_GUEST_KIND=''
CURRENT_GUEST_ID=''
CURRENT_GUEST_NAME=''
CURRENT_GUEST_WAS_RUNNING=0
STAGE_CREATED=0
RESTART_FAILURE=0

restart_current_guest() {
    local state
    [[ "$CURRENT_GUEST_WAS_RUNNING" == 1 ]] || return 0
    state=$(guest_status "$CURRENT_GUEST_KIND" "$CURRENT_GUEST_ID" 2>/dev/null || true)
    if [[ "$state" == running ]]; then
        CURRENT_GUEST_WAS_RUNNING=0
        return 0
    fi
    if [[ "$state" != stopped ]]; then
        log "ERROR: Cannot safely determine state of $CURRENT_GUEST_KIND $CURRENT_GUEST_ID (${CURRENT_GUEST_NAME}); it reports '${state:-unknown}'."
        RESTART_FAILURE=1
        return 1
    fi

    log "Starting $CURRENT_GUEST_KIND $CURRENT_GUEST_ID (${CURRENT_GUEST_NAME}) after its backup."
    if ! guest_start "$CURRENT_GUEST_KIND" "$CURRENT_GUEST_ID"; then
        log "ERROR: Could not start $CURRENT_GUEST_KIND $CURRENT_GUEST_ID."
        RESTART_FAILURE=1
        notify 'Guest restart failed' "$NODE could not restart $CURRENT_GUEST_KIND $CURRENT_GUEST_ID (${CURRENT_GUEST_NAME}) after backup." urgent
        return 1
    fi
    state=$(guest_status "$CURRENT_GUEST_KIND" "$CURRENT_GUEST_ID" 2>/dev/null || true)
    if [[ "$state" != running ]]; then
        log "ERROR: Start command returned, but $CURRENT_GUEST_KIND $CURRENT_GUEST_ID is '${state:-unknown}'."
        RESTART_FAILURE=1
        notify 'Guest restart needs attention' "$NODE start was requested for $CURRENT_GUEST_KIND $CURRENT_GUEST_ID (${CURRENT_GUEST_NAME}), but it is not reporting running." urgent
        return 1
    fi
    CURRENT_GUEST_WAS_RUNNING=0
    notify 'Guest powered on after backup' "$NODE $CURRENT_GUEST_KIND $CURRENT_GUEST_ID (${CURRENT_GUEST_NAME}) is running again." default
    return 0
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    restart_current_guest
    (( RESTART_FAILURE == 0 )) || (( rc != 0 )) || rc=1
    if (( rc == 0 )); then
        [[ -d "$STAGE_DIR" ]] && rm -rf -- "$STAGE_DIR"
    elif (( STAGE_CREATED == 1 )) && [[ -d "$STAGE_DIR" ]]; then
        log "Partial guest backups and configs were kept at $STAGE_DIR for inspection; remove them only after checking the failed run."
    fi
    if (( rc != 0 )); then
        notify 'Guest backup failed' "$NODE sequential VM/container backup failed (exit $rc). Check the node log and any partial work directory." urgent
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$STAGE_DIR/configs" "$STAGE_DIR/guests"
STAGE_CREATED=1
printf 'node=%s\nrun_id=%s\nstarted=%s\n' "$NODE" "$RUN_ID" "$(date -Is)" > "$STAGE_DIR/manifest.txt"
: > "$STAGE_DIR/guest-states.tsv"

for row in "${GUEST_ROWS[@]}"; do
    IFS='|' read -r kind id listed_state <<< "$row"
    state=$(guest_status "$kind" "$id")
    if [[ "$state" != running && "$state" != stopped ]]; then
        log "ERROR: $kind $id is in unsupported state '${state:-unknown}'; stopping without changing it."
        exit 1
    fi

    if [[ "$kind" == vm ]]; then
        config=$(qm config "$id")
        name=$(printf '%s\n' "$config" | sed -n 's/^name: //p' | head -n 1)
        config_file="$STAGE_DIR/configs/vm-${id}_${name:-vm-$id}.conf"
        if grep -Eq '^(ide|sata|scsi|virtio|efidisk|tpmstate)[0-9]+:.*backup=0|^(ide|sata|scsi|virtio)[0-9]+: /dev/' <<< "$config"; then
            log "ERROR: VM $id has a disk excluded from backup or mapped directly to a host device; refusing an incomplete backup."
            exit 1
        fi
        archive_pattern='vzdump-qemu-*.vma.zst'
        guest_label=VM
    else
        config=$(pct config "$id")
        name=$(printf '%s\n' "$config" | sed -n 's/^hostname: //p' | head -n 1)
        config_file="$STAGE_DIR/configs/ct-${id}_${name:-ct-$id}.conf"
        if grep -Eq '^(rootfs|mp[0-9]+):.*backup=0|^mp[0-9]+: /|^dev[0-9]+:' <<< "$config"; then
            log "ERROR: CT $id has an excluded, bind-mounted, or device-mounted volume. Such host data is not included in vzdump; review the container config before continuing."
            exit 1
        fi
        archive_pattern='vzdump-lxc-*.tar.zst'
        guest_label=container
    fi
    [[ -n "$name" ]] || name="$kind-$id"
    safe_name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')
    config_file="$STAGE_DIR/configs/${kind}-${id}_${safe_name}.conf"
    guest_dir="$STAGE_DIR/guests/${kind}-${id}_${safe_name}"
    mkdir -p "$guest_dir"
    printf '%s\n' "$config" > "$config_file"
    printf '%s\t%s\t%s\t%s\n' "$kind" "$id" "$name" "$state" >> "$STAGE_DIR/guest-states.tsv"

    CURRENT_GUEST_KIND=$kind
    CURRENT_GUEST_ID=$id
    CURRENT_GUEST_NAME=$name
    CURRENT_GUEST_WAS_RUNNING=0

    if [[ "$state" == running ]]; then
        CURRENT_GUEST_WAS_RUNNING=1
        log "Requesting graceful shutdown of $guest_label $id ($name); other guests remain online."
        notify 'Guest powering off for backup' "$NODE $guest_label $id ($name) is shutting down for its individual backup." default
        if [[ "$kind" == vm ]]; then
            if ! qm shutdown "$id" --timeout "$SHUTDOWN_TIMEOUT"; then
                log "ERROR: Graceful shutdown failed for VM $id; no force-stop will be attempted."
                exit 1
            fi
        else
            if ! pct shutdown "$id" --timeout "$SHUTDOWN_TIMEOUT" --forceStop 0; then
                log "ERROR: Graceful shutdown failed for container $id; no force-stop will be attempted."
                exit 1
            fi
        fi
        state=$(guest_status "$kind" "$id")
        if [[ "$state" != stopped ]]; then
            log "ERROR: $guest_label $id did not reach stopped state; aborting."
            exit 1
        fi
    fi

    log "Backing up $guest_label $id ($name) while other guests remain available."
    vzdump "$id" --mode stop --compress zstd --dumpdir "$guest_dir"
    find "$guest_dir" -maxdepth 1 -type f -name "$archive_pattern" -print -quit | grep -q . || {
        log "ERROR: vzdump produced no expected archive for $guest_label $id."; exit 1;
    }

    if [[ "$CURRENT_GUEST_WAS_RUNNING" == 1 ]]; then
        restart_current_guest || exit 1
    fi
    log "Completed $guest_label $id ($name); continuing to the next guest."
done

printf 'completed=%s\n' "$(date -Is)" >> "$STAGE_DIR/manifest.txt"
ARCHIVE="${BACKUP_ROOT}/vm_exports_${RUN_ID}.tar.gz"
TEMP_ARCHIVE="${ARCHIVE}.partial"
rm -f -- "$TEMP_ARCHIVE"
log "Packaging sequential VM and container backups into $ARCHIVE."
tar -czf "$TEMP_ARCHIVE" -C "$BACKUP_ROOT" "$(basename "$STAGE_DIR")"
tar -tzf "$TEMP_ARCHIVE" >/dev/null
mv -- "$TEMP_ARCHIVE" "$ARCHIVE"
sha256sum "$ARCHIVE" | awk '{print $1}' > "${ARCHIVE}.sha256"

# Remove only older completed archives on this node, after the new one verifies.
if [[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] && (( RETENTION_COUNT > 0 )); then
    mapfile -t OLD_ARCHIVES < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name "vm_exports_${SAFE_NODE}_*.tar.gz" -printf '%T@ %p\n' | sort -nr | awk -v keep="$RETENTION_COUNT" 'NR>keep {sub(/^[^ ]+ /, ""); print}')
    for old in "${OLD_ARCHIVES[@]}"; do rm -f -- "$old" "${old}.sha256"; done
fi

log "Backup completed: $ARCHIVE"
notify 'Guest backup ready' "$NODE weekly VM/container backup completed: $(basename "$ARCHIVE")." default
printf 'ARCHIVE_PATH=%s\n' "$ARCHIVE"
printf 'CHECKSUM_PATH=%s.sha256\n' "$ARCHIVE"
