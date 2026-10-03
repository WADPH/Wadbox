#!/bin/bash
# homelab-backup.sh
# Config/data archive for a single server + optional off-site upload via rclone
# + optional reporting to a BackUpTrace-compatible HTTP endpoint.
#
# Quick start:
#   1. Edit the CONFIGURATION section below (or put overrides into
#      homelab-backup.conf next to the script -- see CONFIG_FILE).
#   2. Run once by hand as root:   sudo ./homelab-backup.sh
#   3. Schedule it, e.g. in root's crontab:
#        0 3 * * * /opt/homelab-backup/homelab-backup.sh >> /var/log/homelab-backup.log 2>&1
#
# Requirements: bash 4+, tar, gzip, dpkg (Debian/Ubuntu metadata).
# Optional:     rsync (faster, excludes are never read), rclone, curl.
#
# Exit code: 0 on success/warning, 1 if the archive or the upload failed.

set -e

############################################################################
# CONFIGURATION
############################################################################

# --- Backup ---------------------------------------------------------------

# Base name of the archive. The final file is "<BACKUP_NAME>-<DATE>.tar.gz",
# e.g. "my-server-2026-01-31_03-00.tar.gz".
# Allowed characters: letters, digits, dot, underscore, dash.
BACKUP_NAME="my-server"

# Where local archives are stored.
BACKUP_DIR="/mnt/backups/daily"

# How many local archives of THIS BACKUP_NAME to keep. 0 disables retention.
RETENTION_COUNT=3

# Warn if the archive is smaller than this (bytes). 0 disables the check.
# Tip: run the script once, look at the archive size, and set ~70-80% of it.
MIN_EXPECTED_SIZE=0

# Items to back up (files or directories, absolute paths).
BACKUP_ITEMS=(
    "/opt/myapp/docker-compose.yml"   # example: compose file of a service
    "/opt/myapp/.env"                 # example: its environment/secrets
    "/srv/myapp/data"                 # example: application data directory
    "/etc/network/interfaces"
    "/etc/fstab"
    "/etc/ssh"
    "/home/youruser/.bashrc"
    "/home/youruser/scripts"
    "/root/.config"
    "/var/spool/cron"
)

# Paths that must NEVER end up in the archive, even if they are listed in
# BACKUP_ITEMS or live inside a directory that is. Absolute paths, no wildcards.
#   - an exact match or a parent of a BACKUP_ITEMS entry -> the whole entry is skipped
#   - a path inside a BACKUP_ITEMS directory             -> only that sub-path is dropped
# Every exclusion is written to the log.
EXCLUDED_ITEMS=(
    # "/srv/myapp/data/cache"         # example: regenerable cache
    # "/srv/myapp/data/thumbnails"    # example: large, can be rebuilt
)

# --- rclone (off-site copy) -----------------------------------------------

# Set to true to upload BACKUP_DIR to a remote after the archive is created.
RCLONE_ENABLED=false

RCLONE_BIN="/usr/bin/rclone"

# Any configured rclone remote ("rclone config"): Google Drive, S3, B2, SFTP...
# Format: "<remote>:<path>", e.g. "gdrive:Backups/my-server/" or "s3:bucket/my-server/".
RCLONE_DEST="myremote:backups/my-server/"

# "sync"  -> remote mirrors BACKUP_DIR exactly (files removed locally are removed remotely)
# "copy"  -> only uploads new/changed files, never deletes on the remote
RCLONE_MODE="sync"

# Extra flags passed to rclone. --progress is noisy in cron logs; drop it if you like.
RCLONE_FLAGS=(--checksum)

# --- BackUpTrace (optional monitoring) ------------------------------------

# Set to true to send a JSON event per job to BACKUPTRACE_URL.
BACKUPTRACE_ENABLED=false

BACKUPTRACE_URL="http://backuptrace.example.lan/api/v1/backup-events"
BACKUPTRACE_API_KEY="CHANGE_ME"   # better: set it in homelab-backup.conf, not here
BACKUPTRACE_SOURCE_NAME="my-server"

# Job names as they appear on the dashboard. Keep them stable once in use,
# otherwise the dashboard will see them as brand-new jobs.
BACKUPTRACE_ARCHIVE_JOB="local-archive"
BACKUPTRACE_SYNC_JOB="offsite-sync"

