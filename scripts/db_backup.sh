#!/usr/bin/env bash
# =============================================================================
# Dynamic Database Backup (PostgreSQL / MySQL / MongoDB)
# =============================================================================
# Location: scripts/db_backup.sh
#
# Logical backups driven entirely by .env. It adapts instead of assuming:
#
#   * finds .env itself (--env-file, $PWD, project root) and parses it safely
#     (never `source`s it); real environment variables override .env values
#   * pick engines per run: --db postgres | mysql | mongo | all | a,b
#     (default: postgres, or BACKUP_DBS from .env / the environment)
#   * relative backup paths resolve against the project root, so cron can
#     run it from any directory
#   * writes to <name>.partial, verifies it, then renames - a failed or
#     interrupted dump never leaves a truncated file that looks valid
#   * gzip by default (--no-compress to disable); dumps are chmod 600
#   * retention is configurable and only runs after a successful backup
#   * missing client tools: skipped with a warning in `all` mode, a hard error
#     when you asked for that engine explicitly
#   * passwords never appear in `ps` (PGPASSWORD / MYSQL_PWD per command)
#
# Usage:
#   ./db_backup.sh                          PostgreSQL (or BACKUP_DBS)
#   ./db_backup.sh --db all                 every configured engine
#   ./db_backup.sh --db postgres,mongo
#   ./db_backup.sh --no-compress --retention 14 --dir /mnt/backups
#   ./db_backup.sh --dry-run                show what would happen, change nothing
#   DB_BACKUP_DIR=/tmp/backups ./db_backup.sh
#
# Settings (CLI flag > environment / .env > default):
#   BACKUP_DBS=postgres        DB_BACKUP_DIR=backups      (per-engine subfolders)
#   BACKUP_RETENTION_DAYS=7    (0 = keep everything)      BACKUP_COMPRESS=true
#
# Restore:
#   postgres : gunzip -c FILE.sql.gz | psql -h HOST -U USER -d DB
#   mysql    : gunzip -c FILE.sql.gz | mysql -h HOST -u USER -p DB
#   mongo    : mongorestore --uri "$MONGO_URI" --archive=FILE.archive.gz --gzip
#
# Exit code: 0 = all requested backups succeeded, 1 = at least one failed
# =============================================================================

set -euo pipefail
umask 077   # dumps contain banking data: owner-only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_ENGINES="postgres mysql mongo"

CLI_DBS=""; CLI_DIR=""; CLI_RETENTION=""; CLI_COMPRESS=""
DRY_RUN=0
ENV_FILE="${ENV_FILE:-}"
MSG=""; BAD=""; CURRENT_PARTIAL=""
RESULTS=""; OK=0; FAILED=0; SKIPPED=0

