#!/usr/bin/env bash
set -Eeuo pipefail

# Installer for disk cleanup cron job
# - Installs cleanup script to /usr/local/sbin/disk-cleanup
# - Adds an hourly cron job by default that runs the cleanup
#
# Usage:
#   sudo bash scripts/setup-disk-cleanup-cron.sh [options]
#
# Options:
#   -t, --threshold-gb N            Set threshold in GB (default: 10)
#   -s, --schedule CRON_EXPR        Cron schedule (default: "0 * * * *")
#   -p, --path PATH                 Filesystem path to check (default: /)
#       --enable-docker-prune       Enable Docker prune (stopped containers/images/networks)
#       --docker-prune-hours N      Age threshold hours for Docker prune (default: 168)
#       --docker-prune-include-volumes  Also prune unused volumes older than threshold
#       --cleanup-script PATH       Source path of disk-cleanup script to install
#       --cron-only                 Do not copy script; only (re)install cron for existing binary
#       --uninstall                 Remove cron job and installed script
#   -h, --help                      Show help
#
# Extra env pass-through (set them in the environment before running this installer):
#   JOURNAL_RETAIN_DAYS JOURNAL_MAX_SIZE TMP_RETAIN_DAYS LOG_ARCHIVE_RETAIN_DAYS
#   TRUNCATE_DOCKER_LOGS DOCKER_LOG_MAX_MB INODE_LOW_PCT PROTECT_VOLUME_REGEX

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
  fi
}

print_help() {
  sed -n '2,200p' "$0" | awk '/^# Installer/{flag=1;next}/^require_root/{flag=0}flag{print substr($0,3)}'
}

append_env_if_set() {
  local var="$1"
  local val="${!var-}"
  if [[ -n "${val}" ]]; then
    ENV_PREFIX+=" ${var}=$(printf '%q' "${val}")"
  fi
}

install_cron() {
  local marker_path="$1"
  local cron_line="$2"

  local current
  current="$(crontab -l 2>/dev/null || true)"

  # Remove any existing lines referencing our cleanup script
  local filtered
  filtered="$(printf '%s\n' "$current" | grep -v -F "$marker_path" || true)"

  # Append the new cron line
  printf '%s\n%s\n' "$filtered" "$cron_line" | crontab -

  echo "Cron job installed/updated:"
  echo "  $cron_line"
}

uninstall_cron() {
  local marker_path="$1"
  local current
  current="$(crontab -l 2>/dev/null || true)"

  if [[ -z "$current" ]]; then
    echo "No crontab found; nothing to remove."
    return 0
  fi

  local filtered
  filtered="$(printf '%s\n' "$current" | grep -v -F "$marker_path" || true)"
  printf '%s\n' "$filtered" | crontab -
  echo "Removed cron entries referencing $marker_path"
}

