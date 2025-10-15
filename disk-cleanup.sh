#!/usr/bin/env bash
set -Eeuo pipefail

# Disk cleanup script
# - Checks free space on a target path
# - If below threshold, performs safe cleanup steps
#
# Config via env vars (override in cron if desired):
#   THRESHOLD_GB            default: 10
#   TARGET_PATH             default: /
#   PRUNE_DOCKER            default: 0 (set to 1 to enable Docker prune)
#   PRUNE_DOCKER_VOLUMES    default: 0 (set to 1 to prune unused volumes)
#   DOCKER_PRUNE_UNTIL_HOURS default: 168 (age threshold for Docker prune)
#   JOURNAL_RETAIN_DAYS     default: 7
#   TMP_RETAIN_DAYS         default: 7
#   LOG_ARCHIVE_RETAIN_DAYS default: 14

THRESHOLD_GB=${THRESHOLD_GB:-10}
TARGET_PATH=${TARGET_PATH:-/}
PRUNE_DOCKER=${PRUNE_DOCKER:-0}
PRUNE_DOCKER_VOLUMES=${PRUNE_DOCKER_VOLUMES:-0}
JOURNAL_RETAIN_DAYS=${JOURNAL_RETAIN_DAYS:-7}
TMP_RETAIN_DAYS=${TMP_RETAIN_DAYS:-7}
LOG_ARCHIVE_RETAIN_DAYS=${LOG_ARCHIVE_RETAIN_DAYS:-14}
DOCKER_PRUNE_UNTIL_HOURS=${DOCKER_PRUNE_UNTIL_HOURS:-168}

# Ensure sbin paths are available for cron
export PATH="${PATH}:/usr/sbin:/sbin:/usr/local/sbin:/usr/local/bin"

log() {
  if command -v logger >/dev/null 2>&1; then
    logger -t disk-cleanup "$*"
  else
    printf '%s disk-cleanup: %s\n' "$(date -Is)" "$*"
  fi
}

avail_kb() {
  df -Pk "$TARGET_PATH" | awk 'NR==2 {print $4}'
}

cleanup_step() {
  local title=$1
  shift || true
  log "Starting: ${title}"
  if "$@" >/dev/null 2>&1; then
    log "Done: ${title}"
  else
    log "Skipped/failed: ${title}"
  fi
}

prune_old_unused_volumes() {
  # Prune only volumes that are unused (dangling) and older than DOCKER_PRUNE_UNTIL_HOURS
  local hours cutoff now removed=0
  hours=${DOCKER_PRUNE_UNTIL_HOURS}
  now=$(date +%s 2>/dev/null || echo 0)
  (( now == 0 )) && return 0
  cutoff=$(( now - hours * 3600 ))

  local v created created_ts
  for v in $(docker volume ls -qf dangling=true 2>/dev/null); do
    created=$(docker volume inspect -f '{{.CreatedAt}}' "$v" 2>/dev/null || true)
    [[ -z "$created" ]] && continue
    created_ts=$(date -d "$created" +%s 2>/dev/null || echo 0)
    (( created_ts == 0 )) && continue
    if (( created_ts < cutoff )); then
      if docker volume rm "$v" >/dev/null 2>&1; then
        removed=$((removed+1))
      fi
    fi
  done
  log "Docker volumes pruned (unused, > ${hours}h): ${removed}"
}

threshold_kb=$(( THRESHOLD_GB * 1024 * 1024 ))
current_kb=$(avail_kb)

if [[ -z "$current_kb" || "$current_kb" -eq 0 ]]; then
  log "Could not determine free space for $TARGET_PATH"
  exit 1
fi

if (( current_kb >= threshold_kb )); then
  log "Free space OK: $(( current_kb / 1024 / 1024 ))GB >= ${THRESHOLD_GB}GB on $TARGET_PATH"
  exit 0
fi

log "Low free space detected: $(( current_kb / 1024 / 1024 ))GB < ${THRESHOLD_GB}GB on $TARGET_PATH"

# Package cache cleanup (Debian/Ubuntu)
if command -v apt-get >/dev/null 2>&1; then
  cleanup_step "apt-get clean" bash -c 'apt-get clean'
fi

# Package cache cleanup (RHEL/CentOS/Fedora)
if command -v dnf >/dev/null 2>&1; then
  cleanup_step "dnf clean all" bash -c 'dnf -y clean all'
elif command -v yum >/dev/null 2>&1; then
  cleanup_step "yum clean all" bash -c 'yum -y clean all'
fi

# Vacuum systemd journal to retain recent logs only
if command -v journalctl >/dev/null 2>&1; then
  cleanup_step "journalctl vacuum ${JOURNAL_RETAIN_DAYS}d" bash -c "journalctl --vacuum-time=${JOURNAL_RETAIN_DAYS}d"
fi

# Clean /tmp and /var/tmp of old files (safe, age-based)
cleanup_step "/tmp files older than ${TMP_RETAIN_DAYS}d" bash -c "find /tmp -xdev -type f -mtime +${TMP_RETAIN_DAYS} -delete"
cleanup_step "/tmp empty dirs older than ${TMP_RETAIN_DAYS}d" bash -c "find /tmp -xdev -type d -empty -mtime +${TMP_RETAIN_DAYS} -delete"
cleanup_step "/var/tmp files older than ${TMP_RETAIN_DAYS}d" bash -c "find /var/tmp -xdev -type f -mtime +${TMP_RETAIN_DAYS} -delete"
cleanup_step "/var/tmp empty dirs older than ${TMP_RETAIN_DAYS}d" bash -c "find /var/tmp -xdev -type d -empty -mtime +${TMP_RETAIN_DAYS} -delete"

# Remove archived/rotated logs older than retention
cleanup_step "/var/log rotated logs older than ${LOG_ARCHIVE_RETAIN_DAYS}d" bash -c "find /var/log -xdev -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) -mtime +${LOG_ARCHIVE_RETAIN_DAYS} -delete"

# Optional: prune unused Docker data
if [[ "${PRUNE_DOCKER}" == "1" ]] && command -v docker >/dev/null 2>&1; then
  cleanup_step "docker container prune (> ${DOCKER_PRUNE_UNTIL_HOURS}h)" docker container prune -f --filter "until=${DOCKER_PRUNE_UNTIL_HOURS}h"
  cleanup_step "docker image prune (> ${DOCKER_PRUNE_UNTIL_HOURS}h)" docker image prune -af --filter "until=${DOCKER_PRUNE_UNTIL_HOURS}h"
  cleanup_step "docker network prune (> ${DOCKER_PRUNE_UNTIL_HOURS}h)" docker network prune -f --filter "until=${DOCKER_PRUNE_UNTIL_HOURS}h"
  if [[ "${PRUNE_DOCKER_VOLUMES}" == "1" ]]; then
    cleanup_step "docker volume prune (unused > ${DOCKER_PRUNE_UNTIL_HOURS}h)" prune_old_unused_volumes
  fi
fi

# Re-check free space and report status
current_kb_after=$(avail_kb)
if (( current_kb_after >= threshold_kb )); then
  log "Cleanup successful: $(( current_kb_after / 1024 / 1024 ))GB >= ${THRESHOLD_GB}GB on $TARGET_PATH"
  exit 0
else
  log "Cleanup done but still low: $(( current_kb_after / 1024 / 1024 ))GB < ${THRESHOLD_GB}GB on $TARGET_PATH"
  exit 0
fi
