# Server Disk Cleanup + Cron Installer

Two small Bash scripts to automatically free disk space when a filesystem drops below a threshold (10GB by default). Includes an installer that sets up a cron job and optional Docker cleanup (stopped containers, images, networks, and unused volumes).

## Contents

- `disk-cleanup.sh` — Performs the cleanup when free space is below threshold.
- `setup-disk-cleanup-cron.sh` — Installs/updates an hourly cron job (configurable) and copies the cleanup script to `/usr/local/sbin/disk-cleanup`.

## What It Cleans (safe defaults)

- Package caches: `apt` / `dnf` / `yum` caches.
- Journald logs: retains last 7 days (`journalctl --vacuum-time=7d`).
- Temp files: removes files and empty dirs older than 7 days in `/tmp` and `/var/tmp`.
- Rotated logs: deletes archived logs older than 14 days in `/var/log` (`*.gz`, `*.1`, `*.old`).
- Optional Docker cleanup (disabled by default):
  - Prunes stopped containers, unused images, and networks older than N hours.
  - Optionally prunes unused dangling volumes older than N hours.

## Requirements

- Linux with cron (`cron`/`crond`) and `bash`.
- Root privileges to install and run via cron.
- `logger` (usually from `util-linux`) for syslog/journal integration.
- Optional: Docker CLI if Docker pruning is enabled.

## Quick Install

Clone or copy this repo anywhere, then run the installer as root:

```
sudo bash ./setup-disk-cleanup-cron.sh \
  --enable-docker-prune \
  --docker-prune-include-volumes
```

This will:

- Copy `disk-cleanup.sh` to `/usr/local/sbin/disk-cleanup` (0755).
- Add an hourly root cron job that logs with tag `disk-cleanup`.

## Installer Options

`./setup-disk-cleanup-cron.sh [options]`

- `-t, --threshold-gb N` — Minimum free space in GB before cleanup runs (default: `10`).
- `-s, --schedule CRON_EXPR` — Cron schedule (default: `"0 * * * *"`, hourly).
- `-p, --path PATH` — Filesystem path to check (default: `/`).
- `--enable-docker-prune` — Enable Docker pruning.
- `--docker-prune-hours N` — Age threshold in hours for Docker prune (default: `168` = 7 days).
- `--docker-prune-include-volumes` — Also prune unused volumes older than the threshold.
- `--cleanup-script PATH` — Source path of the cleanup script to install.
- `--cron-only` — Do not copy the script; only (re)install cron for existing `/usr/local/sbin/disk-cleanup`.
- `--uninstall` — Remove cron job and installed script.

Examples:

```
# Hourly, default threshold, include Docker prune (7 days age), include volumes
sudo bash ./setup-disk-cleanup-cron.sh \
  --enable-docker-prune \
  --docker-prune-include-volumes

# Every 30 minutes, 12GB threshold, Docker prune older than 5 days (120h)
sudo bash ./setup-disk-cleanup-cron.sh \
  -s "*/30 * * * *" -t 12 \
  --enable-docker-prune --docker-prune-hours 120

# Only update cron, assuming /usr/local/sbin/disk-cleanup already exists
sudo bash ./setup-disk-cleanup-cron.sh --cron-only -s "*/5 * * * *"
```

## Cleanup Script Configuration (env vars)

These can be set inline in cron or when running manually:

- `THRESHOLD_GB` — Trigger threshold in GB (default: `10`).
- `TARGET_PATH` — Mount path to check (default: `/`).
- `PRUNE_DOCKER` — `1` to enable Docker prune (default: `0`).
- `DOCKER_PRUNE_UNTIL_HOURS` — Age in hours for Docker prune filters (default: `168`).
- `PRUNE_DOCKER_VOLUMES` — `1` to include unused volumes older than the threshold (default: `0`).
- `JOURNAL_RETAIN_DAYS` — Journald retention (default: `7`).
- `TMP_RETAIN_DAYS` — Temp files retention (default: `7`).
- `LOG_ARCHIVE_RETAIN_DAYS` — Rotated log retention (default: `14`).

Manual run examples:

```
# Dry-ish test (no Docker), forces trigger by using high threshold
sudo THRESHOLD_GB=999 PRUNE_DOCKER=0 /usr/local/sbin/disk-cleanup

# Full cleanup with Docker including volumes, 24h age
sudo THRESHOLD_GB=999 PRUNE_DOCKER=1 PRUNE_DOCKER_VOLUMES=1 DOCKER_PRUNE_UNTIL_HOURS=24 /usr/local/sbin/disk-cleanup
```

## Verify It’s Working

- Check binary: `ls -l /usr/local/sbin/disk-cleanup`
- Check cron entry: `sudo crontab -l | grep disk-cleanup`
- Ensure cron service is active:
  - Debian/Ubuntu: `systemctl is-active cron`
  - RHEL/CentOS: `systemctl is-active crond`
- View logs (tag `disk-cleanup`):
  - Journald: `sudo journalctl -t disk-cleanup -n 100`
  - Debian/Ubuntu syslog: `sudo grep disk-cleanup /var/log/syslog`

You should see messages like:

```
disk-cleanup: Free space OK: 37GB >= 10GB on /
disk-cleanup: Low free space detected: 7GB < 10GB on /
disk-cleanup: Starting: apt-get clean
disk-cleanup: Done: apt-get clean
...
```

For testing cron timing, you can temporarily use every 5 minutes:

```
sudo bash ./setup-disk-cleanup-cron.sh -s "*/5 * * * *" --cron-only
```

## Uninstall

```
sudo bash ./setup-disk-cleanup-cron.sh --uninstall
```

This removes the cron job and `/usr/local/sbin/disk-cleanup`.

## Troubleshooting

- No logs appear:
  - Confirm `logger` exists: `command -v logger`.
  - Confirm cron is active: `systemctl is-active cron|crond`.
  - Temporarily change cron to write a file: `... /usr/local/sbin/disk-cleanup >> /var/log/disk-cleanup.log 2>&1` and check `sudo tail -n 100 /var/log/disk-cleanup.log`.
- PATH issues in cron:
  - Cron has a minimal env. The installer sets a full `PATH` via the script. If customizing cron manually, ensure `/usr/local/sbin:/usr/sbin:/sbin` are accessible.
- Docker pruning is aggressive?
  - By default it's OFF. When enabled, it removes stopped containers, unused images, and networks older than the configured hours. Volumes are pruned only if unused (dangling) and older than the configured hours.

## Safety Notes

- The script performs age-based cleanup for `/tmp`, `/var/tmp`, and rotated logs; it avoids live logs and non-rotated log files.
- Docker pruning never touches running containers. Volume pruning removes only unused volumes.
- Always test manually first with a high `THRESHOLD_GB` to see actions and logs.