usage() {
    cat <<'EOF'
Usage: db_backup.sh [options]
  --db LIST          postgres | mysql | mongo | all | comma list (default: postgres)
  --dir PATH         backup root (default: backups); engines get subfolders
  --retention DAYS   delete backups older than DAYS (default 7, 0 = keep all)
  --compress         gzip the dump (default)
  --no-compress      write plain files
  --dry-run          print the plan, run nothing
  --env-file PATH    use this .env (default: auto-detect)
  -h, --help         show this help
EOF
}

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARNING] %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }
die()  { err "$*"; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db)          [[ $# -ge 2 ]] || die "--db needs a value";        CLI_DBS="$2"; shift 2 ;;
        --dir)         [[ $# -ge 2 ]] || die "--dir needs a value";       CLI_DIR="$2"; shift 2 ;;
        --retention)   [[ $# -ge 2 ]] || die "--retention needs a value"; CLI_RETENTION="$2"; shift 2 ;;
        --env-file)    [[ $# -ge 2 ]] || die "--env-file needs a value";  ENV_FILE="$2"; shift 2 ;;
        --compress)    CLI_COMPRESS="true"; shift ;;
        --no-compress) CLI_COMPRESS="false"; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage >&2; die "Unknown option: $1" ;;
    esac
done

# --- .env discovery + safe loader ---------------------------------------------
ENV_RE='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
DQ_RE='^"(.*)"[[:space:]]*$'
SQ_RE="^'(.*)'[[:space:]]*\$"
PH_RE='<[^>]*>'

find_env_file() {
    local c
    if [[ -n "$ENV_FILE" ]]; then
        if [[ -f "$ENV_FILE" ]]; then printf '%s\n' "$ENV_FILE"; return 0; fi
        return 1
    fi
    for c in "$PWD/.env" "$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env"; do
        if [[ -f "$c" ]]; then
            (cd "$(dirname "$c")" && printf '%s/.env\n' "$PWD")
            return 0
        fi
    done
    return 1
}

load_env_file() {   # KEY=VALUE only; real environment variables win over the file
    local file="$1" line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ $ENV_RE ]]; then
            key="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[3]}"
            if   [[ "$val" =~ $DQ_RE ]]; then val="${BASH_REMATCH[1]}"
            elif [[ "$val" =~ $SQ_RE ]]; then val="${BASH_REMATCH[1]}"
            fi
            if [[ -z "${!key+x}" ]]; then export "$key=$val"; fi
        fi
    done < "$file"
}

if ENV_PATH="$(find_env_file)"; then
    load_env_file "$ENV_PATH"
    PROJECT_ROOT="$(dirname "$ENV_PATH")"
else
    err ".env file not found (looked in: $PWD, $SCRIPT_DIR/.., $SCRIPT_DIR)."
    err "Run setup_env.sh first, or pass --env-file PATH."
    exit 1
fi

# --- resolve settings (CLI > env/.env > default) --------------------------------
DBS="${CLI_DBS:-${BACKUP_DBS:-postgres}}"
RETENTION="${CLI_RETENTION:-${BACKUP_RETENTION_DAYS:-7}}"
COMPRESS="${CLI_COMPRESS:-${BACKUP_COMPRESS:-true}}"
BASE="${CLI_DIR:-${DB_BACKUP_DIR:-backups}}"
[[ "$BASE" == /* ]] || BASE="$PROJECT_ROOT/$BASE"
TS="$(date +%Y%m%d_%H%M%S)"

[[ "$RETENTION" =~ ^[0-9]+$ ]] || die "Retention must be a whole number of days (got '$RETENTION')."
case "$(printf '%s' "$COMPRESS" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y) COMPRESS=true ;;
    false|0|no|n) COMPRESS=false ;;
    *) die "BACKUP_COMPRESS must be true or false (got '$COMPRESS')." ;;
esac

AUTO=0
if [[ "$DBS" == "all" ]]; then AUTO=1; ENGINES="$ALL_ENGINES"; else ENGINES="${DBS//,/ }"; fi
for e in $ENGINES; do
    [[ " $ALL_ENGINES " == *" $e "* ]] || die "Unknown engine '$e' (choose from: $ALL_ENGINES, all)."
done

# --- helpers ------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

placeholder_in() {
    local v
    for v in "$@"; do
        if [[ "${!v:-}" =~ $PH_RE ]]; then BAD="$v"; return 0; fi
    done
    return 1
}

any_set() {
    local v
    for v in "$@"; do
        if [[ -n "${!v:-}" ]]; then return 0; fi
    done
    return 1
}

human_size() { du -h "$1" 2>/dev/null | cut -f1; }

cleanup() {
    if [[ -n "$CURRENT_PARTIAL" && -e "$CURRENT_PARTIAL" ]]; then rm -f "$CURRENT_PARTIAL"; fi
}
trap cleanup EXIT

verify_file() {
    [[ -s "$1" ]] || return 1
    if [[ "$1" == *.gz ]]; then gzip -t "$1" 2>/dev/null || return 1; fi
    return 0
}

prune_old() {   # prune_old <dir> <name>
    local dir="$1" name="$2" f
    if (( RETENTION == 0 )); then info "Retention disabled (--retention 0); keeping all backups."; return 0; fi
    info "Pruning $name backups older than ${RETENTION} days in $dir"
    if (( DRY_RUN )); then return 0; fi
    while IFS= read -r f; do
        [[ -n "$f" ]] && info "Deleted old backup: $f"
    done < <(find "$dir" -maxdepth 1 -type f -name "${name}_[0-9]*" -mtime +"$RETENTION" -print -delete)
}

# --- engines --------------------------------------------------------------------------
# Each backup_* sets MSG + OUT_FILE and returns: 0 = ok, 1 = failed, 3 = cannot run (not configured / tool missing)
OUT_FILE=""

backup_postgres() {
    local name="${PG_DB:-banking_warehouse}" host="${PG_HOST:-localhost}" port="${PG_PORT:-5432}" user="${PG_USER:-postgres}"
    local dir="$BASE/postgres" ext="sql" tool_args
    if ! any_set PG_HOST PG_DB PG_USER; then MSG="no PG_* settings in .env"; return 3; fi
    if placeholder_in PG_HOST PG_PORT PG_USER PG_PASS PG_DB; then MSG="$BAD is still a <placeholder>"; return 3; fi
    if ! have pg_dump; then MSG="pg_dump is not installed"; return 3; fi
    [[ "$COMPRESS" == true ]] && ext="sql.gz"
    OUT_FILE="$dir/${name}_${TS}.$ext"
    tool_args=(pg_dump -h "$host" -p "$port" -U "$user" -w -Fp "$name")

    info "PostgreSQL: $name@$host:$port -> $OUT_FILE"
    if (( DRY_RUN )); then info "[dry-run] ${tool_args[*]}"; return 0; fi
    mkdir -p "$dir"; CURRENT_PARTIAL="$OUT_FILE.partial"
    if [[ "$COMPRESS" == true ]]; then
        env PGPASSWORD="${PG_PASS:-}" "${tool_args[@]}" | gzip > "$CURRENT_PARTIAL" || { MSG="pg_dump failed"; return 1; }
    else
        env PGPASSWORD="${PG_PASS:-}" "${tool_args[@]}" > "$CURRENT_PARTIAL" || { MSG="pg_dump failed"; return 1; }
    fi
    finalize_file "$CURRENT_PARTIAL" "$OUT_FILE"
}

backup_mysql() {
    local name="${MYSQL_DB:-}" host="${MYSQL_HOST:-localhost}" port="${MYSQL_PORT:-3306}" user="${MYSQL_USER:-root}"
    local dir="$BASE/mysql" ext="sql" tool_args target
    if ! any_set MYSQL_HOST MYSQL_DB MYSQL_USER; then MSG="no MYSQL_* settings in .env"; return 3; fi
    if placeholder_in MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DB; then MSG="$BAD is still a <placeholder>"; return 3; fi
    if ! have mysqldump; then MSG="mysqldump is not installed"; return 3; fi
    [[ "$COMPRESS" == true ]] && ext="sql.gz"
    OUT_FILE="$dir/${name:-all_databases}_${TS}.$ext"
    tool_args=(mysqldump --protocol=TCP -h "$host" -P "$port" -u "$user" --single-transaction --routines --triggers --events)
    if [[ -n "$name" ]]; then tool_args+=("$name"); else tool_args+=(--all-databases); fi

    info "MySQL: ${name:-ALL DATABASES}@$host:$port -> $OUT_FILE"
    if (( DRY_RUN )); then info "[dry-run] ${tool_args[*]}"; return 0; fi
    mkdir -p "$dir"; CURRENT_PARTIAL="$OUT_FILE.partial"
    if [[ "$COMPRESS" == true ]]; then
        env MYSQL_PWD="${MYSQL_PASSWORD:-}" "${tool_args[@]}" | gzip > "$CURRENT_PARTIAL" || { MSG="mysqldump failed"; return 1; }
    else
        env MYSQL_PWD="${MYSQL_PASSWORD:-}" "${tool_args[@]}" > "$CURRENT_PARTIAL" || { MSG="mysqldump failed"; return 1; }
    fi
    finalize_file "$CURRENT_PARTIAL" "$OUT_FILE"
}

backup_mongo() {
    local name="${MONGO_DB_NAME:-mongo}" uri="${MONGO_URI:-}" dir="$BASE/mongo" ext="archive" tool_args
    if ! any_set MONGO_URI; then MSG="no MONGO_URI in .env"; return 3; fi
    if placeholder_in MONGO_URI MONGO_DB_NAME; then MSG="$BAD is still a <placeholder>"; return 3; fi
    if ! have mongodump; then MSG="mongodump is not installed"; return 3; fi
    [[ "$COMPRESS" == true ]] && ext="archive.gz"
    OUT_FILE="$dir/${name}_${TS}.$ext"

    info "MongoDB: $name -> $OUT_FILE"
    if (( DRY_RUN )); then info "[dry-run] mongodump --uri <MONGO_URI> --archive=$OUT_FILE$( [[ $COMPRESS == true ]] && echo ' --gzip' )"; return 0; fi
    mkdir -p "$dir"; CURRENT_PARTIAL="$OUT_FILE.partial"
    tool_args=(mongodump --quiet --uri "$uri" --archive="$CURRENT_PARTIAL")
    if [[ "$COMPRESS" == true ]]; then tool_args+=(--gzip); fi
    "${tool_args[@]}" || { MSG="mongodump failed"; return 1; }
    finalize_file "$CURRENT_PARTIAL" "$OUT_FILE"
}

finalize_file() {   # finalize_file <partial> <final>
    if ! verify_file "$1"; then MSG="backup is empty or corrupt (not kept)"; return 1; fi
    mv "$1" "$2"; CURRENT_PARTIAL=""
    return 0
}

run_engine() {
    local eng="$1" rc=0 dir
    MSG=""; OUT_FILE=""
    "backup_$eng" || rc=$?
    dir="$BASE/$eng"

    case "$rc" in
        0)  OK=$((OK + 1))
            if (( DRY_RUN )); then
                RESULTS+="$(printf '%-9s %-10s %s' "$eng" "DRY-RUN" "$OUT_FILE")"$'\n'
            else
                RESULTS+="$(printf '%-9s %-10s %s (%s)' "$eng" "OK" "$OUT_FILE" "$(human_size "$OUT_FILE")")"$'\n'
                prune_old "$dir" "$(basename "$OUT_FILE" | sed -E 's/_[0-9]{8}_[0-9]{6}\..*$//')"
            fi ;;
        3)  if (( AUTO )); then
                SKIPPED=$((SKIPPED + 1)); warn "$eng skipped: $MSG"
                RESULTS+="$(printf '%-9s %-10s %s' "$eng" "SKIPPED" "$MSG")"$'\n'
            else
                FAILED=$((FAILED + 1)); err "$eng cannot run: $MSG"
                RESULTS+="$(printf '%-9s %-10s %s' "$eng" "FAILED" "$MSG")"$'\n'
            fi ;;
        *)  FAILED=$((FAILED + 1)); err "$eng: $MSG"
            RESULTS+="$(printf '%-9s %-10s %s' "$eng" "FAILED" "$MSG")"$'\n' ;;
    esac
}

main() {
    local eng
    info "Config: $ENV_PATH"
    info "Engines: ${ENGINES// /, } | compress: $COMPRESS | retention: ${RETENTION}d | root: $BASE"
    (( DRY_RUN )) && info "Dry run - nothing will be written or deleted."

    for eng in $ENGINES; do run_engine "$eng"; done

    echo "============================================================"
    echo "                      BACKUP SUMMARY"
    echo "============================================================"
    printf '%s' "$RESULTS"
    echo "------------------------------------------------------------"
    echo "Timestamp : $TS"
    echo "Succeeded : $OK   Skipped: $SKIPPED   Failed: $FAILED"
    echo "============================================================"

    if (( FAILED > 0 )); then exit 1; fi
    if (( OK == 0 )); then err "Nothing was backed up."; exit 1; fi
}

main
