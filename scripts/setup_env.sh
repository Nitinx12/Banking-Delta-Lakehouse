#!/usr/bin/env bash
# =============================================================================
# Dynamic Environment Setup
# =============================================================================
# Builds real .env files from the *.example templates:
#
#   * AUTO-GENERATES secrets   : Airflow Fernet key, Airflow admin password,
#                                R reader password, *SECRET* keys, DB passwords
#   * PROMPTS for your values  : Databricks host/token/http-path, Gmail address
#                                and app password, alert / admin e-mails
#   * DERIVES dependent values : MYSQL_URI, AIRFLOW__SMTP__* (mirrors SMTP_*),
#                                SMTP_MAIL_FROM, ALERT_EMAIL_FROM
#   * SAFE TO RE-RUN           : existing real values are kept (merge mode),
#                                so the Fernet key is never rotated by accident.
#                                A timestamped backup is made before any change.
#
# Usage:
#   ./setup_env.sh                    interactive (asks only what it must)
#   ./setup_env.sh --non-interactive  never prompts; uses SETUP_<KEY> env vars
#   ./setup_env.sh --force            regenerate secrets (re-asks prompted values)
#   ./setup_env.sh --help
#
# CI / unattended example:
#   SETUP_DATABRICKS_HOST=adb-123.azuredatabricks.net \
#   SETUP_DATABRICKS_TOKEN=dapi... \
#   SETUP_SMTP_USER=me@gmail.com SETUP_SMTP_PASSWORD='abcd efgh ijkl mnop' \
#   ./setup_env.sh --non-interactive
# =============================================================================

set -euo pipefail
umask 077   # generated files are readable only by you

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARNING] %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }

# Format: "example_file:target_file"
ENV_FILES=(
    ".env.example:.env"
    "airflow/.env.airflow.example:airflow/.env.airflow"
    "r/.env.r.example:r/.env.r"
)

INTERACTIVE=1
FORCE=0
[[ -t 0 ]] || INTERACTIVE=0

usage() {
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        -n|--non-interactive) INTERACTIVE=0 ;;
        -f|--force)           FORCE=1 ;;
        -h|--help)            usage; exit 0 ;;
        *) err "Unknown option: $arg"; usage; exit 2 ;;
    esac
done

# --- project root ------------------------------------------------------------
ROOT="${PROJECT_ROOT:-}"
if [[ -z "$ROOT" ]]; then
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$ROOT"

# --- state -------------------------------------------------------------------
KV_RE='^([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
PLACEHOLDER_RE='<[^>]*>'
TARGET=""
RESOLVED=""
HOW=""
ANSWER=""
GENERATED=""
PROMPTED=""
PENDING=""

# --- python (only used for secret generation; optional) ----------------------
PYTHON_BIN=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then
        PYTHON_BIN="$c"
        break
    fi
done

# =============================================================================
# Secret generators
# =============================================================================
gen_fernet() {   # identical format to cryptography.fernet.Fernet.generate_key()
    if [[ -n "$PYTHON_BIN" ]]; then
        "$PYTHON_BIN" -c 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())' | tr -d '\r\n'
    elif command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 | tr '+/' '-_' | tr -d '\r\n'
    else
        err "Need python or openssl to generate a Fernet key."; exit 1
    fi
}

gen_password() {   # alphanumeric only -> safe in URIs, shells and .env parsers
    local len="${1:-24}"
    if [[ -n "$PYTHON_BIN" ]]; then
        "$PYTHON_BIN" -c "import secrets, string; a = string.ascii_letters + string.digits; print(''.join(secrets.choice(a) for _ in range($len)))" | tr -d '\r\n'
    elif command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 $((len * 3)) | tr -dc 'A-Za-z0-9' | cut -c1-"$len"
    else
        ( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len" )
    fi
}

gen_hex() {
    if [[ -n "$PYTHON_BIN" ]]; then
        "$PYTHON_BIN" -c 'import secrets; print(secrets.token_hex(32))' | tr -d '\r\n'
    elif command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32 | tr -d '\r\n'
    else
        gen_password 64
    fi
}

# =============================================================================
# Helpers
# =============================================================================
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_placeholder() {   # "<your-...>" or "changeme"
    local v="$1"
    [[ "$v" =~ $PLACEHOLDER_RE ]] || [[ "$v" == "changeme" ]]
}

file_value() {   # file_value <file> <KEY> -> prints value, rc 1 if absent
    local f="$1" k="$2" line
    [[ -f "$f" ]] || return 1
    line="$(grep -E "^${k}=" "$f" | tail -n 1)" || true
    [[ -n "$line" ]] || return 1
    printf '%s' "${line#*=}" | tr -d '\r'
}

urlencode() {
    local s="$1" out="" c hex i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

normalize() {   # normalize <KEY> <value>
    local key="$1" v
    v="$(trim "$2")"
    case "$key" in
        DATABRICKS_HOST) v="${v#https://}"; v="${v#http://}"; v="${v%/}" ;;
        SMTP_PASSWORD)   v="${v//[[:space:]]/}" ;;   # Google shows app passwords with spaces
    esac
    printf '%s' "$v"
}

