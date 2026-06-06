#!/usr/bin/env bash
#
# bootstrap.sh — one-shot installer for the SQL Server estate's management
# host on RHEL / Rocky / AlmaLinux / CentOS Stream. Run as root from inside
# the project clone:
#
#     sudo ./bootstrap.sh
#
# Reads setup.yaml in the same directory. Sets the hostname from the host's
# entry in /etc/hosts, then installs and wires up:
#
#   - Python 3 + Ansible + Windows collections
#   - GitHub CLI (gh) + optional gh auth from setup.yaml / GH_TOKEN
#   - InfluxDB 1.x   (CheckMK perfdata target)
#   - CheckMK Raw    (server / OMD site)
#   - nagflux        (CheckMK Raw -> InfluxDB live pipeline)
#   - Rundeck        (job orchestration)
#   - Ollama         (local LLM for the chatbot, pulls the configured model)
#   - DBA chatbot    (Flask app under AI/, systemd service)
#   - ticktator      (CheckMK -> ServiceNow notification handler)
#   - firewalld      (opens the ports listed in setup.yaml)
#
# After each phase a QA check runs. On failure or QA-failure you're prompted
# to retry / skip / continue-anyway / abort. Set BOOTSTRAP_AUTO=1 for a
# non-interactive run (auto-continue on success, auto-abort on failure).
#
# Skip phases with env vars (each accepts 1/true to skip):
#   SKIP_GITHUB, SKIP_INFLUXDB, SKIP_CHECKMK, SKIP_NAGFLUX, SKIP_RUNDECK,
#   SKIP_OLLAMA, SKIP_CHATBOT, SKIP_AUTOONBOARD, SKIP_TICKTATOR, SKIP_FIREWALL
#
# Override the path to setup.yaml:
#   SETUP_YAML=/path/to/setup.yaml ./bootstrap.sh
#
set -euo pipefail
shopt -s nullglob

# --- paths / logging ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_YAML="${SETUP_YAML:-$SCRIPT_DIR/setup.yaml}"
LOG_FILE=/var/log/bootstrap.log
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

c_blue=$'\033[1;34m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_green=$'\033[1;32m'; c_off=$'\033[0m'
log()   { printf '%s[bootstrap]%s %s\n' "$c_blue"   "$c_off" "$*" | tee -a "$LOG_FILE"; }
warn()  { printf '%s[bootstrap]%s %s\n' "$c_yellow" "$c_off" "$*" | tee -a "$LOG_FILE"; }
ok()    { printf '%s[bootstrap]%s %s\n' "$c_green"  "$c_off" "$*" | tee -a "$LOG_FILE"; }
die()   { printf '%s[bootstrap FATAL]%s %s\n' "$c_red" "$c_off" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }
phase() { printf '\n%s========== %s ==========%s\n' "$c_blue" "$*" "$c_off" | tee -a "$LOG_FILE"; }

skip() {
    local v="${!1:-0}"
    case "${v,,}" in 1|true|yes) return 0 ;; *) return 1 ;; esac
}

# --- interactive flow: retry / skip / continue / abort -----------------------
#
# Sentinel return codes phase functions can use:
#   99  = precondition not met; treat as skipped (no prompt)
#
# Set BOOTSTRAP_AUTO=1 for non-interactive runs (auto-continue / auto-abort).
prompt_action() {
    local name="$1" status="$2"   # status: failed | qa_failed | ok
    local msg default

    case "$status" in
        failed)
            msg="${c_red}[$name] FAILED${c_off} — review $LOG_FILE
  [r]etry / [s]kip / [a]bort"
            default="r"
            ;;
        qa_failed)
            msg="${c_yellow}[$name] QA CHECK FAILED${c_off} — review $LOG_FILE
  [r]etry / [s]kip / [c]ontinue anyway / [a]bort"
            default="r"
            ;;
        ok)
            msg="${c_green}[$name] OK${c_off}
  [c]ontinue / [r]etry / [s]kip-next / [a]bort"
            default="c"
            ;;
    esac

    # Non-interactive (BOOTSTRAP_AUTO=1 or no controlling tty): auto-decide.
    if [[ "${BOOTSTRAP_AUTO:-0}" =~ ^(1|true|yes)$ ]] || [[ ! -r /dev/tty ]]; then
        case "$status" in
            ok)        echo continue ;;
            qa_failed) echo continue ;;
            failed)    echo abort ;;
        esac
        return
    fi

    local ans
    while true; do
        printf '\n%s\n  Choice [%s]: ' "$msg" "$default" >/dev/tty
        if ! IFS= read -r ans </dev/tty; then
            # tty went away mid-run; behave like BOOTSTRAP_AUTO.
            case "$status" in
                ok|qa_failed) echo continue ;;
                failed)       echo abort ;;
            esac
            return
        fi
        ans="${ans:-$default}"
        case "${ans,,}" in
            r|retry)        echo retry;    return ;;
            s|skip)         echo skip;     return ;;
            c|continue)     echo continue; return ;;
            a|abort)        echo abort;    return ;;
            *) printf '%s[bootstrap]%s pick r / s / c / a\n' "$c_yellow" "$c_off" >/dev/tty ;;
        esac
    done
}

