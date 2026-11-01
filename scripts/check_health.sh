#!/usr/bin/env bash
# =============================================================================
# Dynamic Connectivity Health Check
# =============================================================================
# Location: scripts/check_health.sh
#
# Verifies PostgreSQL, MySQL, MongoDB and Databricks using whatever is in .env.
# It adapts to the machine and the config instead of assuming a fixed setup:
#
#   * finds .env itself (--env-file, $PWD, project root) and parses it safely
#     (never `source`s it, so values with spaces / special chars are fine)
#   * environment variables beat .env values (HEALTH_TIMEOUT=3 ./check_health.sh)
#   * skips services that aren't configured or still hold <placeholders>
#   * reads host/port from MONGO_URI; strips https:// from DATABRICKS_HOST
#   * no client installed (psql, mysql, mongosh)? falls back to a port check
#     and reports a WARN instead of a false FAIL
#   * never hangs: every probe has a timeout; passwords stay out of `ps`
#   * --wait N retries until services come up (handy right after docker compose)
#
# Usage:
#   ./check_health.sh                      all configured services (deep checks)
#   ./check_health.sh --quick              port checks only
#   ./check_health.sh --only postgres,mysql
#   ./check_health.sh --skip databricks
#   ./check_health.sh --wait 60            retry failing checks for up to 60s
#   ./check_health.sh --strict             unconfigured services count as FAIL
#   ./check_health.sh --env-file /path/to/.env --timeout 10
#
# Exit code: 0 = nothing failing, 1 = at least one failure (or nothing checked)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_SERVICES="postgres mysql mongo databricks"

QUICK=0; STRICT=0
CLI_WAIT=""; CLI_TIMEOUT=""; ONLY=""; SKIP_LIST=""
ENV_FILE="${ENV_FILE:-}"
PASS=0; FAIL=0; WARN=0; SKIP=0
MSG=""; BAD=""

usage() {
    cat <<'EOF'
Usage: check_health.sh [options]
  --quick            port checks only (no logins / queries)
  --only a,b         check only these: postgres,mysql,mongo,databricks
  --skip a,b         skip these services
  --wait SECONDS     keep retrying failing checks for up to SECONDS
  --timeout SECONDS  per-probe timeout (default 5, or HEALTH_TIMEOUT)
  --strict           treat unconfigured (skipped) services as failures
  --env-file PATH    use this .env (default: auto-detect)
  -h, --help         show this help
EOF
}

