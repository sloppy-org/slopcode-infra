#!/usr/bin/env bash
# Idempotent installer for the slopgate watchdog system.
#
# Primary + weekly summary on the leader (faepmac1, launchd).
# Reverse watchdog on chat.computor.at (Linux, systemd).
#
# Reuses the computor-infra env file for SMTP credentials and the
# chat.computor.at SSH parameters. Pulls the slopbot zuliprc from
# chat.computor.at on first run.
#
# Usage:
#   install_slopgate_watchdog.sh           # both targets
#   install_slopgate_watchdog.sh leader    # primary + summary only
#   install_slopgate_watchdog.sh reverse   # reverse only
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPUTOR_INFRA="${COMPUTOR_INFRA:-$HOME/infra/computor-infra}"

# shellcheck disable=SC1091
source "$COMPUTOR_INFRA/lib.sh"

require_var SMTP_USER
require_var SMTP_PASSWORD
require_var WATCHDOG_INCIDENT_MAIL

TARGET="${1:-both}"
FAEPMAC1="${FAEPMAC1:-faepmac1}"

LOCAL_ZULIPRC="$COMPUTOR_INFRA/.slopbot.zuliprc"
if [[ ! -f "$LOCAL_ZULIPRC" ]]; then
    log "fetching slopbot zuliprc from chat.computor.at"
    scp -q -P "$COMPUTOR_SSH_PORT" "root@$COMPUTOR_HOST_IP:/etc/slopbot/zuliprc" "$LOCAL_ZULIPRC"
    chmod 0600 "$LOCAL_ZULIPRC"
fi

install_leader() {
    log "bootstrapping slopgate primary watchdog on $FAEPMAC1"

    for f in slopgate_watchdog_lib.sh slopgate_watchdog.sh slopgate_watchdog_summary.sh; do
        scp -q "$SCRIPT_DIR/$f" "${FAEPMAC1}:/tmp/$f"
    done
    scp -q "$LOCAL_ZULIPRC" "${FAEPMAC1}:/tmp/slopgate_zuliprc"

    SMTP_USER_VAL="$SMTP_USER"
    SMTP_PASS_VAL="$SMTP_PASSWORD"
    INCIDENT_MAIL="$WATCHDOG_INCIDENT_MAIL"
    HB_SSH_TARGET="root@${COMPUTOR_HOST_IP}"
    HB_SSH_PORT="${COMPUTOR_SSH_PORT:-22}"
    HB_REMOTE_PATH="/var/lib/slopgate-watchdog/primary-heartbeat"

    ssh "$FAEPMAC1" bash -s <<REMOTE
set -euo pipefail

if ! command -v msmtp >/dev/null 2>&1; then
    echo "[faepmac1] installing msmtp via brew"
    brew install msmtp
fi

mkdir -p ~/.config/slopgate-watchdog ~/.local/share/slopgate-watchdog ~/bin

install -m 0600 /tmp/slopgate_zuliprc ~/.config/slopgate-watchdog/zuliprc
rm -f /tmp/slopgate_zuliprc

CERT_FILE=/usr/local/etc/openssl@3/cert.pem
[ -f "\$CERT_FILE" ] || CERT_FILE=/etc/ssl/cert.pem
cat >~/.config/slopgate-watchdog/msmtprc <<RC
defaults
tls on
tls_starttls on
tls_trust_file \$CERT_FILE

account tugraz
host mailrelay.tugraz.at
port 587
auth on
user ${SMTP_USER_VAL}
password ${SMTP_PASS_VAL}
from albert@tugraz.at

account default : tugraz
RC
chmod 0600 ~/.config/slopgate-watchdog/msmtprc

install -m 0755 /tmp/slopgate_watchdog.sh         ~/bin/slopgate-watchdog
install -m 0644 /tmp/slopgate_watchdog_lib.sh     ~/bin/slopgate_watchdog_lib.sh
install -m 0755 /tmp/slopgate_watchdog_summary.sh ~/bin/slopgate-watchdog-summary
rm -f /tmp/slopgate_watchdog.sh /tmp/slopgate_watchdog_lib.sh /tmp/slopgate_watchdog_summary.sh

cat >~/.config/slopgate-watchdog/env.sh <<ENV
export WATCHDOG_ZULIPRC="\$HOME/.config/slopgate-watchdog/zuliprc"
export WATCHDOG_STATE_DIR="\$HOME/.local/share/slopgate-watchdog"
export WATCHDOG_INCIDENT_MAIL="${INCIDENT_MAIL}"
export MSMTP_CONFIG="\$HOME/.config/slopgate-watchdog/msmtprc"
export WATCHDOG_HEARTBEAT_SSH_TARGET="${HB_SSH_TARGET}"
export WATCHDOG_HEARTBEAT_SSH_PORT="${HB_SSH_PORT}"
export WATCHDOG_HEARTBEAT_REMOTE_PATH="${HB_REMOTE_PATH}"
ENV

cat >~/bin/slopgate-watchdog-run <<'WRAP'
#!/bin/bash
source "\$HOME/.config/slopgate-watchdog/env.sh"
export MSMTPRC="\$HOME/.config/slopgate-watchdog/msmtprc"
exec "\$HOME/bin/slopgate-watchdog"
WRAP
chmod +x ~/bin/slopgate-watchdog-run

cat >~/bin/slopgate-watchdog-summary-run <<'WRAP'
#!/bin/bash
source "\$HOME/.config/slopgate-watchdog/env.sh"
export MSMTPRC="\$HOME/.config/slopgate-watchdog/msmtprc"
exec "\$HOME/bin/slopgate-watchdog-summary"
WRAP
chmod +x ~/bin/slopgate-watchdog-summary-run

HOME_DIR=\$HOME
PLIST_DIR=~/Library/LaunchAgents
mkdir -p "\$PLIST_DIR"

PLIST_MAIN="\$PLIST_DIR/at.slopgate.watchdog.plist"
cat >"\$PLIST_MAIN" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>         <string>at.slopgate.watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>\${HOME_DIR}/bin/slopgate-watchdog-run</string>
    </array>
    <key>StartInterval</key> <integer>300</integer>
    <key>RunAtLoad</key>     <true/>
    <key>StandardOutPath</key> <string>\${HOME_DIR}/Library/Logs/slopgate-watchdog.log</string>
    <key>StandardErrorPath</key><string>\${HOME_DIR}/Library/Logs/slopgate-watchdog.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>\${HOME_DIR}</string>
        <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLIST

PLIST_SUM="\$PLIST_DIR/at.slopgate.watchdog-summary.plist"
cat >"\$PLIST_SUM" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>         <string>at.slopgate.watchdog-summary</string>
    <key>ProgramArguments</key>
    <array>
        <string>\${HOME_DIR}/bin/slopgate-watchdog-summary-run</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key><integer>1</integer>
        <key>Hour</key>  <integer>6</integer>
        <key>Minute</key><integer>0</integer>
    </dict>
    <key>StandardOutPath</key> <string>\${HOME_DIR}/Library/Logs/slopgate-watchdog-summary.log</string>
    <key>StandardErrorPath</key><string>\${HOME_DIR}/Library/Logs/slopgate-watchdog-summary.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>\${HOME_DIR}</string>
        <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLIST

for plist in "\$PLIST_MAIN" "\$PLIST_SUM"; do
    label=\$(grep -A1 '<key>Label</key>' "\$plist" | tail -1 | sed 's/.*<string>//;s/<\/string>//')
    launchctl bootout "gui/\$(id -u)/\$label" 2>/dev/null || true
    launchctl bootstrap "gui/\$(id -u)" "\$plist" 2>/dev/null || true
done
echo "[faepmac1] slopgate primary + summary watchdogs installed and started"
REMOTE
}