# run_phase <display name> <skip-env-var-or-empty> <run-fn> [qa-fn]
#
# Honors the SKIP_* env var, runs the phase in a subshell so a failure inside
# doesn't kill the script, runs the (optional) QA check, then prompts the user.
run_phase() {
    local name="$1" skip_var="$2" run_fn="$3" qa_fn="${4:-}"

    if [[ -n "$skip_var" ]] && skip "$skip_var"; then
        warn "$name — SKIPPED ($skip_var=1)"
        return 0
    fi

    local attempt=0
    while true; do
        attempt=$((attempt + 1))
        if [[ $attempt -eq 1 ]]; then
            phase "$name"
        else
            phase "$name (retry #$((attempt - 1)))"
        fi

        local rc=0
        ( set -e; "$run_fn" ) || rc=$?

        # Phase-level precondition skip — no prompt, just move on.
        if [[ $rc -eq 99 ]]; then
            return 0
        fi

        local action
        if [[ $rc -ne 0 ]]; then
            warn "$name failed (rc=$rc)"
            action="$(prompt_action "$name" failed)"
        elif [[ -n "$qa_fn" ]] && declare -F "$qa_fn" >/dev/null 2>&1; then
            local qrc=0
            ( set -e; "$qa_fn" ) || qrc=$?
            if [[ $qrc -ne 0 ]]; then
                warn "$name — QA check failed (rc=$qrc)"
                action="$(prompt_action "$name" qa_failed)"
            else
                ok "$name — QA passed"
                action="$(prompt_action "$name" ok)"
            fi
        else
            action="$(prompt_action "$name" ok)"
        fi

        case "$action" in
            retry)    log "Retrying $name…"; continue ;;
            skip)     warn "$name — SKIPPED by user"; return 0 ;;
            continue) return 0 ;;
            abort)    die "aborted by user at $name" ;;
        esac
    done
}

# --- pre-flight ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "must be run as root"
[[ -f $SETUP_YAML ]] || die "setup.yaml not found at $SETUP_YAML"
command -v rpm >/dev/null || die "not an RPM-based system"

. /etc/os-release
DISTRO_ID="$ID"
EL_VERSION="${VERSION_ID%%.*}"
case "$DISTRO_ID" in
    rhel|centos|rocky|almalinux|fedora) ;;
    *) warn "Untested distro '$DISTRO_ID'; continuing anyway" ;;
esac
log "Detected $DISTRO_ID $EL_VERSION"

