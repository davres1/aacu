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
# Skip phases with env vars (each accepts 1/true to skip):
#   SKIP_GITHUB, SKIP_INFLUXDB, SKIP_CHECKMK, SKIP_NAGFLUX, SKIP_RUNDECK,
#   SKIP_OLLAMA, SKIP_CHATBOT, SKIP_TICKTATOR, SKIP_FIREWALL
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

# --- Phase 1: base packages ---------------------------------------------------
phase "Phase 1: base packages"
dnf -y install epel-release >>"$LOG_FILE" 2>&1 || true
dnf -y install python3 python3-pip git curl wget firewalld rsync tar openssl \
               ca-certificates jq >>"$LOG_FILE" 2>&1
python3 -m pip install --quiet --upgrade pip pyyaml >>"$LOG_FILE" 2>&1
ok "Python $(python3 -V | awk '{print $2}'), pip ready"

# --- Phase 2: load setup.yaml into shell variables ----------------------------
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

# --- Phase 3: Ansible ---------------------------------------------------------
phase "Phase 3: Ansible toolkit + Windows collections"
# Match the chatbot's AI/requirements.txt so anyone pip-installing from there
# gets the same set we pre-install systemwide here. ansible (meta) pulls in
# ansible-core; the rest are operator-friendly extras.
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

# --- Phase 3b: GitHub CLI ----------------------------------------------------
if skip SKIP_GITHUB; then
    warn "Phase 3b: GitHub CLI — SKIPPED"
else
    phase "Phase 3b: GitHub CLI (gh)"
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
            # it in the running user's gh config (~/.config/gh/). Suppress the
            # token from the log file.
            if printf '%s' "$GH_AUTH_TOKEN" | gh auth login --with-token >/dev/null 2>&1; then
                ok "gh $(gh --version | awk 'NR==1 {print $3}') installed and authenticated"
            else
                warn "gh installed but auth failed — verify token scopes (needs 'repo')"
            fi
        else
            ok "gh $(gh --version | awk 'NR==1 {print $3}') installed (no token supplied — run 'gh auth login' to sign in)"
        fi
    fi
fi

# --- Phase 4: InfluxDB -------------------------------------------------------
if skip SKIP_INFLUXDB; then
    warn "Phase 4: InfluxDB — SKIPPED"
else
    phase "Phase 4: InfluxDB ${INFLUXDB_VERSION}"
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
fi

# --- Phase 5: CheckMK Raw ----------------------------------------------------
if skip SKIP_CHECKMK; then
    warn "Phase 5: CheckMK — SKIPPED"
else
    phase "Phase 5: CheckMK Raw (site=$CHECKMK_SITE)"
    if ! command -v omd >/dev/null 2>&1; then
        # Look for an RPM in files/ first; the user can drop any supported version there.
        cmk_rpm="$(ls -1 "$SCRIPT_DIR"/files/check-mk-raw-*.rpm 2>/dev/null | sort -V | tail -1)"
        if [[ -z $cmk_rpm ]]; then
            die "CheckMK RPM not found. Download from https://checkmk.com/download and place in $SCRIPT_DIR/files/"
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
fi

# --- Phase 5b: nagflux (CheckMK Raw -> InfluxDB) -----------------------------
if skip SKIP_NAGFLUX; then
    warn "Phase 5b: nagflux — SKIPPED"
elif ! command -v omd >/dev/null 2>&1; then
    warn "Phase 5b: nagflux — needs CheckMK/OMD, but it's not installed; SKIPPED"
else
    phase "Phase 5b: nagflux ${NAGFLUX_VERSION}"
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
fi

# --- Phase 6: Rundeck --------------------------------------------------------
if skip SKIP_RUNDECK; then
    warn "Phase 6: Rundeck — SKIPPED"
else
    phase "Phase 6: Rundeck"
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
fi

# --- Phase 7: Ollama ---------------------------------------------------------
if skip SKIP_OLLAMA; then
    warn "Phase 7: Ollama — SKIPPED"
else
    phase "Phase 7: Ollama + model $OLLAMA_MODEL"
    if ! command -v ollama >/dev/null 2>&1; then
        curl -fsSL https://ollama.com/install.sh | sh >>"$LOG_FILE" 2>&1
    fi
    systemctl enable --now ollama >>"$LOG_FILE" 2>&1 || true
    # The pull is large; let it run but don't fail the whole bootstrap if it stalls.
    if ! timeout 1800 ollama pull "$OLLAMA_MODEL" >>"$LOG_FILE" 2>&1; then
        warn "ollama pull $OLLAMA_MODEL did not finish in 30 min — retry manually"
    fi
    ok "Ollama listening on $OLLAMA_BASE"
fi

# --- Phase 8: Chatbot service (gunicorn + LiteLLM) ---------------------------
if skip SKIP_CHATBOT; then
    warn "Phase 8: Chatbot — SKIPPED"
elif [[ ! -d "$SCRIPT_DIR/AI" ]]; then
    warn "Phase 8: $SCRIPT_DIR/AI not found — SKIPPED"
else
    phase "Phase 8: DBA chatbot (gunicorn + LiteLLM)"
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
fi

# --- Phase 9: ticktator ------------------------------------------------------
if skip SKIP_TICKTATOR; then
    warn "Phase 9: ticktator — SKIPPED"
elif [[ ! -f "$SCRIPT_DIR/ticktator.py" ]]; then
    warn "Phase 9: ticktator.py not found — SKIPPED"
else
    phase "Phase 9: ticktator notification handler"
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
    fi
fi

# --- Phase 10: firewall ------------------------------------------------------
if skip SKIP_FIREWALL; then
    warn "Phase 10: firewall — SKIPPED"
else
    phase "Phase 10: firewalld"
    systemctl enable --now firewalld >>"$LOG_FILE" 2>&1
    for port in $FW_PORTS; do
        firewall-cmd --permanent --add-port="$port" >>"$LOG_FILE" 2>&1 || true
    done
    firewall-cmd --reload >>"$LOG_FILE" 2>&1
    ok "Opened ports: $FW_PORTS"
fi

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
  2. ansible-playbook -i /etc/ansible/hosts $SCRIPT_DIR/dba_automation.yaml --ask-vault-pass
  3. In CheckMK WATO, add a notification rule that invokes 'ticktator'
  4. In Rundeck, register the SQL hosts (rundeckfacts.py provides the facts)
SUMMARY