# How long these jobs may go without a new backup before the dashboard treats
# them as stale. In DAYS; fractions allowed (e.g. 2.5). Sent per event as
# `stale_after_hours`, so each source is judged against its own schedule.
# Both jobs share this value because they run in the same invocation; if their
# schedules ever diverge, pass a different value as the 7th argument to
# report_backuptrace for that one call.
STALE_AFTER_DAYS=2

# --- Optional external config ---------------------------------------------

# If this file exists, it is sourced AFTER the defaults above, so any variable
# (arrays included) can be overridden there. Default: same name as the script
# with a .conf extension, in the same directory. Keep it out of git.
CONFIG_FILE="${CONFIG_FILE:-$(dirname "$(readlink -f "$0")")/$(basename "$0" .sh).conf}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

############################################################################
# HELPERS
############################################################################

log()  { echo "[$(date '+%F %T')] $*"; }
err()  { echo "[$(date '+%F %T')] ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

# Accepts true/yes/1/on (case-insensitive) as "enabled".
is_true() {
    case "${1,,}" in
        true|yes|1|on) return 0 ;;
        *)             return 1 ;;
    esac
}

# Strip trailing slashes so "/etc/ssh/" and "/etc/ssh" compare equal.
normalize_path() {
    local p="$1"
    while [[ "$p" == */ && "$p" != "/" ]]; do
        p="${p%/}"
    done
    printf '%s' "$p"
}