die() { printf '[ERROR] %s\n' "$*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)    QUICK=1; shift ;;
        --strict)   STRICT=1; shift ;;
        --only)     [[ $# -ge 2 ]] || die "--only needs a value";     ONLY="$2"; shift 2 ;;
        --skip)     [[ $# -ge 2 ]] || die "--skip needs a value";     SKIP_LIST="$2"; shift 2 ;;
        --wait)     [[ $# -ge 2 ]] || die "--wait needs a value";     CLI_WAIT="$2"; shift 2 ;;
        --timeout)  [[ $# -ge 2 ]] || die "--timeout needs a value";  CLI_TIMEOUT="$2"; shift 2 ;;
        --env-file) [[ $# -ge 2 ]] || die "--env-file needs a value"; ENV_FILE="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *)          usage >&2; die "Unknown option: $1" ;;
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
else
    printf '[ERROR] .env file not found (looked in: %s, %s, %s).\n' "$PWD" "$SCRIPT_DIR/.." "$SCRIPT_DIR" >&2
    printf '        Run setup_env.sh first, or pass --env-file PATH.\n' >&2
    exit 1
fi

TIMEOUT="${CLI_TIMEOUT:-${HEALTH_TIMEOUT:-5}}"
WAIT="${CLI_WAIT:-${HEALTH_WAIT:-0}}"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be a whole number of seconds"
[[ "$WAIT"    =~ ^[0-9]+$ ]] || die "--wait must be a whole number of seconds"

# --- output ---------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; DIM=""; NC=""
fi
info() { printf '[INFO] %s\n' "$*"; }

# --- helpers --------------------------------------------------------------------
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"

run_t() {   # run a command under a timeout when one is available
    if [[ -n "$TIMEOUT_BIN" ]]; then "$TIMEOUT_BIN" "$TIMEOUT" "$@"; else "$@"; fi
}

have() { command -v "$1" >/dev/null 2>&1; }

first_line() {
    local s="${1%%$'\n'*}"
    printf '%s' "${s:0:160}"
}

check_port() {   # check_port <host> <port>
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" "$TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null
    elif have nc; then
        nc -z -w "$TIMEOUT" "$1" "$2" >/dev/null 2>&1
    else
        bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null
    fi
}

any_set() {   # is at least one of these variables defined?
    local v
    for v in "$@"; do
        if [[ -n "${!v:-}" ]]; then return 0; fi
    done
    return 1
}

placeholder_in() {   # sets BAD to the first variable still holding a <placeholder>
    local v
    for v in "$@"; do
        if [[ "${!v:-}" =~ $PH_RE ]]; then BAD="$v"; return 0; fi
    done
    return 1
}

# --- checks ---------------------------------------------------------------------
# Each check sets MSG and returns: 0 = PASS, 1 = FAIL, 2 = WARN, 3 = SKIP
check_postgres() {
    local host="${PG_HOST:-localhost}" port="${PG_PORT:-5432}" user="${PG_USER:-postgres}" db="${PG_DB:-postgres}" err
    if ! any_set PG_HOST PG_PORT PG_USER PG_DB; then MSG="PostgreSQL: no PG_* settings in .env"; return 3; fi
    if placeholder_in PG_HOST PG_PORT PG_USER PG_DB PG_PASS; then MSG="PostgreSQL: $BAD is still a <placeholder>"; return 3; fi

    if ! check_port "$host" "$port"; then MSG="PostgreSQL port $port is unreachable on $host"; return 1; fi
    if (( QUICK )); then MSG="PostgreSQL port $port is open on $host"; return 0; fi
    if ! have psql; then MSG="PostgreSQL port is open, but psql is not installed (deep check skipped)"; return 2; fi

    if err="$(run_t env PGPASSWORD="${PG_PASS:-}" PGCONNECT_TIMEOUT="$TIMEOUT" \
              psql -h "$host" -p "$port" -U "$user" -d "$db" -w -Atc 'SELECT 1;' 2>&1)"; then
        MSG="PostgreSQL ($host:$port/$db) is accepting queries"; return 0
    fi
    MSG="PostgreSQL port is open, but login/query failed: $(first_line "$err")"; return 1
}

check_mysql() {
    local host="${MYSQL_HOST:-localhost}" port="${MYSQL_PORT:-3306}" user="${MYSQL_USER:-root}" err
    if ! any_set MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_DB; then MSG="MySQL: no MYSQL_* settings in .env"; return 3; fi
    if placeholder_in MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DB; then MSG="MySQL: $BAD is still a <placeholder>"; return 3; fi

    if ! check_port "$host" "$port"; then MSG="MySQL port $port is unreachable on $host"; return 1; fi
    if (( QUICK )); then MSG="MySQL port $port is open on $host"; return 0; fi

    # NB: `mysqladmin ping` exits 0 even when access is denied, so it can't verify logins.
    if have mysql; then
        if err="$(run_t env MYSQL_PWD="${MYSQL_PASSWORD:-}" mysql --protocol=TCP -h "$host" -P "$port" -u "$user" \
                  --connect-timeout="$TIMEOUT" -N -e 'SELECT 1;' 2>&1)"; then
            MSG="MySQL ($host:$port) is accepting queries"; return 0
        fi
    elif have mysqladmin; then
        if err="$(run_t env MYSQL_PWD="${MYSQL_PASSWORD:-}" mysqladmin --protocol=TCP -h "$host" -P "$port" -u "$user" \
                  --connect-timeout="$TIMEOUT" status 2>&1)"; then
            MSG="MySQL ($host:$port) is accepting connections"; return 0
        fi
    else
        MSG="MySQL port is open, but no mysql client is installed (deep check skipped)"; return 2
    fi
    MSG="MySQL port is open, but login failed: $(first_line "$err")"; return 1
}

check_mongo() {
    local uri="${MONGO_URI:-}" u h p srv=0 shell="" err
    if ! any_set MONGO_URI MONGO_HOST MONGO_PORT; then MSG="MongoDB: no MONGO_* settings in .env"; return 3; fi
    if placeholder_in MONGO_URI MONGO_HOST MONGO_PORT; then MSG="MongoDB: $BAD is still a <placeholder>"; return 3; fi

    # Derive host/port from the URI so the check follows the real connection string
    if [[ -n "$uri" ]]; then
        [[ "$uri" == mongodb+srv://* ]] && srv=1
        u="${uri#*://}"; u="${u%%/*}"; u="${u##*@}"; u="${u%%,*}"
        if [[ "$u" == \[* ]]; then h="${u%%]*}"; h="${h#[}"; p="${u#*]}"; p="${p#:}"
        else h="${u%%:*}"; if [[ "$u" == *:* ]]; then p="${u##*:}"; else p=""; fi
        fi
        p="${p:-${MONGO_PORT:-27017}}"
    else
        h="${MONGO_HOST:-localhost}"; p="${MONGO_PORT:-27017}"
        uri="mongodb://$h:$p"
    fi

    if (( srv )); then
        if (( QUICK )); then MSG="MongoDB uses an SRV URI; port check not possible (run without --quick)"; return 2; fi
    else
        if ! check_port "$h" "$p"; then MSG="MongoDB port $p is unreachable on $h"; return 1; fi
        if (( QUICK )); then MSG="MongoDB port $p is open on $h"; return 0; fi
    fi

    if have mongosh; then shell="mongosh"; elif have mongo; then shell="mongo"; fi
    if [[ -z "$shell" ]]; then MSG="MongoDB port is open, but mongosh is not installed (deep check skipped)"; return 2; fi

    if err="$(run_t "$shell" "$uri" --quiet --eval "db.adminCommand('ping').ok" 2>&1)"; then
        MSG="MongoDB ($h:$p) answered ping"; return 0
    fi
    MSG="MongoDB did not answer ping: $(first_line "$err")"; return 1
}

check_databricks() {
    local host="${DATABRICKS_HOST:-}" token="${DATABRICKS_TOKEN:-}" code body state wid
    if ! any_set DATABRICKS_HOST DATABRICKS_TOKEN; then MSG="Databricks: no DATABRICKS_* settings in .env"; return 3; fi
    if placeholder_in DATABRICKS_HOST DATABRICKS_TOKEN DATABRICKS_HTTP_PATH; then MSG="Databricks: $BAD is still a <placeholder>"; return 3; fi
    host="${host#https://}"; host="${host#http://}"; host="${host%%/*}"
    if [[ -z "$host" ]]; then MSG="Databricks: DATABRICKS_HOST is empty"; return 1; fi

    if ! check_port "$host" 443; then MSG="Databricks host $host is unreachable on port 443"; return 1; fi
    if (( QUICK )); then MSG="Databricks host $host is reachable on port 443"; return 0; fi
    if [[ -z "$token" ]]; then MSG="Databricks: DATABRICKS_TOKEN is empty"; return 1; fi
    if ! have curl; then MSG="Databricks host is reachable, but curl is not installed (token not verified)"; return 2; fi

    # Token goes through stdin (-K -) so it never shows up in `ps`.
    # SCIM "Me" works for any valid token, unlike clusters/list which needs cluster permissions.
    code="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | \
            curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" -K - \
            "https://$host/api/2.0/preview/scim/v2/Me" 2>/dev/null)" || code="000"

    case "$code" in
        200) ;;
        401|403) MSG="Databricks is reachable, but the token was rejected (HTTP $code)"; return 1 ;;
        000)     MSG="Databricks API did not respond within ${TIMEOUT}s"; return 1 ;;
        *)       MSG="Databricks API returned HTTP $code"; return 1 ;;
    esac

    # Bonus: if DATABRICKS_HTTP_PATH points at a SQL warehouse, report whether it is awake
    if [[ "${DATABRICKS_HTTP_PATH:-}" == */warehouses/* ]]; then
        wid="${DATABRICKS_HTTP_PATH##*/warehouses/}"; wid="${wid%%/*}"
        body="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | \
                curl -s --max-time "$TIMEOUT" -K - "https://$host/api/2.0/sql/warehouses/$wid" 2>/dev/null)" || body=""
        state="$(printf '%s' "$body" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([A-Z_]*\)".*/\1/p' | head -n 1)"
        case "$state" in
            RUNNING)        MSG="Databricks token is valid; SQL warehouse is RUNNING"; return 0 ;;
            STOPPED|STOPPING|STARTING)
                            MSG="Databricks token is valid; SQL warehouse is $state (auto-starts on first query, expect a delay)"; return 2 ;;
        esac
    fi
    MSG="Databricks API is reachable and the token is valid"; return 0
}

# --- runner -----------------------------------------------------------------------
run_check() {   # run_check <service>
    local svc="$1" rc=0 deadline=$((SECONDS + WAIT))
    while :; do
        MSG=""; rc=0
        "check_$svc" || rc=$?
        if [[ "$rc" -ne 1 || "$SECONDS" -ge "$deadline" ]]; then break; fi
        sleep 2
    done
    if (( STRICT && rc == 3 )); then rc=1; MSG="$MSG (--strict)"; fi

    case "$rc" in
        0) PASS=$((PASS + 1)); printf '%s[PASS]%s %s\n' "$GREEN"  "$NC" "$MSG" ;;
        1) FAIL=$((FAIL + 1)); printf '%s[FAIL]%s %s\n' "$RED"    "$NC" "$MSG" >&2 ;;
        2) WARN=$((WARN + 1)); printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$MSG" ;;
        *) SKIP=$((SKIP + 1)); printf '%s[SKIP]%s %s\n' "$DIM"    "$NC" "$MSG" ;;
    esac
}