lookup() {   # lookup <KEY> <default> : this file -> earlier files -> root .env
    local k="$1" d="${2:-}" v="" cur="CUR_$1" cache="CACHE_$1"
    if [[ -n "${!cur+x}" ]]; then
        v="${!cur}"
    elif [[ -n "${!cache+x}" ]]; then
        v="${!cache}"
    else
        v="$(file_value "$ROOT/.env" "$k")" || v=""
    fi
    if [[ -z "$v" ]] || is_placeholder "$v"; then v="$d"; fi
    printf '%s' "$v"
}

hint_for() {
    case "$1" in
        DATABRICKS_HOST)      echo "Workspace hostname, e.g. adb-1234567890123456.7.azuredatabricks.net" ;;
        DATABRICKS_TOKEN)     echo "Personal access token (User Settings > Developer > Access tokens)" ;;
        DATABRICKS_HTTP_PATH) echo "SQL warehouse > Connection details > HTTP path (/sql/1.0/warehouses/...)" ;;
        SMTP_USER)            echo "Gmail address that sends the alert / report e-mails" ;;
        SMTP_PASSWORD)        echo "Gmail APP password (needs 2-Step Verification): https://myaccount.google.com/apppasswords" ;;
        ALERT_EMAIL_TO)       echo "Address that receives pipeline alerts and the daily PDF report" ;;
        AIRFLOW_ADMIN_EMAIL)  echo "E-mail for the Airflow admin account" ;;
        PG_PASS)              echo "PostgreSQL password. Press Enter to auto-generate, or type your existing one." ;;
        MYSQL_PASSWORD)       echo "MySQL password. Press Enter to auto-generate, or type your existing one." ;;
        *)                    echo "Value for $1" ;;
    esac
}

ask() {   # ask <prompt> <default> <secret 0|1>  -> ANSWER
    local prompt="$1" default="${2:-}" secret="${3:-0}" shown=""
    if [[ -n "$default" ]]; then
        if [[ "$secret" == 1 ]]; then shown=" [Enter = keep current]"; else shown=" [$default]"; fi
    fi
    ANSWER=""
    if [[ "$secret" == 1 ]]; then
        read -r -s -p "  $prompt$shown: " ANSWER || ANSWER=""
        echo
    else
        read -r -p "  $prompt$shown: " ANSWER || ANSWER=""
    fi
    if [[ -z "$ANSWER" ]]; then ANSWER="$default"; fi
}

record() {   # record <KEY> <how>
    case "$2" in
        generated) GENERATED+="$TARGET: $1"$'\n' ;;
        prompted)  PROMPTED+="$TARGET: $1"$'\n' ;;
        pending)   PENDING+="$TARGET: $1"$'\n' ;;
    esac
}

# What kind of value is this key?
classify() {   # classify <KEY> <example value>
    local key="$1" example="$2"
    case "$key" in
        *FERNET_KEY)                           echo fernet; return ;;
        MYSQL_URI)                             echo mirror; return ;;
        AIRFLOW__SMTP__SMTP_*)                 echo mirror; return ;;
        SMTP_MAIL_FROM|ALERT_EMAIL_FROM)       echo derive_if_missing; return ;;
        SMTP_PASSWORD|DATABRICKS_TOKEN)        echo prompt_secret; return ;;
        PG_PASS|MYSQL_PASSWORD)                echo db_password; return ;;
        AIRFLOW_ADMIN_PASSWORD|R_PG_PASSWORD)  echo password; return ;;
        AIRFLOW__*SECRET*|*SECRET_KEY)         echo secret_hex; return ;;
        DATABRICKS_HOST|DATABRICKS_HTTP_PATH|SMTP_USER|ALERT_EMAIL_TO|AIRFLOW_ADMIN_EMAIL)
                                               echo prompt; return ;;
    esac
    if is_placeholder "$example"; then      # unknown key that still has a <placeholder>
        case "$key" in
            *PASSWORD*|*_PASS)                 echo password ;;
            *TOKEN*|*API_KEY*|*SECRET*)        echo prompt_secret ;;
            *)                                 echo prompt ;;
        esac
    else
        echo default
    fi
}

