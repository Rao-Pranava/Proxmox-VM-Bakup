# Proxmox backup and VM disk utilities

This was created to make VM/container backups repeatable, reduce simultaneous guest downtime during an export run, verify copied archives, and provide reusable VM disk import/export helpers. 

**They are examples to adapt and review for your own infrastructure; *they are not a turnkey, universally safe backup policy*.**

## Contents

| File | Purpose |
|---|---|
| `export_all_vms.sh` | On one Proxmox node, backs up QEMU VMs and LXC containers sequentially using `vzdump`. A guest that was running is gracefully stopped only for its own backup and restarted before the next guest. Creates a compressed archive and SHA-256 checksum. |
| `collect_proxmox_backups.sh` | Coordinator for multiple Proxmox nodes. Waits for configured nodes to become reachable, starts their exporters, validates archives and checksums, copies each archive to a storage host, prunes old collected archives, then invokes a configured replication script. |
| `proxmox-backup.conf.example` | Example per-node exporter configuration. Copy to `/etc/proxmox-backup.conf` and customize. |
| `proxmox-backup-nodes.conf.example` | Example coordinator configuration. Copy to `/etc/proxmox-backup-nodes.conf` and replace every sample host, path, and folder. |
| `weekly-proxmox-backup.service` | systemd oneshot service for the coordinator. |
| `weekly-proxmox-backup.timer` | Example weekly schedule using systemd's `weekly` calendar expression; persistent across downtime. Change the schedule as needed. |
| `replicate-backup.sh` | Generic source-to-destination rsync replication with dated history of replaced/deleted files. Configure source and destination mount points in the script before use. |
| `Proxmox.sh` | Interactive/CLI helper for exporting VM disks, importing disks from local or remote sources, and creating VMs. This is separate from the weekly `vzdump` flow. |

## How the coordinated backup works

1. The coordinator runs on one Proxmox node (Your Primary Node) and reads `/etc/proxmox-backup-nodes.conf`.
2. For each listed node, it waits until SSH is available (or runs locally for the `LOCAL` target), then invokes `export_all_vms.sh`.
3. The exporter waits for an active `vzdump` task to finish. It records guest configurations and states, then handles one guest at a time. Running guests receive a graceful shutdown, are backed up with `vzdump`, and are restarted before the next guest. Guests that were stopped remain stopped. The script refuses certain excluded or host-mounted disks/volumes because those would make an incomplete backup.
4. The exporter packages the per-guest archives and configuration files into `vm_exports_<node>_<timestamp>.tar.gz`, validates the tar archive, and writes a `.sha256` checksum.
5. The coordinator checks the source checksum, copies the archive to the configured storage host using SSH/SCP, verifies the copied checksum, and promotes the partial file to its final name only after verification.
6. Once all configured nodes succeed, older collected archives are pruned according to `COLLECTED_RETENTION`; then the coordinator runs the configured replication script. On an export or copy failure, the replication step is skipped.

`replicate-backup.sh` is a separate replication example. It requires both configured source and destination paths to be mounted, then uses `rsync` with deletion protection and dated history. Read its options and behavior before using it on valuable data.

## Requirements

- Proxmox VE with Bash and the native `qm`, `pct`, `pvesh`, and `vzdump` tools.
- On Proxmox nodes: `python3`, `tar`, `sha256sum`, `flock`, and standard GNU utilities. `curl` is needed only when enabling notifications.
- On the coordinator: `ssh`, `scp`, `sha256sum`, and `flock`.
- On the storage host for `replicate-backup.sh`: `rsync`, `flock`, `mountpoint`, and standard GNU utilities. Install `curl` only if you enable its notifications.
- Root access for Proxmox guest management and writing backup locations.
- Non-interactive SSH from the coordinator to every remote Proxmox node and to the storage host, with known host keys already accepted. Grant only the permissions needed for the commands and paths in use.
- Enough free space for per-guest temporary files, the packaged archive, and retained copies.

## Installation

Review every script and sample configuration before installing. The examples use generic hostnames and paths. Replace them with your own values; do not put passwords, private keys, access tokens, public IPs, or internal endpoints in a public repository.

### 1. Install the exporter on each Proxmox node

Copy `export_all_vms.sh` to each node and install the per-node config:

```bash
install -o root -g root -m 700 export_all_vms.sh /usr/local/sbin/export_all_vms.sh
install -o root -g root -m 600 proxmox-backup.conf.example /etc/proxmox-backup.conf
```