# Prints the exclude rule that covers the given item (exact match or parent)
# and returns 0; returns 1 if the item is not excluded.
excluded_by() {
    local item="$1" ex
    for ex in "${EXCLUDED_NORM[@]}"; do
        if [[ "$item" == "$ex" || "$item" == "$ex"/* ]]; then
            printf '%s' "$ex"
            return 0
        fi
    done
    return 1
}

# Make a string safe to drop into a JSON literal. rclone errors and file paths
# are free text -- a backslash or a stray control character would otherwise
# produce a body the API rejects, and the event would be lost.
json_escape() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | tr '\n\r\t' '   ' \
        | tr -d '\000-\037'
}

# Copy one item into the staging dir, preserving its full path.
# Remaining arguments are sub-paths of the item that must be left out.
copy_item() {
    local item="$1"; shift
    local ex rc=0

    if [ "$HAVE_RSYNC" = true ]; then
        # rsync skips excluded sub-paths without ever reading them, which matters
        # for big directories (thumbnails, caches). With --relative the transfer
        # root is "/", so absolute exclude patterns are anchored correctly.
        local args=(-a --relative)
        for ex in "$@"; do
            args+=(--exclude="$ex")
        done
        rsync "${args[@]}" "$item" "$TMPDIR/" || rc=$?
    else
        local dest="$TMPDIR$item"
        mkdir -p "$(dirname "$dest")"
        cp -a "$item" "$dest" || rc=$?
    fi

    # Safety net (and the only mechanism in the cp fallback): make sure no
    # excluded path survived in the staging dir.
    for ex in "$@"; do
        rm -rf -- "${TMPDIR:?}$ex"
    done

    return "$rc"
}

# Report an event to BackUpTrace. No-op when the integration is disabled.
# Never lets a curl failure kill the script.
report_backuptrace() {
    is_true "$BACKUPTRACE_ENABLED" || return 0

    local job_name="$1"
    local status="$2"
    local file_name="$3"
    local file_size="$4"
    local duration="$5"
    local extra_json="$6"   # must be a valid JSON object string, e.g. '{"exit_code":1}'
    local stale_after="${7:-$STALE_AFTER_HOURS}"
    local http_code

    # --max-time keeps a hung or unreachable API from stalling the backup job
    # itself, which runs from cron.
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 15 \
        -X POST "$BACKUPTRACE_URL" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: $BACKUPTRACE_API_KEY" \
        -d "{
            \"source_name\": \"$(json_escape "$BACKUPTRACE_SOURCE_NAME")\",
            \"job_name\": \"$(json_escape "$job_name")\",
            \"status\": \"$status\",
            \"file_name\": \"$(json_escape "$file_name")\",
            \"file_size_bytes\": $file_size,
            \"duration_seconds\": $duration,
            \"stale_after_hours\": $stale_after,
            \"extra\": $extra_json
        }") || http_code="000"

    # If BackUpTrace itself is unreachable, log it but don't fail the backup.
    if [[ "$http_code" == 2* ]]; then
        log "BackUpTrace [$job_name]: reported '$status' (HTTP $http_code)"
    else
        err "BackUpTrace [$job_name]: report failed (HTTP $http_code) -- backup itself is unaffected"
    fi
}

############################################################################
# VALIDATION
############################################################################

[[ "$BACKUP_NAME" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "BACKUP_NAME may only contain letters, digits, '.', '_' and '-' (got '$BACKUP_NAME')"
[ -n "$BACKUP_DIR" ] || die "BACKUP_DIR is empty"
[[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] \
    || die "RETENTION_COUNT must be a non-negative integer (got '$RETENTION_COUNT')"
[[ "$MIN_EXPECTED_SIZE" =~ ^[0-9]+$ ]] \
    || die "MIN_EXPECTED_SIZE must be a non-negative integer (got '$MIN_EXPECTED_SIZE')"
[ "${#BACKUP_ITEMS[@]}" -gt 0 ] || die "BACKUP_ITEMS is empty, nothing to back up"

if is_true "$RCLONE_ENABLED"; then
    [ -x "$RCLONE_BIN" ] || die "RCLONE_ENABLED is on but '$RCLONE_BIN' is not executable"
    [ -n "$RCLONE_DEST" ] || die "RCLONE_ENABLED is on but RCLONE_DEST is empty"
    [[ "$RCLONE_MODE" == "sync" || "$RCLONE_MODE" == "copy" ]] \
        || die "RCLONE_MODE must be 'sync' or 'copy' (got '$RCLONE_MODE')"
fi

if is_true "$BACKUPTRACE_ENABLED"; then
    command -v curl >/dev/null || die "BACKUPTRACE_ENABLED is on but curl is not installed"
    [ -n "$BACKUPTRACE_URL" ] || die "BACKUPTRACE_ENABLED is on but BACKUPTRACE_URL is empty"
    [[ -n "$BACKUPTRACE_API_KEY" && "$BACKUPTRACE_API_KEY" != "CHANGE_ME" ]] \
        || die "BACKUPTRACE_ENABLED is on but BACKUPTRACE_API_KEY is not set"
    awk -v v="$STALE_AFTER_DAYS" 'BEGIN { exit !(v + 0 > 0) }' \
        || die "STALE_AFTER_DAYS must be a positive number of days (got '$STALE_AFTER_DAYS')"
    # The API takes hours; the config uses days because that's how schedules are discussed.
    STALE_AFTER_HOURS=$(awk -v d="$STALE_AFTER_DAYS" 'BEGIN { printf "%.6g", d * 24 }')
fi

# Normalized exclude list, used for all comparisons below.
EXCLUDED_NORM=()
for ex in "${EXCLUDED_ITEMS[@]}"; do
    [ -n "$ex" ] || continue
    [[ "$ex" == /* ]] || die "EXCLUDED_ITEMS entries must be absolute paths (got '$ex')"
    EXCLUDED_NORM+=("$(normalize_path "$ex")")
done

if command -v rsync >/dev/null; then
    HAVE_RSYNC=true
else
    HAVE_RSYNC=false
fi

# Human-readable remote name for logs, e.g. "gdrive" from "gdrive:Backups/".
RCLONE_REMOTE_LABEL="${RCLONE_DEST%%:*}"

############################################################################
# MAIN
############################################################################

EXIT_CODE=0
DATE=$(date +%F_%H-%M)
ARCHIVE_NAME="${BACKUP_NAME}-${DATE}.tar.gz"
ARCHIVE="$BACKUP_DIR/$ARCHIVE_NAME"
HOST=$(hostname)

mkdir -p "$BACKUP_DIR"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT   # staging dir is removed even if the script dies

log "Starting backup '$BACKUP_NAME' -> $ARCHIVE"
is_true "$RCLONE_ENABLED" \
    && log "Off-site upload: rclone $RCLONE_MODE -> $RCLONE_DEST" \
    || log "Off-site upload: disabled"
is_true "$BACKUPTRACE_ENABLED" \
    && log "BackUpTrace: enabled (source '$BACKUPTRACE_SOURCE_NAME', stale after ${STALE_AFTER_DAYS}d / ${STALE_AFTER_HOURS}h)" \
    || log "BackUpTrace: disabled"
[ "$HAVE_RSYNC" = true ] || log "rsync not found, falling back to cp (excluded sub-paths are copied, then removed)"

# Warn about exclude rules that don't touch anything in BACKUP_ITEMS (likely typos).
for ex in "${EXCLUDED_NORM[@]}"; do
    matched=false
    for raw in "${BACKUP_ITEMS[@]}"; do
        item=$(normalize_path "$raw")
        if [[ "$item" == "$ex" || "$item" == "$ex"/* || "$ex" == "$item"/* ]]; then
            matched=true
            break
        fi
    done
    [ "$matched" = true ] || log "Note: exclude rule '$ex' does not match any BACKUP_ITEMS entry"
done

START_TIME=$(date +%s)
COUNT_COPIED=0
COUNT_SKIPPED=0
COUNT_EXCLUDED=0
COUNT_ERRORS=0

# --- Stage files, preserving the full path structure ---
for RAW_ITEM in "${BACKUP_ITEMS[@]}"; do
    ITEM=$(normalize_path "$RAW_ITEM")

    if RULE=$(excluded_by "$ITEM"); then
        log "Excluded: $ITEM (rule: $RULE)"
        COUNT_EXCLUDED=$((COUNT_EXCLUDED + 1))
        continue
    fi

    if [ ! -e "$ITEM" ]; then
        log "Skipped: $ITEM (not found)"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
        continue
    fi

    # Exclude rules that point inside this item.
    NESTED=()
    for ex in "${EXCLUDED_NORM[@]}"; do
        [[ "$ex" == "$ITEM"/* ]] && NESTED+=("$ex")
    done

    log "Backing up $ITEM"
    for ex in "${NESTED[@]}"; do
        log "  Excluded inside $ITEM: $ex"
        COUNT_EXCLUDED=$((COUNT_EXCLUDED + 1))
    done

    if copy_item "$ITEM" "${NESTED[@]}"; then
        COUNT_COPIED=$((COUNT_COPIED + 1))
    else
        err "Failed to copy $ITEM (archive will be marked as warning)"
        COUNT_ERRORS=$((COUNT_ERRORS + 1))
    fi
done

# --- System metadata (useful for rebuilding / debugging) ---
log "Saving package list and system info..."
mkdir -p "$TMPDIR/meta"
if command -v dpkg >/dev/null; then
    dpkg --get-selections > "$TMPDIR/meta/packages.list"
fi
uname -a > "$TMPDIR/meta/uname.txt"
lsblk > "$TMPDIR/meta/lsblk.txt" 2>/dev/null || true

# --- Create archive ---
ARCHIVE_STATUS="success"
if ! tar -czf "$ARCHIVE" -C "$TMPDIR" .; then
    ARCHIVE_STATUS="failed"
    rm -f "$ARCHIVE"   # don't leave a half-written archive for retention/rclone to pick up
fi

rm -rf "$TMPDIR"

ARCHIVE_DURATION=$(( $(date +%s) - START_TIME ))
ARCHIVE_EXTRA="{\"host\": \"$(json_escape "$HOST")\", \"items_total\": ${#BACKUP_ITEMS[@]}, \"items_copied\": $COUNT_COPIED, \"items_skipped\": $COUNT_SKIPPED, \"items_excluded\": $COUNT_EXCLUDED, \"copy_errors\": $COUNT_ERRORS"

if [ "$ARCHIVE_STATUS" = "success" ] && [ -f "$ARCHIVE" ]; then
    ARCHIVE_SIZE=$(stat -c%s "$ARCHIVE")
    log "Archive created: $ARCHIVE ($ARCHIVE_SIZE bytes)"
    log "Items: $COUNT_COPIED copied, $COUNT_SKIPPED not found, $COUNT_EXCLUDED excluded, $COUNT_ERRORS errors"

    if [ "$COUNT_ERRORS" -gt 0 ]; then
        ARCHIVE_STATUS="warning"
    fi

    if [ "$MIN_EXPECTED_SIZE" -gt 0 ] && [ "$ARCHIVE_SIZE" -lt "$MIN_EXPECTED_SIZE" ]; then
        ARCHIVE_STATUS="warning"
        log "WARNING: archive smaller than expected ($ARCHIVE_SIZE < $MIN_EXPECTED_SIZE bytes)"
    fi

    report_backuptrace "$BACKUPTRACE_ARCHIVE_JOB" "$ARCHIVE_STATUS" "$ARCHIVE_NAME" "$ARCHIVE_SIZE" "$ARCHIVE_DURATION" \
        "$ARCHIVE_EXTRA}"
else
    ARCHIVE_STATUS="failed"
    EXIT_CODE=1
    err "Backup FAILED: tar step did not complete"
    report_backuptrace "$BACKUPTRACE_ARCHIVE_JOB" "failed" "$ARCHIVE_NAME" "0" "$ARCHIVE_DURATION" \
        "$ARCHIVE_EXTRA, \"reason\": \"tar_failed\"}"
fi

# --- Retention: keep the last N archives of THIS backup name only ---
# The strict date glob prevents e.g. "server" from also matching "server-old-*".
if [ "$RETENTION_COUNT" -gt 0 ]; then
    DATE_GLOB='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]'
    # shellcheck disable=SC2086
    ls -1t -- "$BACKUP_DIR/$BACKUP_NAME"-$DATE_GLOB.tar.gz 2>/dev/null \
        | tail -n +$((RETENTION_COUNT + 1)) \
        | xargs -r -d '\n' rm -f --
    log "Retention complete (kept last $RETENTION_COUNT '$BACKUP_NAME' archives)"
else
    log "Retention disabled (RETENTION_COUNT=0)"
fi

# --- Off-site upload via rclone ---
if ! is_true "$RCLONE_ENABLED"; then
    log "Skipping rclone upload: RCLONE_ENABLED is off"
elif [ "$ARCHIVE_STATUS" = "failed" ]; then
    log "Skipping rclone upload: local archive step failed"
    report_backuptrace "$BACKUPTRACE_SYNC_JOB" "failed" "" "0" "0" \
        "{\"host\": \"$(json_escape "$HOST")\", \"reason\": \"skipped_due_to_archive_failure\"}"
else
    log "Starting rclone $RCLONE_MODE to $RCLONE_REMOTE_LABEL ($RCLONE_DEST)..."
    SYNC_START=$(date +%s)
    RCLONE_LOG=$(mktemp)

    if "$RCLONE_BIN" "$RCLONE_MODE" "$BACKUP_DIR" "$RCLONE_DEST" \
        "${RCLONE_FLAGS[@]}" > "$RCLONE_LOG" 2>&1; then
        SYNC_STATUS="success"
    else
        SYNC_STATUS="failed"
    fi

    SYNC_DURATION=$(( $(date +%s) - SYNC_START ))
    # Size reported is this run's archive, which is what the event is about.
    SYNCED_SIZE=$([ -f "$ARCHIVE" ] && stat -c%s "$ARCHIVE" || echo 0)
    SYNC_EXTRA="{\"host\": \"$(json_escape "$HOST")\", \"remote\": \"$(json_escape "$RCLONE_DEST")\", \"mode\": \"$RCLONE_MODE\""

    if [ "$SYNC_STATUS" = "success" ]; then
        log "rclone $RCLONE_MODE completed"
        report_backuptrace "$BACKUPTRACE_SYNC_JOB" "success" "$ARCHIVE_NAME" "$SYNCED_SIZE" "$SYNC_DURATION" \
            "$SYNC_EXTRA}"
    else
        EXIT_CODE=1
        err "rclone $RCLONE_MODE FAILED, last lines of its output:"
        tail -n 20 "$RCLONE_LOG" >&2
        RCLONE_ERROR=$(json_escape "$(tail -c 500 "$RCLONE_LOG")")
        report_backuptrace "$BACKUPTRACE_SYNC_JOB" "failed" "$ARCHIVE_NAME" "$SYNCED_SIZE" "$SYNC_DURATION" \
            "$SYNC_EXTRA, \"error\": \"$RCLONE_ERROR\"}"
    fi

    rm -f "$RCLONE_LOG"
fi

log "All done (exit code $EXIT_CODE)."
exit "$EXIT_CODE"
