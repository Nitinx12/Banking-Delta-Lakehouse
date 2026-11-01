#!/usr/bin/env bash

# ============================================================================
# LOG MONITOR & CLEANUP  (v2)
# ============================================================================
# Location: scripts/ (two levels below the project root; PROJECT_ROOT
#           below resolves to the grandparent of this file's directory)
#
# Rules:
#   1. Files older than MAX_AGE_DAYS are flagged for deletion.
#   2. Files larger than MAX_SIZE_MB are flagged for deletion.
#   3. The most recently modified log file is ALWAYS preserved.
#   4. Every deletion prints a notification.
#
# Usage:
#   ./monitor_logs.sh                 Show a summary report (default, read-only)
#   ./monitor_logs.sh summary         Same as above
#   ./monitor_logs.sh clean           Delete flagged logs (asks for confirmation)
#   ./monitor_logs.sh clean --dry-run Preview what 'clean' would delete (deletes nothing)
#   ./monitor_logs.sh clean -y        Skip the confirmation prompt
#   ./monitor_logs.sh -h | --help     Show this help
#
# Expected structure:
#
# project/
# ├── logs/
# │   ├── app.log
# │   ├── database.log
# │   └── ...
# └── monitor_logs.sh
#
# ============================================================================

set -uo pipefail
# Note: deliberately not using `set -e` here. This script deletes files in a
# loop and prints a summary at the end; one bad/unreadable file should not
# silently kill the whole run before the summary is printed.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-7}"   # override with: MAX_AGE_DAYS=14 ./monitor_logs.sh ...
MAX_SIZE_MB="${MAX_SIZE_MB:-5}"     # override with: MAX_SIZE_MB=10 ./monitor_logs.sh ...

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------

info()   { printf '[INFO] %s\n' "$1"; }
notify() { printf '[NOTIFICATION] %s\n' "$1"; }
warn()   { printf '[WARNING] %s\n' "$1" >&2; }
err()    { printf '[ERROR] %s\n' "$1" >&2; }

usage() {
    cat <<EOF
Log Monitor & Cleanup

Usage:
  $(basename "$0")                 Show a summary report of all logs (default, read-only)
  $(basename "$0") summary         Same as above
  $(basename "$0") clean           Delete logs older than ${MAX_AGE_DAYS}d or larger than ${MAX_SIZE_MB}MB
                                    (asks for confirmation; the newest log is always kept)
  $(basename "$0") clean --dry-run Preview what 'clean' would delete, deletes nothing
  $(basename "$0") clean -y        Skip the confirmation prompt
  $(basename "$0") -h | --help     Show this help

Log directory : ${LOG_DIR}
Age limit     : ${MAX_AGE_DAYS} days
Size limit    : ${MAX_SIZE_MB} MB
EOF
}

# ----------------------------------------------------------------------------
# Portable file stats (Linux/GNU + macOS/BSD)
# ----------------------------------------------------------------------------

file_mtime_epoch() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null; }
file_size_bytes()  { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null; }

# Nanosecond-precision mtime as a plain integer string, for picking the
# TRUE latest file even when several logs share the same whole second
# (GNU stat only; falls back to second precision on macOS/BSD stat).
file_mtime_ns() {
    local out
    if out=$(stat -c '%.9Y' "$1" 2>/dev/null); then
        printf '%s' "${out/./}"
    elif out=$(stat -f '%m' "$1" 2>/dev/null); then
        printf '%s000000000' "$out"
    else
        return 1
    fi
}

# Apparent/logical file size in whole MB (NOT `du`, which reports disk usage
# and under-reports sparse files).
file_size_mb() {
    local bytes
    bytes=$(file_size_bytes "$1") || { echo 0; return 1; }
    echo $(( bytes / 1024 / 1024 ))
}

file_age_days() {
    local mtime now
    mtime=$(file_mtime_epoch "$1") || { echo 0; return 1; }
    now=$(date +%s)
    echo $(( (now - mtime) / 86400 ))
}