main() {
    local s item selected=""

    # validate + build the service list
    for item in ${ONLY//,/ } ${SKIP_LIST//,/ }; do
        [[ " $ALL_SERVICES " == *" $item "* ]] || die "Unknown service '$item' (choose from: $ALL_SERVICES)"
    done
    for s in $ALL_SERVICES; do
        if [[ -n "$ONLY" && ",$ONLY," != *",$s,"* ]]; then continue; fi
        if [[ ",$SKIP_LIST," == *",$s,"* ]]; then continue; fi
        selected+="$s "
    done
    [[ -n "$selected" ]] || die "No services selected."

    echo "============================================================"
    echo "            INFRASTRUCTURE HEALTH CHECK"
    echo "============================================================"
    info "Config: $ENV_PATH | mode: $( ((QUICK)) && echo quick || echo full ) | timeout: ${TIMEOUT}s$( ((WAIT)) && echo " | wait: ${WAIT}s" )"

    for s in $selected; do run_check "$s"; done

    echo "============================================================"
    printf 'Passed: %d   Warnings: %d   Skipped: %d   Failed: %d\n' "$PASS" "$WARN" "$SKIP" "$FAIL"
    if (( FAIL > 0 )); then
        printf '%sSYSTEMS FAILURE: %d component(s) failing%s\n' "$RED" "$FAIL" "$NC"
        exit 1
    elif (( PASS + WARN == 0 )); then
        printf '%sNOTHING WAS CHECKED - no service is configured in %s%s\n' "$RED" "$ENV_PATH" "$NC"
        exit 1
    fi
    printf '%sALL CHECKED SYSTEMS OPERATIONAL%s\n' "$GREEN" "$NC"
}

main