main() {
  require_root

  local SCHEDULE="0 * * * *"
  local THRESHOLD_GB="10"
  local TARGET_PATH="/"
  local ENABLE_DOCKER_PRUNE=0
  local DOCKER_PRUNE_HOURS=168
  local DOCKER_PRUNE_INCLUDE_VOLUMES=0
  local CLEANUP_SRC_OVERRIDE=""
  local CRON_ONLY=0
  local ACTION="install"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--threshold-gb) THRESHOLD_GB="$2"; shift 2;;
      -s|--schedule) SCHEDULE="$2"; shift 2;;
      -p|--path) TARGET_PATH="$2"; shift 2;;
      --enable-docker-prune) ENABLE_DOCKER_PRUNE=1; shift;;
      --docker-prune-hours) DOCKER_PRUNE_HOURS="$2"; shift 2;;
      --docker-prune-include-volumes) DOCKER_PRUNE_INCLUDE_VOLUMES=1; shift;;
      --cleanup-script) CLEANUP_SRC_OVERRIDE="$2"; shift 2;;
      --cron-only) CRON_ONLY=1; shift;;
      --uninstall) ACTION="uninstall"; shift;;
      -h|--help) print_help; exit 0;;
      *) echo "Unknown option: $1" >&2; print_help; exit 1;;
    esac
  done

  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local SRC_CLEANUP
  if [[ -n "$CLEANUP_SRC_OVERRIDE" ]]; then
    SRC_CLEANUP="$CLEANUP_SRC_OVERRIDE"
  else
    SRC_CLEANUP="$SCRIPT_DIR/disk-cleanup.sh"
  fi
  local DEST_CLEANUP="/usr/local/sbin/disk-cleanup"

  if [[ "$ACTION" == "uninstall" ]]; then
    uninstall_cron "$DEST_CLEANUP"
    if [[ -f "$DEST_CLEANUP" ]]; then
      rm -f "$DEST_CLEANUP"
      echo "Removed $DEST_CLEANUP"
    fi
    echo "Uninstall complete."
    exit 0
  fi

  if [[ "$CRON_ONLY" -eq 0 ]]; then
    if [[ -f "$SRC_CLEANUP" ]]; then
      install -m 0755 "$SRC_CLEANUP" "$DEST_CLEANUP"
      echo "Installed cleanup script to $DEST_CLEANUP"
    else
      if [[ -x "$DEST_CLEANUP" ]]; then
        echo "Source not found ($SRC_CLEANUP). Using existing $DEST_CLEANUP (cron only)."
      else
        echo "Cleanup script not found and not installed: $SRC_CLEANUP" >&2
        echo "Provide --cleanup-script PATH or place disk-cleanup at $DEST_CLEANUP" >&2
        exit 1
      fi
    fi
  else
    if [[ ! -x "$DEST_CLEANUP" ]]; then
      echo "--cron-only specified but $DEST_CLEANUP not found/executable." >&2
      exit 1
    fi
  fi

  # Build env prefix for cron
  ENV_PREFIX="THRESHOLD_GB=${THRESHOLD_GB} TARGET_PATH=$(printf '%q' "${TARGET_PATH}")"

  if [[ "$ENABLE_DOCKER_PRUNE" -eq 1 ]]; then
    ENV_PREFIX+=" PRUNE_DOCKER=1 DOCKER_PRUNE_UNTIL_HOURS=${DOCKER_PRUNE_HOURS}"
    if [[ "$DOCKER_PRUNE_INCLUDE_VOLUMES" -eq 1 ]]; then
      ENV_PREFIX+=" PRUNE_DOCKER_VOLUMES=1"
    fi
  fi

  # Pass-through optional tunables if set in the environment
  append_env_if_set JOURNAL_RETAIN_DAYS
  append_env_if_set JOURNAL_MAX_SIZE
  append_env_if_set TMP_RETAIN_DAYS
  append_env_if_set LOG_ARCHIVE_RETAIN_DAYS
  append_env_if_set TRUNCATE_DOCKER_LOGS
  append_env_if_set DOCKER_LOG_MAX_MB
  append_env_if_set INODE_LOW_PCT
  append_env_if_set PROTECT_VOLUME_REGEX

  local LOGGER_BIN
  if command -v logger >/dev/null 2>&1; then
    LOGGER_BIN="$(command -v logger)"
  else
    LOGGER_BIN="/usr/bin/logger"
  fi

  # Redirect output to syslog to avoid local mail spools.
  local CRON_LINE
  CRON_LINE="${SCHEDULE} ${ENV_PREFIX} ${DEST_CLEANUP} 2>&1 | ${LOGGER_BIN} -t disk-cleanup"

  install_cron "$DEST_CLEANUP" "$CRON_LINE"

  # Helpful hints
  systemctl is-active cron >/dev/null 2>&1 && echo "cron service: active" || true
  systemctl is-active crond >/dev/null 2>&1 && echo "crond service: active" || true
}

main "$@"