# =============================================================================
# Value resolution (sets RESOLVED + HOW)
# Priority: SETUP_<KEY> env var > existing real value > value shared from an
#           earlier file in this run > generate / prompt / template default
# =============================================================================
resolve_key() {
    local key="$1" example="$2" kind="$3"
    local ovr="SETUP_$key" cvar="CACHE_$key"
    local existing="" regen=0 reask=0 secret=0

    existing="$(file_value "$TARGET" "$key")" || existing=""
    if is_placeholder "$existing"; then existing=""; fi

    if [[ -n "${!ovr:-}" ]]; then
        RESOLVED="$(normalize "$key" "${!ovr}")"; HOW=provided
        printf -v "$cvar" '%s' "$RESOLVED"
        return 0
    fi

    if [[ "$FORCE" == 1 ]]; then
        case "$kind" in
            fernet|password|secret_hex|db_password) regen=1 ;;
            prompt|prompt_secret) if [[ "$INTERACTIVE" == 1 ]]; then reask=1; fi ;;
        esac
    fi

    if [[ -n "$existing" && "$regen" == 0 && "$reask" == 0 ]]; then
        RESOLVED="$existing"; HOW=kept
        return 0
    fi

    if [[ -n "${!cvar+x}" ]]; then
        RESOLVED="${!cvar}"; HOW=shared
        if is_placeholder "$RESOLVED"; then HOW=pending; fi
        return 0
    fi

    case "$kind" in
        fernet)      RESOLVED="$(gen_fernet)";      HOW=generated ;;
        password)    RESOLVED="$(gen_password 24)"; HOW=generated ;;
        secret_hex)  RESOLVED="$(gen_hex)";         HOW=generated ;;
        db_password)
            RESOLVED=""
            if [[ "$INTERACTIVE" == 1 ]]; then
                printf '\n  %s\n' "$(hint_for "$key")"
                ask "$key (Enter = auto-generate)" "" 1
                RESOLVED="$(normalize "$key" "$ANSWER")"
            fi
            if [[ -z "$RESOLVED" ]]; then RESOLVED="$(gen_password 24)"; HOW=generated; else HOW=prompted; fi
            ;;
        prompt|prompt_secret)
            if [[ "$kind" == prompt_secret ]]; then secret=1; fi
            RESOLVED=""
            if [[ "$INTERACTIVE" == 1 ]]; then
                printf '\n  %s\n' "$(hint_for "$key")"
                ask "$key" "$existing" "$secret"
                RESOLVED="$(normalize "$key" "$ANSWER")"
            fi
            if [[ -z "$RESOLVED" ]]; then RESOLVED="$example"; HOW=pending; else HOW=prompted; fi
            ;;
        *)           RESOLVED="$example"; HOW=default ;;
    esac

    if [[ "$HOW" == prompted ]]; then
        case "$RESOLVED" in
            *[[:space:]\#\"\'\$\`\\]*)
                warn "$key contains spaces or special characters; quote it in $TARGET if your tooling needs it." ;;
        esac
    fi

    if [[ "$kind" != default ]]; then printf -v "$cvar" '%s' "$RESOLVED"; fi
}

derive_key() {   # keys computed from other keys (resolved in pass 2)
    local key="$1" example="$2" kind="$3"
    local ovr="SETUP_$key" existing="" v="" pw="" src=""

    existing="$(file_value "$TARGET" "$key")" || existing=""
    if is_placeholder "$existing"; then existing=""; fi

    if [[ -n "${!ovr:-}" ]]; then RESOLVED="${!ovr}"; HOW=provided; return 0; fi

    case "$key" in
        MYSQL_URI)
            pw="$(lookup MYSQL_PASSWORD '')"
            if [[ -z "$pw" ]]; then
                RESOLVED="$example"; HOW=pending
            else
                RESOLVED="mysql://$(lookup MYSQL_USER root):$(urlencode "$pw")@$(lookup MYSQL_HOST localhost):$(lookup MYSQL_PORT 3306)/$(lookup MYSQL_DB banking_core_db)"
                HOW=derived
            fi
            ;;
        AIRFLOW__SMTP__SMTP_*)
            src="SMTP_${key#AIRFLOW__SMTP__SMTP_}"
            RESOLVED="$(lookup "$src" "$example")"; HOW=derived
            if is_placeholder "$RESOLVED"; then HOW=pending; fi
            ;;
        *)  # SMTP_MAIL_FROM / ALERT_EMAIL_FROM default to the Gmail account
            if [[ -n "$existing" ]]; then
                RESOLVED="$existing"; HOW=kept
            else
                RESOLVED="$(lookup SMTP_USER "$example")"; HOW=derived
                if is_placeholder "$RESOLVED"; then HOW=pending; fi
            fi
            ;;
    esac
}