Edit `/etc/proxmox-backup.conf`. Set `BACKUP_ROOT` to a location with sufficient free space, set a suitable shutdown timeout and retention count, and leave notifications disabled unless you have configured a notification service. The example config sets `/srv/proxmox-backups`.

### 2. Configure SSH and the coordinator

Set up and manually verify key-based SSH from the coordinator to each remote node and the storage host. Confirm that the selected SSH account can run the exporter, create destination directories, copy files, and invoke the replication script. Avoid disabling SSH host-key checking.

Copy the coordinator files:

```bash
install -o root -g root -m 700 collect_proxmox_backups.sh /usr/local/sbin/collect_proxmox_backups.sh
install -o root -g root -m 600 proxmox-backup-nodes.conf.example /etc/proxmox-backup-nodes.conf
```

Edit `/etc/proxmox-backup-nodes.conf`:

- Keep one `NODES` entry per Proxmox node. Each row is `node-label|SSH-target|remote-script-path|destination-subfolder`.
- Use `LOCAL` for the coordinator node itself. Other targets can be SSH aliases or `user@hostname` values resolvable by the coordinator.
- The script path must exist on each target. Destination subfolders must be simple names without `/`.
- Set `STORAGE_TARGET`, `NODE_ROOT`, and `BACKUP_MOUNT` to the storage host and mounted destination used by your system.
- Set `REPLICATION_SCRIPT` to the replication script installed on the storage host.
- Adjust `COLLECTED_RETENTION` and `POLL_SECONDS` to fit your storage and availability requirements. The example retains four completed archives per node.

The coordinator waits indefinitely for configured nodes and storage to return. A powered-off or unreachable machine can therefore keep the scheduled service running. Only list nodes that should be included, and plan how you will recover a run that waits for a machine that will not return.

### 3. Configure optional replication

If using `replicate-backup.sh`, copy it to the storage host and edit its `SOURCE` and `DEST` settings to the actual mounted filesystems. Ensure those mount points are real mount points; this check prevents accidental writes into an unmounted directory. Review `RETENTION_DAYS`, `HISTORY_DIR`, and log paths, then run the script manually with a small test dataset before connecting it to the coordinator. The current replication example expects the storage host to have both source and destination filesystems mounted.

```bash
install -o root -g root -m 700 replicate-backup.sh /usr/local/sbin/replicate-backup.sh
```

Notifications are off by default. To enable them, set `NTFY_URL`, `NTFY_TOPIC`, and `NTFY_ENABLED=1` in the private config files. Treat a notification endpoint or topic as potentially sensitive and keep private values out of Git.

### 4. Install and schedule the systemd unit

On the coordinator, install the service and timer after editing the service's `ExecStart` if you chose a different script path:

```bash
install -o root -g root -m 644 weekly-proxmox-backup.service /etc/systemd/system/weekly-proxmox-backup.service
install -o root -g root -m 644 weekly-proxmox-backup.timer /etc/systemd/system/weekly-proxmox-backup.timer
systemctl daemon-reload
systemctl enable --now weekly-proxmox-backup.timer
systemctl list-timers weekly-proxmox-backup.timer
```

The `weekly` expression uses systemd's weekly default schedule in the host's local time zone. Edit `OnCalendar` if a different maintenance window is appropriate. Run an initial supervised trial in a maintenance window before relying on the timer. Check logs with `journalctl -u weekly-proxmox-backup.service`, exporter output, generated archives and checksums, guest states, storage capacity, and the replication result. Test restoring a guest to a spare VMID or isolated destination. A backup that has not been restore-tested should not be treated as a proven recovery plan.

## Standalone VM disk utility

`Proxmox.sh` is not called by the coordinated exporter. Run it as root on a Proxmox host after reviewing its behavior. Use `bash Proxmox.sh --help` for examples and options. Exports can write large disk images; imports and VM creation change the Proxmox configuration. Check target storage, VM IDs, formats, network access, and free space first. Try recovery operations with a test VM before using production data.

## Security and data handling

- The scripts process full VM and container contents, which can include credentials and personal data. Protect backup archives and their destination with appropriate access controls and encryption at rest.
- Keep real node names, IP addresses, storage paths, notification endpoints, and credentials in host-local configuration files with restrictive permissions. Do not commit those files.
- The `.example` files in this folder contain placeholders and should be copied to private host configs before customization.
- Replication with deletion behavior can remove destination files. Understand the configured history/retention behavior and test against disposable data first.
- This project does not provide encryption, off-site storage, or a restore orchestration system by itself.

## Video & Blog

Coming Soon.....
