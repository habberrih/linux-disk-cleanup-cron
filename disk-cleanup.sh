#!/usr/bin/env bash
set -Eeuo pipefail

# Disk cleanup script
# - Checks free space (and inode headroom) on TARGET_PATH
# - If below threshold, performs safe cleanup steps
#
# Config via env vars (override in cron if desired):
#   THRESHOLD_GB               default: 10
#   TARGET_PATH                default: /
#   PRUNE_DOCKER               default: 0 (set to 1 to enable Docker prune)
#   PRUNE_DOCKER_VOLUMES       default: 0 (set to 1 to prune unused volumes)
#   DOCKER_PRUNE_UNTIL_HOURS   default: 168 (age threshold for Docker prune)
#   JOURNAL_RETAIN_DAYS        default: 7        (used if JOURNAL_MAX_SIZE=0)
#   JOURNAL_MAX_SIZE           default: 0        (e.g., "200M"; takes precedence if non-zero)
#   TMP_RETAIN_DAYS            default: 7
#   LOG_ARCHIVE_RETAIN_DAYS    default: 14
#   TRUNCATE_DOCKER_LOGS       default: 0        (1 to enable)
#   DOCKER_LOG_MAX_MB          default: 100
#   INODE_LOW_PCT              default: 2        (trigger if <2% inodes free)
#   PROTECT_VOLUME_REGEX       default: '^prod_|^backup_' (skip matching volumes when pruning)

THRESHOLD_GB=${THRESHOLD_GB:-10}
TARGET_PATH=${TARGET_PATH:-/}
PRUNE_DOCKER=${PRUNE_DOCKER:-0}
PRUNE_DOCKER_VOLUMES=${PRUNE_DOCKER_VOLUMES:-0}
JOURNAL_RETAIN_DAYS=${JOURNAL_RETAIN_DAYS:-7}
JOURNAL_MAX_SIZE=${JOURNAL_MAX_SIZE:-0}
TMP_RETAIN_DAYS=${TMP_RETAIN_DAYS:-7}
LOG_ARCHIVE_RETAIN_DAYS=${LOG_ARCHIVE_RETAIN_DAYS:-14}
DOCKER_PRUNE_UNTIL_HOURS=${DOCKER_PRUNE_UNTIL_HOURS:-168}
TRUNCATE_DOCKER_LOGS=${TRUNCATE_DOCKER_LOGS:-0}
DOCKER_LOG_MAX_MB=${DOCKER_LOG_MAX_MB:-100}
INODE_LOW_PCT=${INODE_LOW_PCT:-2}
PROTECT_VOLUME_REGEX=${PROTECT_VOLUME_REGEX:-'^prod_|^backup_'}

# Ensure sbin paths are available for cron
export PATH="${PATH}:/usr/sbin:/sbin:/usr/local/sbin:/usr/local/bin"

# Single-run lock to avoid overlap
LOCKFILE=/var/lock/disk-cleanup.lock
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  logger -t disk-cleanup "Another cleanup is running; exiting." 2>/dev/null || true
  exit 0
fi

log() {
  if command -v logger >/dev/null 2>&1; then
    logger -t disk-cleanup "$*"
  else
    printf '%s disk-cleanup: %s\n' "$(date -Is)" "$*"
  fi
}

# Run slow/IO-heavy things more nicely
run_slow() { ionice -c2 -n7 nice -n 19 "$@"; }

avail_kb() { df -Pk "$TARGET_PATH" | awk 'NR==2 {print $4}'; }
avail_inodes() { df -Pi "$TARGET_PATH" | awk 'NR==2{print $4}'; }
inode_total()  { df -Pi "$TARGET_PATH" | awk 'NR==2{print $2}'; }