install_reverse() {
    log "bootstrapping slopgate reverse watchdog on $(ssh_target)"

    put_remote "$SCRIPT_DIR/slopgate_watchdog_lib.sh"     "/tmp/slopgate_watchdog_lib.sh"
    put_remote "$SCRIPT_DIR/slopgate_watchdog_reverse.sh" "/tmp/slopgate_watchdog_reverse.sh"

    INCIDENT_MAIL="$WATCHDOG_INCIDENT_MAIL"

    run_remote bash -s <<REMOTE
set -euo pipefail

apt-get -y install msmtp msmtp-mta curl jq >/dev/null 2>&1

install -m 0644 /tmp/slopgate_watchdog_lib.sh     /usr/local/sbin/slopgate_watchdog_lib.sh
install -m 0755 /tmp/slopgate_watchdog_reverse.sh /usr/local/sbin/slopgate-watchdog-reverse
rm -f /tmp/slopgate_watchdog_lib.sh /tmp/slopgate_watchdog_reverse.sh

mkdir -p /var/lib/slopgate-watchdog

cat >/etc/systemd/system/slopgate-watchdog-reverse.service <<SVC
[Unit]
Description=Slopgate reverse watchdog — checks primary heartbeat
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/slopgate-watchdog-reverse
Environment=WATCHDOG_ZULIPRC=/etc/slopbot/zuliprc
Environment=WATCHDOG_STATE_DIR=/var/lib/slopgate-watchdog
Environment=WATCHDOG_INCIDENT_MAIL=${INCIDENT_MAIL}
StandardOutput=journal
StandardError=journal
SVC

cat >/etc/systemd/system/slopgate-watchdog-reverse.timer <<TMR
[Unit]
Description=Slopgate reverse watchdog timer — every 10 min

[Timer]
OnBootSec=17min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now slopgate-watchdog-reverse.timer

STATE_DIR=/var/lib/slopgate-watchdog
mkdir -p "\$STATE_DIR"
if [[ ! -f "\$STATE_DIR/slopgate-watchdog-primary.state" ]]; then
    printf 'ok\n%s\n\n' "\$(date +%s)" > "\$STATE_DIR/slopgate-watchdog-primary.state"
fi

echo "[chat host] slopgate reverse watchdog installed and started"
REMOTE
}

case "$TARGET" in
    leader)  install_leader ;;
    reverse) install_reverse ;;
    both)    install_leader; install_reverse ;;
    *)       echo "usage: $0 [leader|reverse|both]" >&2; exit 2 ;;
esac