# =============================================================================
# Build one target file from one example
# =============================================================================
process_file() {
    local example="$1" target="$2"
    local line key val kind tmp bak v k extras="" keys=" "
    TARGET="$target"

    for v in $(compgen -v CUR_ || true); do unset "$v"; done

    # Pass 1: independent keys (prompt / generate / keep)
    while IFS= read -r -u 3 line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ $KV_RE ]]; then
            key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
            keys+="$key "
            kind="$(classify "$key" "$val")"
            case "$kind" in mirror|derive_if_missing) continue ;; esac
            resolve_key "$key" "$val" "$kind"
            printf -v "CUR_$key" '%s' "$RESOLVED"
            record "$key" "$HOW"
        fi
    done 3< "$example"

    # Pass 2: keys derived from pass-1 values
    while IFS= read -r -u 3 line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ $KV_RE ]]; then
            key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
            kind="$(classify "$key" "$val")"
            case "$kind" in
                mirror|derive_if_missing)
                    derive_key "$key" "$val" "$kind"
                    printf -v "CUR_$key" '%s' "$RESOLVED"
                    record "$key" "$HOW"
                    ;;
            esac
        fi
    done 3< "$example"

    # Pass 3: render (keeps comments / layout of the template)
    mkdir -p "$(dirname "$target")"
    tmp="$(mktemp "$target.XXXXXX")"
    {
        printf '# Generated by setup_env.sh from %s\n' "$example"
        printf '# Contains secrets - never commit this file.\n\n'
    } > "$tmp"

    while IFS= read -r -u 3 line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" == "# Copy this file to"* || "$line" == "#   cp "* ]]; then continue; fi
        if [[ "$line" =~ $KV_RE ]]; then
            k="${BASH_REMATCH[1]}"; v="CUR_$k"
            printf '%s=%s\n' "$k" "${!v}" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done 3< "$example"

    # Keep custom variables the user added to an existing file
    if [[ -f "$target" ]]; then
        while IFS= read -r -u 4 line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            if [[ "$line" =~ $KV_RE ]]; then
                k="${BASH_REMATCH[1]}"
                if [[ "$keys" != *" $k "* ]]; then extras+="$line"$'\n'; fi
            fi
        done 4< "$target"
        if [[ -n "$extras" ]]; then
            printf '\n# ---- Preserved from previous %s ----\n%s' "$target" "$extras" >> "$tmp"
        fi
    fi

    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        info "$target is already up to date"
    else
        if [[ -f "$target" ]]; then
            bak="$target.bak.$(date +%Y%m%d%H%M%S)"
            cp -p "$target" "$bak"
            chmod 600 "$bak" 2>/dev/null || true
            info "Backed up existing file to $bak"
        fi
        mv "$tmp" "$target"
        chmod 600 "$target" 2>/dev/null || true
        info "Wrote $target (from $example)"
    fi

    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if ! git check-ignore -q "$target" 2>/dev/null; then
            warn "$target is NOT git-ignored. Add it to .gitignore so secrets are not committed."
        fi
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    info "Starting environment setup in $ROOT"
    if [[ "$INTERACTIVE" == 1 ]]; then
        info "Interactive mode: secrets are generated for you; you'll be asked only for values we can't invent."
    else
        info "Non-interactive mode: using SETUP_<KEY> env vars; unknown values stay as <placeholders>."
    fi
    if [[ "$FORCE" == 1 ]]; then
        warn "--force: secrets will be regenerated. A new AIRFLOW__CORE__FERNET_KEY cannot decrypt"
        warn "connections/variables already stored in an existing Airflow metadata DB."
    fi

    local pair example target
    for pair in "${ENV_FILES[@]}"; do
        example="${pair%%:*}"
        target="${pair#*:}"
        if [[ ! -f "$example" ]]; then
            err "Example file not found: $example. Skipping $target."
            continue
        fi
        echo
        info "Processing $target"
        process_file "$example" "$target"
    done

    echo
    echo "============================================================"
    echo "                      SETUP COMPLETE"
    echo "============================================================"
    if [[ -n "$GENERATED" ]]; then
        echo "Auto-generated (values are inside the files):"
        printf '%s' "$GENERATED" | sed 's/^/  - /'
        echo
    fi
    if [[ -n "$PROMPTED" ]]; then
        echo "Entered by you:"
        printf '%s' "$PROMPTED" | sed 's/^/  - /'
        echo
    fi
    if [[ -n "$PENDING" ]]; then
        echo "STILL NEEDS A REAL VALUE (edit the file, or re-run this script):"
        printf '%s' "$PENDING" | sed 's/^/  - /'
        echo
    fi
    if [[ "$GENERATED" == *": PG_PASS"* || "$GENERATED" == *": MYSQL_PASSWORD"* || "$GENERATED" == *": R_PG_PASSWORD"* ]]; then
        echo "NOTE: generated DB passwords must match your databases. Fresh containers"
        echo "      will pick them up from .env; for an already-running Postgres/MySQL,"
        echo "      set the same password there (and for the r_reader role)."
        echo
    fi
    echo "Re-running is safe: real values are kept, backups are timestamped."
    echo "============================================================"
}

main