cleanup_step() {
  local title=$1; shift || true
  log "Starting: ${title}"
  if "$@" >/dev/null 2>&1; then
    log "Done: ${title}"
  else
    local rc=$?
    log "FAILED (${rc}): ${title}"
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
    # optional protection by name/prefix
    if [[ -n "$PROTECT_VOLUME_REGEX" && "$v" =~ $PROTECT_VOLUME_REGEX ]]; then
      continue
    fi
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
[[ -z "$current_kb" || "$current_kb" -eq 0 ]] && { log "Could not determine free space for $TARGET_PATH"; exit 1; }

# Inode pressure guard: if < INODE_LOW_PCT% free, force cleanup path
it=$(inode_total); ia=$(avail_inodes)
if [[ -n "$it" && "$it" -gt 0 && -n "$ia" ]]; then
  free_pct=$(( 100 * ia / it ))
  if (( free_pct < INODE_LOW_PCT )); then
    log "Low inode headroom: ${free_pct}% free on $TARGET_PATH (forcing cleanup)"
    current_kb=$((threshold_kb - 1))
  fi
fi

if (( current_kb >= threshold_kb )); then
  log "Free space OK: $(( current_kb / 1024 / 1024 ))GB >= ${THRESHOLD_GB}GB on $TARGET_PATH"
  exit 0
fi

log "Low free space detected: $(( current_kb / 1024 / 1024 ))GB < ${THRESHOLD_GB}GB on $TARGET_PATH"
before_kb=$current_kb

# Package cache cleanup (Debian/Ubuntu)
if command -v apt-get >/dev/null 2>&1; then
  cleanup_step "apt-get clean" bash -c 'run_slow apt-get clean'
fi

# Package cache cleanup (RHEL/CentOS/Fedora)
if command -v dnf >/dev/null 2>&1; then
  cleanup_step "dnf clean all" bash -c 'run_slow dnf -y clean all'
elif command -v yum >/dev/null 2>&1; then
  cleanup_step "yum clean all" bash -c 'run_slow yum -y clean all'
fi

# Vacuum systemd journal by size (preferred) or time
if command -v journalctl >/dev/null 2>&1; then
  if [[ "$JOURNAL_MAX_SIZE" != "0" ]]; then
    cleanup_step "journalctl vacuum size ${JOURNAL_MAX_SIZE}" bash -c "run_slow journalctl --vacuum-size='${JOURNAL_MAX_SIZE}'"
  else
    cleanup_step "journalctl vacuum ${JOURNAL_RETAIN_DAYS}d" bash -c "run_slow journalctl --vacuum-time='${JOURNAL_RETAIN_DAYS}d'"
  fi
fi

# Clean /tmp and /var/tmp of old files/empty dirs
cleanup_step "/tmp files older than ${TMP_RETAIN_DAYS}d"         bash -c "run_slow find /tmp -xdev -type f -mtime +${TMP_RETAIN_DAYS} -delete"
cleanup_step "/tmp empty dirs older than ${TMP_RETAIN_DAYS}d"    bash -c "run_slow find /tmp -xdev -type d -empty -mtime +${TMP_RETAIN_DAYS} -delete"
cleanup_step "/var/tmp files older than ${TMP_RETAIN_DAYS}d"     bash -c "run_slow find /var/tmp -xdev -type f -mtime +${TMP_RETAIN_DAYS} -delete"
cleanup_step "/var/tmp empty dirs older than ${TMP_RETAIN_DAYS}d" bash -c "run_slow find /var/tmp -xdev -type d -empty -mtime +${TMP_RETAIN_DAYS} -delete"

# Remove archived/rotated logs older than retention (wider patterns)
cleanup_step "/var/log rotated logs older than ${LOG_ARCHIVE_RETAIN_DAYS}d" bash -c \
'run_slow find /var/log -xdev -type f \( \
   -name "*.gz" -o -name "*.xz" -o -name "*.bz2" -o -name "*.zip" -o \
   -regex ".*/[^/]+\.log\.[0-9]+" -o -name "*.old" -o -name "*-old" \
 \) -mtime +'${LOG_ARCHIVE_RETAIN_DAYS}' -delete'

# Optional: truncate huge Docker JSON logs (safety valve; prefer proper rotation)
if [[ "${TRUNCATE_DOCKER_LOGS}" == "1" ]] && command -v docker >/dev/null 2>&1; then
  cleanup_step "truncate docker logs > ${DOCKER_LOG_MAX_MB}MB" bash -c \
  'run_slow find /var/lib/docker/containers -name "*-json.log" -size +'${DOCKER_LOG_MAX_MB}'M -exec truncate -s 0 {} \;'
fi

# Optional: prune unused Docker data
if [[ "${PRUNE_DOCKER}" == "1" ]] && command -v docker >/dev/null 2>&1; then
  cleanup_step "docker container prune (> ${DOCKER_PRUNE_UNTIL_HOURS}h)" bash -c "run_slow docker container prune -f --filter 'until=${DOCKER_PRUNE_UNTIL_HOURS}h'"
  cleanup_step "docker image prune (> ${DOCKER_PRUNE_UNTIL_HOURS}h)"     bash -c "run_slow docker image prune -af --filter 'until=${DOCKER_PRUNE_UNTIL_HOURS}h'"
  cleanup_step "docker network prune (> ${DOCKER_PRUNE_UNTIL_HOURS}h)"   bash -c "run_slow docker network prune -f --filter 'until=${DOCKER_PRUNE_UNTIL_HOURS}h'"
  if [[ "${PRUNE_DOCKER_VOLUMES}" == "1" ]]; then
    cleanup_step "docker volume prune (unused > ${DOCKER_PRUNE_UNTIL_HOURS}h)" prune_old_unused_volumes
  fi
fi

# Re-check free space and report status + delta
current_kb_after=$(avail_kb)
freed_kb=$(( current_kb_after - before_kb ))
log "Freed $(( freed_kb / 1024 / 1024 ))GB (from $(( before_kb / 1024 / 1024 ))GB to $(( current_kb_after / 1024 / 1024 ))GB) on $TARGET_PATH"

if (( current_kb_after >= threshold_kb )); then
  log "Cleanup successful: $(( current_kb_after / 1024 / 1024 ))GB >= ${THRESHOLD_GB}GB on $TARGET_PATH"
  exit 0
else
  log "Cleanup done but still low: $(( current_kb_after / 1024 / 1024 ))GB < ${THRESHOLD_GB}GB on $TARGET_PATH"
  exit 0
fi