# --- hostname from /etc/hosts -------------------------------------------------
phase "Hostname from /etc/hosts"
get_hostname_from_hosts() {
    local primary_ip h=""
    primary_ip="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $9; exit}')"
    if [[ -n ${primary_ip:-} ]]; then
        # Match the row beginning with the primary IP, return first non-comment alias.
        h="$(awk -v ip="$primary_ip" '
            $1 == ip {
                for (i = 2; i <= NF; i++) if ($i !~ /^(localhost|#)/) { print $i; exit }
            }' /etc/hosts)"
    fi
    if [[ -z $h ]]; then
        # Fall back to the first non-loopback row's primary name.
        h="$(awk '
            $1 !~ /^127\./ && $1 !~ /^::1?$/ && NF >= 2 && $0 !~ /^[[:space:]]*#/ {
                print $2; exit
            }' /etc/hosts)"
    fi
    echo "$h"
}
NEW_HOST="$(get_hostname_from_hosts)"
[[ -n $NEW_HOST ]] || die "could not derive a hostname from /etc/hosts"
log "Setting hostname to $NEW_HOST"
hostnamectl set-hostname "$NEW_HOST"
[[ "$(hostname)" == "$NEW_HOST" ]] || warn "hostname mismatch — kernel still reports '$(hostname)'"

# --- Phase 2: load setup.yaml into shell variables ----------------------------
# (kept inline because it has to export many vars to the parent shell)
phase "Phase 2: load setup.yaml"
SETUP_ENV="$(mktemp)"
python3 - "$SETUP_YAML" <<'PY' > "$SETUP_ENV"
import shlex, sys, yaml
with open(sys.argv[1]) as fh:
    d = yaml.safe_load(fh) or {}

def g(*p, default=''):
    x = d
    for k in p:
        if not isinstance(x, dict) or k not in x:
            return default
        x = x[k]
    return x if x is not None else default

vals = {
    "INFLUX_HOST":     g('chatbot','influxdb','host', default='localhost'),
    "INFLUX_PORT":     g('chatbot','influxdb','port', default=8086),
    "INFLUX_DB":       g('chatbot','influxdb','database', default='influx'),
    "INFLUX_USER":     g('chatbot','influxdb','user', default='influx'),
    "INFLUX_PASS":     g('chatbot','influxdb','password', default='influx'),
    "INFLUXDB_VERSION":g('bootstrap','packages','influxdb_version', default='1.8.10'),
    "JAVA_PKG":        g('bootstrap','packages','java', default='java-17-openjdk'),
    "NAGFLUX_VERSION": g('bootstrap','nagflux','version', default='0.4.3'),
    "NAGFLUX_URL":     g('bootstrap','nagflux','url',
                          default='https://github.com/Griesbacher/nagflux/releases/download/v0.4.3/nagflux-linux-x86_64.tar.gz'),
    "OLLAMA_BASE":     g('chatbot','llm','ollama','base_url', default='http://localhost:11434'),
    "OLLAMA_MODEL":    g('chatbot','llm','ollama','model', default='llama3.1:8b'),
    "FLASK_HOST":      g('chatbot','flask','host', default='0.0.0.0'),
    "FLASK_PORT":      g('chatbot','flask','port', default=5000),
    "CHECKMK_SITE":    g('bootstrap','checkmk','site', default='monitoring'),
    "CHECKMK_ADMIN":   g('bootstrap','checkmk','admin_password', default='cmkadmin'),
    "RUNDECK_ADMIN":   g('bootstrap','rundeck','admin_password', default='admin'),
    "RUNDECK_URL":     g('bootstrap','rundeck','public_url', default='http://localhost:4440'),
    "SNOW_INSTANCE":   g('servicenow','instance', default=''),
    "SNOW_USER":       g('servicenow','user', default=''),
    "SNOW_PASS":       g('servicenow','password', default=''),
    "SNOW_GROUP":      g('servicenow','assignment_group', default='Database Operations'),
    "SNOW_DEDUP":      g('servicenow','dedup_hours', default=4),
    "GITHUB_TOKEN":    g('bootstrap','github','token', default=''),
    "FW_PORTS":        ' '.join(str(p) for p in g('bootstrap','firewall_ports', default=[]) or []),
}
for k, v in vals.items():
    print(f"{k}={shlex.quote(str(v))}")
PY
# shellcheck disable=SC1090
source "$SETUP_ENV"
rm -f "$SETUP_ENV"
log "setup.yaml loaded (CheckMK site=$CHECKMK_SITE, Influx db=$INFLUX_DB, model=$OLLAMA_MODEL)"

# =============================================================================
# Phase functions (run_fn + qa_fn pairs) — registered with run_phase below.
# =============================================================================

# --- Phase 1: base packages --------------------------------------------------
phase1_base_packages() {
    dnf -y install epel-release >>"$LOG_FILE" 2>&1 || true
    dnf -y install python3 python3-pip git curl wget firewalld rsync tar openssl \
                   ca-certificates jq >>"$LOG_FILE" 2>&1
    python3 -m pip install --quiet --upgrade pip pyyaml >>"$LOG_FILE" 2>&1
    ok "Python $(python3 -V | awk '{print $2}'), pip ready"
}
qa_phase1_base_packages() {
    local missing=()
    for cmd in python3 pip3 git curl wget firewall-cmd rsync tar openssl jq; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        warn "missing commands: ${missing[*]}"
        return 1
    fi
    python3 -c 'import yaml' >/dev/null 2>&1 || { warn "python yaml module missing"; return 1; }
    log "QA: base packages present; pyyaml importable"
}

# --- Phase 3: Ansible --------------------------------------------------------
phase3_ansible() {
    # Match AI/requirements.txt so pip-installs from there get the same set we
    # pre-install systemwide here. ansible (meta) pulls in ansible-core.
    python3 -m pip install --quiet --upgrade \
        "ansible>=2.14" \
        "ansible-core>=2.14" \
        "ansible-runner>=2.0" \
        "ansible-lint>=6.0" \
        "ansible-tower-cli>=3.0" \
        >>"$LOG_FILE" 2>&1 || warn "one or more ansible pip installs failed — review $LOG_FILE"

    # Windows collections come from Galaxy, not PyPI.
    ansible-galaxy collection install ansible.windows community.windows --upgrade >>"$LOG_FILE" 2>&1 || \
        warn "ansible-galaxy collection install had warnings — review $LOG_FILE"
    ok "Ansible $(ansible --version | head -1 | awk '{print $NF}' | tr -d ']')"
}
qa_phase3_ansible() {
    command -v ansible >/dev/null 2>&1 || { warn "ansible binary missing"; return 1; }
    command -v ansible-galaxy >/dev/null 2>&1 || { warn "ansible-galaxy missing"; return 1; }
    ansible --version >/dev/null 2>&1 || { warn "ansible --version failed"; return 1; }
    local installed
    installed="$(ansible-galaxy collection list 2>/dev/null || true)"
    grep -q '^ansible\.windows ' <<<"$installed"     || { warn "ansible.windows collection missing"; return 1; }
    grep -q '^community\.windows ' <<<"$installed"   || { warn "community.windows collection missing"; return 1; }
    log "QA: ansible + windows collections present"
}

# --- Phase 3b: GitHub CLI ----------------------------------------------------
phase3b_github_cli() {
    if ! command -v gh >/dev/null 2>&1; then
        # The official RHEL repo for the GitHub CLI.
        cat >/etc/yum.repos.d/gh-cli.repo <<'REPO'
[gh-cli]
name=packages for the GitHub CLI
baseurl=https://cli.github.com/packages/rpm
enabled=1
gpgcheck=1
gpgkey=https://cli.github.com/packages/rpm/gh-cli.repo.gpg
REPO
        # Some RHEL forks ship the key separately; this is harmless either way.
        rpm --import https://cli.github.com/packages/rpm/gh-cli.repo.gpg 2>>"$LOG_FILE" || true
        dnf -y install gh >>"$LOG_FILE" 2>&1 || warn "gh install failed — continuing without it"
    fi

    # Allow GH_TOKEN env var to override the value from setup.yaml.
    GH_AUTH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
    if command -v gh >/dev/null 2>&1; then
        if [[ -n "$GH_AUTH_TOKEN" && "$GH_AUTH_TOKEN" != "CHANGE_ME" ]]; then
            # `gh auth login --with-token` reads the token from stdin and stores
            # it in the running user's gh config. Suppress the token from the log.
            if printf '%s' "$GH_AUTH_TOKEN" | gh auth login --with-token >/dev/null 2>&1; then
                ok "gh $(gh --version | awk 'NR==1 {print $3}') installed and authenticated"
            else
                warn "gh installed but auth failed — verify token scopes (needs 'repo')"
            fi
        else
            ok "gh $(gh --version | awk 'NR==1 {print $3}') installed (no token supplied — run 'gh auth login' to sign in)"
        fi
    fi
}
qa_phase3b_github_cli() {
    command -v gh >/dev/null 2>&1 || { warn "gh binary missing"; return 1; }
    gh --version >/dev/null 2>&1 || { warn "gh --version failed"; return 1; }
    # Auth is optional; only verify if a token was supplied.
    local tok="${GH_TOKEN:-$GITHUB_TOKEN}"
    if [[ -n "$tok" && "$tok" != "CHANGE_ME" ]]; then
        gh auth status >/dev/null 2>&1 || { warn "gh auth status reports not logged in"; return 1; }
    fi
    log "QA: gh CLI ready"
}

# --- Phase 4: InfluxDB -------------------------------------------------------
phase4_influxdb() {
    cat >/etc/yum.repos.d/influxdata.repo <<'REPO'
[influxdata]
name = InfluxData Repository - Stable
baseurl = https://repos.influxdata.com/rhel/$releasever/$basearch/stable
enabled = 1
gpgcheck = 1
gpgkey = https://repos.influxdata.com/influxdata-archive_compat.key
REPO
    dnf -y install "influxdb-${INFLUXDB_VERSION}" >>"$LOG_FILE" 2>&1 || \
        dnf -y install influxdb >>"$LOG_FILE" 2>&1
    systemctl enable --now influxdb >>"$LOG_FILE" 2>&1
    # Wait for the HTTP API to come up.
    for _ in {1..15}; do
        curl -fs http://localhost:8086/ping && break || sleep 1
    done
    influx -execute "CREATE DATABASE \"$INFLUX_DB\"" >>"$LOG_FILE" 2>&1 || true
    if [[ -n "$INFLUX_USER" && -n "$INFLUX_PASS" ]]; then
        influx -execute "CREATE USER \"$INFLUX_USER\" WITH PASSWORD '$INFLUX_PASS' WITH ALL PRIVILEGES" >>"$LOG_FILE" 2>&1 \
            || influx -execute "SET PASSWORD FOR \"$INFLUX_USER\" = '$INFLUX_PASS'" >>"$LOG_FILE" 2>&1 || true
        influx -execute "GRANT ALL ON \"$INFLUX_DB\" TO \"$INFLUX_USER\"" >>"$LOG_FILE" 2>&1 || true
    fi
    ok "InfluxDB on http://localhost:8086, db=$INFLUX_DB"
}
qa_phase4_influxdb() {
    systemctl is-active --quiet influxdb || { warn "influxdb service not active"; return 1; }
    curl -fs --max-time 5 http://localhost:8086/ping >/dev/null 2>&1 || \
        { warn "influxdb /ping failed"; return 1; }
    if ! influx -execute "SHOW DATABASES" 2>/dev/null | grep -qx "$INFLUX_DB"; then
        warn "database $INFLUX_DB not found in SHOW DATABASES"
        return 1
    fi
    log "QA: influxdb up, db=$INFLUX_DB present"
}

# --- Phase 5: CheckMK Raw ----------------------------------------------------
phase5_checkmk() {
    if ! command -v omd >/dev/null 2>&1; then
        # Look for an RPM in MSSQL/files/ first; the user can drop any supported version there.
        cmk_rpm="$(ls -1 "$SCRIPT_DIR"/MSSQL/files/check-mk-raw-*.rpm 2>/dev/null | sort -V | tail -1)"
        if [[ -z $cmk_rpm ]]; then
            die "CheckMK RPM not found. Download from https://checkmk.com/download and place in $SCRIPT_DIR/MSSQL/files/"
        fi
        log "Installing $cmk_rpm"
        dnf -y install "$cmk_rpm" >>"$LOG_FILE" 2>&1
    fi
    if ! omd sites 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CHECKMK_SITE"; then
        omd create "$CHECKMK_SITE" >>"$LOG_FILE" 2>&1
        # Set admin password (works in 2.x).
        omd su "$CHECKMK_SITE" -c "htpasswd -b ~/etc/htpasswd cmkadmin '$CHECKMK_ADMIN'" >>"$LOG_FILE" 2>&1 \
            || warn "Could not set admin password — set it manually"
    else
        log "Site $CHECKMK_SITE already exists"
    fi
    omd start "$CHECKMK_SITE" >>"$LOG_FILE" 2>&1 || true
    ok "CheckMK GUI: http://$NEW_HOST/${CHECKMK_SITE}/ (user cmkadmin)"
}
qa_phase5_checkmk() {
    command -v omd >/dev/null 2>&1 || { warn "omd binary missing"; return 1; }
    omd sites 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CHECKMK_SITE" || \
        { warn "site $CHECKMK_SITE not registered"; return 1; }
    # omd status returns non-zero if anything is stopped.
    if ! omd status "$CHECKMK_SITE" >>"$LOG_FILE" 2>&1; then
        warn "omd status reports stopped/partial components in site $CHECKMK_SITE"
        return 1
    fi
    log "QA: checkmk site $CHECKMK_SITE running"
}

# --- Phase 5b: nagflux (CheckMK Raw -> InfluxDB) -----------------------------
phase5b_nagflux() {
    if ! command -v omd >/dev/null 2>&1; then
        warn "nagflux needs CheckMK/OMD, but it's not installed; skipping"
        return 99
    fi
    install -d /opt/nagflux /etc/nagflux /var/lib/nagflux

    if [[ ! -x /opt/nagflux/nagflux ]]; then
        tmp="$(mktemp -d)"
        log "Downloading nagflux from $NAGFLUX_URL"
        curl -fsSL -o "$tmp/nagflux.tgz" "$NAGFLUX_URL" || die "nagflux download failed"
        tar -C "$tmp" -xzf "$tmp/nagflux.tgz"
        bin="$(find "$tmp" -maxdepth 2 -type f -name nagflux -perm -u+x | head -1)"
        [[ -n $bin ]] || die "nagflux binary not found in archive"
        install -m 0755 "$bin" /opt/nagflux/nagflux
        rm -rf "$tmp"
    fi

    SPOOL="/omd/sites/$CHECKMK_SITE/var/spool/nagflux"
    install -d -o "$CHECKMK_SITE" -g "$CHECKMK_SITE" "$SPOOL" /var/lib/nagflux

    # nagflux config — write CheckMK perfdata into the InfluxDB 'checkmk' DB.
    # The Nagios macros ($TIMET$, $HOSTNAME$, ...) inside the .mk template below
    # are kept literal via \$ — bash sees the backslash, the file gets $...$.
    cat >/etc/nagflux/config.gcfg <<NCFG
[main]
NagiosSpoolfileFolder = "$SPOOL"
NagiosSpoolfileWorker = 4
InfluxWorker          = 8
MaxInfluxWorker       = 16
DumpFile              = "/var/lib/nagflux/nagflux.dump"
NagfluxSpoolfileFolder= "/var/lib/nagflux/spool"
FieldSeparator        = "&"
BufferSize            = 10000
FileBufferSize        = 65536
DefaultTarget         = "all"
ModGearmanWorker      = 0

[Log]
LogFile     = "/var/log/nagflux.log"
MinSeverity = "INFO"

[InfluxDBGlobal]
CreateDatabaseIfNotExists = true

[InfluxDB "all"]
Enabled               = true
Version               = 1.0
Address               = "http://127.0.0.1:${INFLUX_PORT}"
Arguments             = "precision=ms&db=${INFLUX_DB}&u=${INFLUX_USER}&p=${INFLUX_PASS}"
StopPullingDataIfDown = true

[Livestatus]
Type            = "unix"
Address         = "/omd/sites/$CHECKMK_SITE/tmp/run/live"
MinBackoffTime  = 30s
MaxBackoffTime  = 120s

[ModGearman "default"]
Enabled = false
NCFG

    touch /var/log/nagflux.log
    chown "$CHECKMK_SITE:$CHECKMK_SITE" /var/log/nagflux.log /var/lib/nagflux

    # Tell the CheckMK site to write perfdata in Nagios format to $SPOOL so
    # nagflux can pick it up.
    SITE_MK_DIR="/omd/sites/$CHECKMK_SITE/etc/check_mk/conf.d/wato"
    install -d -o "$CHECKMK_SITE" -g "$CHECKMK_SITE" "$SITE_MK_DIR"
    cat >"$SITE_MK_DIR/nagflux_perfdata.mk" <<MKCFG
# Generated by bootstrap.sh — feed perfdata to nagflux.
process_performance_data = True
host_perfdata_file       = "$SPOOL/host-perfdata"
service_perfdata_file    = "$SPOOL/service-perfdata"
host_perfdata_file_template = (
    "DATATYPE::HOSTPERFDATA\tTIMET::\$TIMET\$\tHOSTNAME::\$HOSTNAME\$\t"
    "HOSTPERFDATA::\$HOSTPERFDATA\$\tHOSTCHECKCOMMAND::\$HOSTCHECKCOMMAND\$\t"
    "HOSTSTATE::\$HOSTSTATE\$\tHOSTSTATETYPE::\$HOSTSTATETYPE\$"
)
service_perfdata_file_template = (
    "DATATYPE::SERVICEPERFDATA\tTIMET::\$TIMET\$\tHOSTNAME::\$HOSTNAME\$\t"
    "SERVICEDESC::\$SERVICEDESC\$\tSERVICEPERFDATA::\$SERVICEPERFDATA\$\t"
    "SERVICECHECKCOMMAND::\$SERVICECHECKCOMMAND\$\tHOSTSTATE::\$HOSTSTATE\$\t"
    "HOSTSTATETYPE::\$HOSTSTATETYPE\$\tSERVICESTATE::\$SERVICESTATE\$\t"
    "SERVICESTATETYPE::\$SERVICESTATETYPE\$"
)
service_perfdata_file_mode = "p"
service_perfdata_file_processing_interval = 15
host_perfdata_file_mode = "p"
host_perfdata_file_processing_interval = 15
MKCFG
    chown "$CHECKMK_SITE:$CHECKMK_SITE" "$SITE_MK_DIR/nagflux_perfdata.mk"

    # Re-apply CheckMK config so the site picks up the new perfdata routing.
    omd su "$CHECKMK_SITE" -c "cmk -U && cmk -O" >>"$LOG_FILE" 2>&1 || \
        warn "cmk -U/-O returned non-zero; check the site manually"

    cat >/etc/systemd/system/nagflux.service <<UNIT
[Unit]
Description=Nagflux - CheckMK perfdata -> InfluxDB
After=network-online.target influxdb.service
Wants=network-online.target

[Service]
Type=simple
User=$CHECKMK_SITE
Group=$CHECKMK_SITE
ExecStart=/opt/nagflux/nagflux -configPath /etc/nagflux/config.gcfg
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now nagflux >>"$LOG_FILE" 2>&1
    ok "nagflux running, feeding CheckMK perfdata into InfluxDB db=$INFLUX_DB"
}
qa_phase5b_nagflux() {
    [[ -x /opt/nagflux/nagflux ]] || { warn "/opt/nagflux/nagflux missing/not executable"; return 1; }
    [[ -f /etc/nagflux/config.gcfg ]] || { warn "/etc/nagflux/config.gcfg missing"; return 1; }
    systemctl is-active --quiet nagflux || { warn "nagflux service not active"; return 1; }
    [[ -f "/omd/sites/$CHECKMK_SITE/etc/check_mk/conf.d/wato/nagflux_perfdata.mk" ]] || \
        { warn "checkmk perfdata wiring file missing"; return 1; }
    log "QA: nagflux active, perfdata routing in place"
}

# --- Phase 6: Rundeck --------------------------------------------------------
phase6_rundeck() {
    dnf -y install "$JAVA_PKG" >>"$LOG_FILE" 2>&1
    if ! rpm -q rundeck >/dev/null 2>&1; then
        curl -fsSL https://packagecloud.io/install/repositories/pagerduty/rundeck/script.rpm.sh | bash >>"$LOG_FILE" 2>&1
        dnf -y install rundeck >>"$LOG_FILE" 2>&1
    fi
    # Set admin password via realm.properties (plaintext is fine — file is 0640 / root only).
    if [[ -f /etc/rundeck/realm.properties ]]; then
        sed -i.bak -E "s|^admin:[^,]+,(user,admin)$|admin:${RUNDECK_ADMIN},\1|" /etc/rundeck/realm.properties
    fi
    if [[ -f /etc/rundeck/rundeck-config.properties ]]; then
        sed -i -E "s|^grails.serverURL=.*|grails.serverURL=${RUNDECK_URL}|" /etc/rundeck/rundeck-config.properties
    fi
    systemctl enable --now rundeckd >>"$LOG_FILE" 2>&1
    ok "Rundeck at $RUNDECK_URL (user admin)"
}
qa_phase6_rundeck() {
    rpm -q rundeck >/dev/null 2>&1 || { warn "rundeck rpm not installed"; return 1; }
    systemctl is-active --quiet rundeckd || { warn "rundeckd service not active"; return 1; }
    # Rundeck startup is slow; allow up to ~60s for the listener to come up.
    local i
    for i in {1..30}; do
        curl -fs --max-time 3 "${RUNDECK_URL%/}/menu/home" >/dev/null 2>&1 && break
        sleep 2
    done
    curl -fs --max-time 3 "${RUNDECK_URL%/}/menu/home" >/dev/null 2>&1 || \
        { warn "rundeck HTTP did not respond at $RUNDECK_URL"; return 1; }
    log "QA: rundeck responding at $RUNDECK_URL"
}

# --- Phase 7: Ollama ---------------------------------------------------------
phase7_ollama() {
    if ! command -v ollama >/dev/null 2>&1; then
        curl -fsSL https://ollama.com/install.sh | sh >>"$LOG_FILE" 2>&1
    fi
    systemctl enable --now ollama >>"$LOG_FILE" 2>&1 || true
    # The pull is large; let it run but don't fail the whole bootstrap if it stalls.
    if ! timeout 1800 ollama pull "$OLLAMA_MODEL" >>"$LOG_FILE" 2>&1; then
        warn "ollama pull $OLLAMA_MODEL did not finish in 30 min — retry manually"
    fi
    ok "Ollama listening on $OLLAMA_BASE"
}
qa_phase7_ollama() {
    command -v ollama >/dev/null 2>&1 || { warn "ollama binary missing"; return 1; }
    curl -fs --max-time 5 "${OLLAMA_BASE%/}/api/tags" >/dev/null 2>&1 || \
        { warn "ollama API at $OLLAMA_BASE not responding"; return 1; }
    if ! ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$OLLAMA_MODEL"; then
        warn "model $OLLAMA_MODEL not present in 'ollama list'"
        return 1
    fi
    log "QA: ollama up, model $OLLAMA_MODEL pulled"
}

# --- Phase 8: Chatbot service (gunicorn + LiteLLM) ---------------------------
phase8_chatbot() {
    if [[ ! -d "$SCRIPT_DIR/AI" ]]; then
        warn "$SCRIPT_DIR/AI not found — skipping chatbot phase"
        return 99
    fi
    python3 -m pip install --quiet -r "$SCRIPT_DIR/AI/requirements.txt" >>"$LOG_FILE" 2>&1

    # Worker sizing — tune through env in the unit (GUNICORN_WORKERS / _THREADS).
    GUNICORN_BIN="$(command -v gunicorn || echo /usr/local/bin/gunicorn)"

    cat >/etc/systemd/system/dba-chatbot.service <<UNIT
[Unit]
Description=DBA Info Chatbot — unified MSSQL + Oracle, gunicorn, LiteLLM
After=network-online.target ollama.service influxdb.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR/AI

# --- core config ---
Environment=SETUP_YAML=$SETUP_YAML
Environment=FLASK_HOST=$FLASK_HOST
Environment=FLASK_PORT=$FLASK_PORT
Environment=PYTHONUNBUFFERED=1
Environment=LOG_LEVEL=INFO

# --- LiteLLM tunables (override per host as needed) ---
# LITELLM_MODEL forces a specific model (e.g. "anthropic/claude-sonnet-4-6").
# If unset, settings.py picks the best available based on which API keys
# are present (ANTHROPIC_API_KEY > OPENAI_API_KEY > ollama/<OLLAMA_MODEL>).
# Environment=LITELLM_MODEL=anthropic/claude-sonnet-4-6
# Environment=ANTHROPIC_API_KEY=
# Environment=OPENAI_API_KEY=
Environment=LITELLM_TIMEOUT=60
Environment=LITELLM_NUM_RETRIES=2

# --- gunicorn worker sizing ---
Environment=GUNICORN_WORKERS=4
Environment=GUNICORN_THREADS=8
Environment=GUNICORN_TIMEOUT=300

ExecStart=$GUNICORN_BIN -c $SCRIPT_DIR/AI/gunicorn_conf.py app:app

Restart=on-failure
RestartSec=5
TimeoutStopSec=30

# --- hardening ---
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now dba-chatbot >>"$LOG_FILE" 2>&1
    ok "Chatbot at http://$NEW_HOST:$FLASK_PORT (4 workers × 8 threads = 32 concurrent users)"
}
qa_phase8_chatbot() {
    [[ -f /etc/systemd/system/dba-chatbot.service ]] || { warn "dba-chatbot unit missing"; return 1; }
    systemctl is-active --quiet dba-chatbot || { warn "dba-chatbot service not active"; return 1; }
    # Give gunicorn a few seconds to bind.
    local i
    for i in {1..10}; do
        curl -fs --max-time 3 "http://127.0.0.1:${FLASK_PORT}/" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -fs --max-time 3 "http://127.0.0.1:${FLASK_PORT}/" >/dev/null 2>&1 || \
        { warn "chatbot HTTP not responding on :$FLASK_PORT"; return 1; }
    log "QA: chatbot service active on :$FLASK_PORT"
}

# --- Phase 8b: nightly auto-onboarding cron ----------------------------------
# Installs a cron.d job that runs auto_onboard.yml every night, pushing each
# flavor's dba_automation.yaml to hosts newly added to /etc/ansible/hosts
# (those without the onboarding marker). A vault password file at
# /etc/aacu/.vault_pass is used automatically when present (unattended runs
# can't prompt).
phase8b_autoonboard() {
    if [[ ! -f "$SCRIPT_DIR/auto_onboard.yml" ]]; then
        warn "auto_onboard.yml not found in $SCRIPT_DIR — skipping"
        return 99
    fi
    local cron_file=/etc/cron.d/aacu-auto-onboard
    cat > "$cron_file" <<EOF
# Nightly auto-onboarding of newly added DB hosts (managed by bootstrap.sh).
# Pushes MSSQL/Oracle/Db2 dba_automation to hosts missing the onboarding marker.
SHELL=/bin/bash
30 1 * * * root cd $SCRIPT_DIR && ansible-playbook -i /etc/ansible/hosts auto_onboard.yml -e onboard_group=pending_onboard \$( [ -f /etc/aacu/.vault_pass ] && echo --vault-password-file /etc/aacu/.vault_pass ) >> /var/log/aacu_auto_onboard.log 2>&1
EOF
    chmod 0644 "$cron_file"
    log "installed nightly auto-onboard cron at $cron_file (01:30 daily)"
}
qa_phase8b_autoonboard() {
    [[ -f /etc/cron.d/aacu-auto-onboard ]] || { warn "auto-onboard cron not installed"; return 1; }
    log "QA: nightly auto-onboard cron present"
}

# --- Phase 9: ticktator ------------------------------------------------------
phase9_ticktator() {
    if [[ ! -f "$SCRIPT_DIR/ticktator.py" ]]; then
        warn "ticktator.py not found in $SCRIPT_DIR — skipping"
        return 99
    fi
    SITE_NOTIF="/omd/sites/$CHECKMK_SITE/local/share/check_mk/notifications"
    if [[ -d "$SITE_NOTIF" ]]; then
        install -m 0755 -o "$CHECKMK_SITE" -g "$CHECKMK_SITE" "$SCRIPT_DIR/ticktator.py" "$SITE_NOTIF/ticktator"
        cat >/etc/default/ticktator <<ENV
# Generated by bootstrap.sh from setup.yaml
SNOW_INSTANCE="$SNOW_INSTANCE"
SNOW_USER="$SNOW_USER"
SNOW_PASS="$SNOW_PASS"
SNOW_ASSIGNMENT_GROUP="$SNOW_GROUP"
TICKTATOR_DEDUP_HOURS="$SNOW_DEDUP"
ENV
        chmod 0600 /etc/default/ticktator
        mkdir -p /var/lib/ticktator
        ok "ticktator at $SITE_NOTIF/ticktator (env: /etc/default/ticktator)"
    else
        warn "$SITE_NOTIF not present yet — re-run with --tags ticktator after the CheckMK site starts"
        return 1
    fi
}
qa_phase9_ticktator() {
    local notif="/omd/sites/$CHECKMK_SITE/local/share/check_mk/notifications/ticktator"
    [[ -x "$notif" ]] || { warn "$notif missing or not executable"; return 1; }
    [[ -f /etc/default/ticktator ]] || { warn "/etc/default/ticktator missing"; return 1; }
    [[ -d /var/lib/ticktator ]] || { warn "/var/lib/ticktator missing"; return 1; }
    log "QA: ticktator notification handler installed"
}

# --- Phase 10: firewall ------------------------------------------------------
phase10_firewall() {
    systemctl enable --now firewalld >>"$LOG_FILE" 2>&1
    for port in $FW_PORTS; do
        firewall-cmd --permanent --add-port="$port" >>"$LOG_FILE" 2>&1 || true
    done
    firewall-cmd --reload >>"$LOG_FILE" 2>&1
    ok "Opened ports: $FW_PORTS"
}
qa_phase10_firewall() {
    systemctl is-active --quiet firewalld || { warn "firewalld not active"; return 1; }
    local open
    open="$(firewall-cmd --list-ports 2>/dev/null || true)"
    local missing=()
    for port in $FW_PORTS; do
        grep -qw -- "$port" <<<"$open" || missing+=("$port")
    done
    if (( ${#missing[@]} )); then
        warn "ports not open: ${missing[*]}"
        return 1
    fi
    log "QA: firewalld active, ports open: $FW_PORTS"
}

# =============================================================================
# Run each phase through the QA + retry/skip/continue wrapper.
# =============================================================================
run_phase "Phase 1: base packages"           ""              phase1_base_packages   qa_phase1_base_packages
run_phase "Phase 3: Ansible + collections"   ""              phase3_ansible         qa_phase3_ansible
run_phase "Phase 3b: GitHub CLI (gh)"        SKIP_GITHUB     phase3b_github_cli     qa_phase3b_github_cli
run_phase "Phase 4: InfluxDB ${INFLUXDB_VERSION}" SKIP_INFLUXDB phase4_influxdb     qa_phase4_influxdb
run_phase "Phase 5: CheckMK Raw (site=$CHECKMK_SITE)" SKIP_CHECKMK phase5_checkmk   qa_phase5_checkmk
run_phase "Phase 5b: nagflux ${NAGFLUX_VERSION}" SKIP_NAGFLUX phase5b_nagflux       qa_phase5b_nagflux
run_phase "Phase 6: Rundeck"                 SKIP_RUNDECK    phase6_rundeck         qa_phase6_rundeck
run_phase "Phase 7: Ollama + model $OLLAMA_MODEL" SKIP_OLLAMA phase7_ollama         qa_phase7_ollama
run_phase "Phase 8: DBA chatbot"             SKIP_CHATBOT    phase8_chatbot         qa_phase8_chatbot
run_phase "Phase 8b: nightly auto-onboard"   SKIP_AUTOONBOARD phase8b_autoonboard   qa_phase8b_autoonboard
run_phase "Phase 9: ticktator"               SKIP_TICKTATOR  phase9_ticktator       qa_phase9_ticktator
run_phase "Phase 10: firewalld"              SKIP_FIREWALL   phase10_firewall       qa_phase10_firewall

# --- summary -----------------------------------------------------------------
cat <<SUMMARY

${c_green}========== bootstrap complete ==========${c_off}
  hostname    : $NEW_HOST
  CheckMK     : http://$NEW_HOST/${CHECKMK_SITE}/   (cmkadmin)
  Rundeck     : $RUNDECK_URL                        (admin)
  InfluxDB    : http://$NEW_HOST:8086               db=$INFLUX_DB
  Ollama      : $OLLAMA_BASE                        model=$OLLAMA_MODEL
  Chatbot     : http://$NEW_HOST:$FLASK_PORT
  Log file    : $LOG_FILE

Next steps:
  1. Add Windows SQL hosts to /etc/ansible/hosts under [sql_servers]
  2. ansible-playbook -i /etc/ansible/hosts $SCRIPT_DIR/MSSQL/dba_automation.yaml --ask-vault-pass
  3. In CheckMK WATO, add a notification rule that invokes 'ticktator'
  4. In Rundeck, register the SQL hosts (rundeckfacts.py provides the facts)
SUMMARY