find_latest_log() {
    local latest="" latest_ns="" f mtime_ns
    while IFS= read -r -d '' f; do
        mtime_ns=$(file_mtime_ns "$f") || continue
        if [[ -z "$latest" ]] || (( 10#$mtime_ns > 10#$latest_ns )); then
            latest_ns=$mtime_ns
            latest="$f"
        fi
    done < <(find "$LOG_DIR" -type f -print0 2>/dev/null)
    printf '%s' "$latest"
}

require_log_dir() {
    if [[ ! -d "$LOG_DIR" ]]; then
        warn "Log directory does not exist: $LOG_DIR"
        exit 0
    fi
}

# Classifies one file. Prints: "<size_mb> <age_days> <status>"
# STATUS is one of: LATEST, OLD+LARGE, OLD, LARGE, OK
classify_file() {
    local f="$1" latest="$2" size age status is_old=0 is_large=0
    size=$(file_size_mb "$f")
    age=$(file_age_days "$f")
    if [[ "$f" == "$latest" ]]; then
        status="LATEST"
    else
        (( age  > MAX_AGE_DAYS  )) && is_old=1
        (( size > MAX_SIZE_MB   )) && is_large=1
        if   (( is_old && is_large )); then status="OLD+LARGE"
        elif (( is_old ));            then status="OLD"
        elif (( is_large ));          then status="LARGE"
        else                                status="OK"
        fi
    fi
    printf '%s %s %s' "$size" "$age" "$status"
}

# ----------------------------------------------------------------------------
# summary: read-only report of every log file
# ----------------------------------------------------------------------------

cmd_summary() {
    require_log_dir
    local latest
    latest=$(find_latest_log)

    if [[ -z "$latest" ]]; then
        info "No log files found in $LOG_DIR"
        return 0
    fi

    printf '\n%-40s %10s %10s %-12s\n' "FILE" "SIZE(MB)" "AGE(days)" "STATUS"
    printf '%s\n' "------------------------------------------------------------------------------"

    local files_count=0 total_mb=0 n_old=0 n_large=0 n_oldlarge=0
    local f size age status

    while IFS= read -r -d '' f; do
        read -r size age status <<< "$(classify_file "$f" "$latest")"
        printf '%-40s %10s %10s %-12s\n' "$(basename "$f")" "$size" "$age" "$status"
        files_count=$((files_count + 1))
        total_mb=$((total_mb + size))
        case "$status" in
            OLD)       n_old=$((n_old + 1)) ;;
            LARGE)     n_large=$((n_large + 1)) ;;
            OLD+LARGE) n_oldlarge=$((n_oldlarge + 1)) ;;
        esac
    done < <(find "$LOG_DIR" -type f -print0 2>/dev/null)

    local would_delete=$((n_old + n_large + n_oldlarge))

    echo
    echo "============================================================"
    echo "                    LOG SUMMARY"
    echo "============================================================"
    echo "Log directory        : $LOG_DIR"
    echo "Total log files      : $files_count"
    echo "Total size (approx)  : ${total_mb} MB"
    echo "Latest (preserved)   : $(basename "$latest")"
    echo "Flagged - old only   : $n_old"
    echo "Flagged - large only : $n_large"
    echo "Flagged - old+large  : $n_oldlarge"
    echo "Would be deleted     : $would_delete"
    echo "============================================================"

    if (( would_delete > 0 )); then
        info "Run '$(basename "$0") clean' to remove flagged logs, or 'clean --dry-run' to preview."
    else
        info "Nothing needs cleanup."
    fi
}

# ----------------------------------------------------------------------------
# clean: actually delete flagged logs (with confirmation / dry-run)
# ----------------------------------------------------------------------------

cmd_clean() {
    require_log_dir

    local dry_run=0 assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            -y|--yes)  assume_yes=1 ;;
            *) err "Unknown option for 'clean': $arg"; usage; exit 1 ;;
        esac
    done

    local latest
    latest=$(find_latest_log)
    if [[ -z "$latest" ]]; then
        info "No log files found in $LOG_DIR"
        return 0
    fi

    info "Log directory : $LOG_DIR"
    info "Age limit     : ${MAX_AGE_DAYS} days"
    info "Size limit    : ${MAX_SIZE_MB} MB"
    info "Latest log (always kept): $(basename "$latest")"

    # Decide what to delete BEFORE deleting anything.
    local -a to_delete=() reasons=()
    local f size age status

    while IFS= read -r -d '' f; do
        [[ "$f" == "$latest" ]] && continue
        read -r size age status <<< "$(classify_file "$f" "$latest")"
        case "$status" in
            OLD)       to_delete+=("$f"); reasons+=("older than ${MAX_AGE_DAYS} days") ;;
            LARGE)     to_delete+=("$f"); reasons+=("${size} MB") ;;
            OLD+LARGE) to_delete+=("$f"); reasons+=("older than ${MAX_AGE_DAYS} days, ${size} MB") ;;
        esac
    done < <(find "$LOG_DIR" -type f -print0 2>/dev/null)

    if (( ${#to_delete[@]} == 0 )); then
        echo
        info "Nothing to delete."
        return 0
    fi

    echo
    info "${#to_delete[@]} file(s) will be deleted:"
    local i
    for i in "${!to_delete[@]}"; do
        echo "  - $(basename "${to_delete[$i]}") (${reasons[$i]})"
    done

    if (( dry_run )); then
        echo
        info "Dry run - no files were deleted."
        return 0
    fi

    if (( ! assume_yes )); then
        local confirm=""
        read -r -p $'\nProceed with deletion? [y/N] ' confirm
        case "$confirm" in
            y|Y|yes|YES) ;;
            *) info "Aborted. No files were deleted."; return 0 ;;
        esac
    fi

    local deleted_count=0 failed_count=0
    for f in "${to_delete[@]}"; do
        if rm -f "$f" 2>/dev/null; then
            notify "Deleted: $(basename "$f")"
            deleted_count=$((deleted_count + 1))
        else
            warn "Could not delete: $f"
            failed_count=$((failed_count + 1))
        fi
    done

    # Clean up now-empty subdirectories, but never the logs dir itself.
    find "$LOG_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

    echo
    echo "============================================================"
    echo "                 LOG CLEANUP SUMMARY"
    echo "============================================================"
    echo "Log directory        : $LOG_DIR"
    echo "Files deleted        : $deleted_count"
    if (( failed_count > 0 )); then
        echo "Failed to delete     : $failed_count"
    fi
    echo "Latest log preserved : $(basename "$latest")"
    echo "============================================================"
}

# ----------------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------------

main() {
    local cmd="${1:-summary}"
    case "$cmd" in
        summary|"") cmd_summary ;;
        clean)      shift; cmd_clean "$@" ;;
        -h|--help|help) usage ;;
        *) err "Unknown command: $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
