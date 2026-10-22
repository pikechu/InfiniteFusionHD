#!/usr/bin/env bash
# Run explicitly on the future Linux server. Never invoked by local validation.
set -euo pipefail
umask 027

APP=/opt/kif-mmo
RELEASES=$APP/releases
CONFIG=/etc/kif-mmo/production.json
DATA=/var/lib/kif-mmo
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MANAGER=$SCRIPT_DIR/../release_manager.py

die() { printf '%s\n' "$*" >&2; exit 1; }
preflight() {
    [[ $(uname -s) == Linux ]] || die 'These host-management actions require Linux; use the local verifier on Windows.'
    [[ $EUID == 0 ]] || die 'Run host-management actions as root.'
    for command in python3 systemctl runuser curl ss; do command -v "$command" >/dev/null || die "Missing prerequisite: $command"; done
    python3 -c 'import sys; assert sys.version_info >= (3,12), "Python 3.12+ required"'
    [[ -x /opt/kif-mmo/tools/caddy && -x /opt/kif-mmo/tools/restic ]] || die 'Run the explicit install-tools.py prerequisite first.'
}
release_path() {
    [[ ${1:-} =~ ^[0-9a-f]{12}-[0-9a-f]{12}$ ]] || die 'Use the exact version from the release build.'
    [[ -d $RELEASES/$1 && ! -L $RELEASES/$1 ]] || die 'Release is not prepared.'
    python3 "$MANAGER" verify --releases "$RELEASES" --version "$1" >&2
    printf '%s\n' "$RELEASES/$1"
}
ops() {
    local release=$1; shift
    runuser -u kif-mmo -- "$release/venv/bin/python" "$release/server/multiplayer/production_ops.py" --config "$CONFIG" --release-dir "$release" "$@"
}
fix_data_owner() {
    local path
    for path in "$DATA/multiplayer.sqlite3" "$DATA/multiplayer.sqlite3.instance.lock" "$DATA/maintenance.instance.lock"; do
        [[ ! -f $path ]] || chown kif-mmo:kif-mmo "$path"
    done
    [[ ! -f /etc/kif-mmo/data-id ]] || { chown root:kif-mmo /etc/kif-mmo/data-id; chmod 0640 /etc/kif-mmo/data-id; }
}
wait_backup() {
    local deadline=$((SECONDS + 730))
    while systemctl is-active --quiet kif-mmo-backup.service; do
        (( SECONDS < deadline )) || die 'Existing backup did not finish; no data was replaced.'
        sleep 2
    done
}
prepare() (
    umask 022
    local archive release
    archive=$(readlink -f -- "${1:?archive required}")
    python3 - "$archive" <<'PY'
import hashlib,re,sys
from pathlib import Path
p=Path(sys.argv[1]); fields=p.with_name(p.name+'.sha256').read_text().split()
if len(fields)!=2 or fields[1]!=p.name or not re.fullmatch('[a-f0-9]{64}',fields[0]): raise SystemExit('Invalid release checksum sidecar')
with p.open('rb') as f: actual=hashlib.file_digest(f,'sha256').hexdigest()
if actual!=fields[0]: raise SystemExit('Release archive checksum mismatch')
PY
    install -d -m 0755 "$APP" "$RELEASES"
    release=$(python3 "$MANAGER" stage --archive "$archive" --releases "$RELEASES")
    [[ -x $release/venv/bin/python ]] || python3 -m venv "$release/venv"
    "$release/venv/bin/python" -m pip install --no-index --find-links "$release/wheels" --require-hashes -r "$release/server/multiplayer/requirements-production.lock" >&2
    # --check-config also loads the WSGI factory, which deliberately refuses an
    # uninitialized data disk. Validate settings without starting the app here.
    "$release/venv/bin/python" - "$release/server/multiplayer/deploy/gunicorn.conf.py" <<'PY' >&2
import runpy,sys
from gunicorn.config import Config
c=Config()
for key,value in runpy.run_path(sys.argv[1]).items():
    if key in c.settings: c.set(key,value)
assert c.workers==1 and not c.preload_app and not c.reload
print('GUNICORN_SETTINGS_VALID')
PY
    printf '%s\n' "$release"
)
setup() {
    local release=$1 unit
    getent group kif-mmo >/dev/null || groupadd --system kif-mmo
    id kif-mmo >/dev/null 2>&1 || useradd --system --gid kif-mmo --home-dir "$DATA" --no-create-home --shell /usr/sbin/nologin kif-mmo
    getent group caddy >/dev/null || groupadd --system caddy
    id caddy >/dev/null 2>&1 || useradd --system --gid caddy --home-dir /var/lib/kif-mmo-caddy --no-create-home --shell /usr/sbin/nologin caddy
    install -d -o kif-mmo -g kif-mmo -m 0700 "$DATA" "$DATA/backup-staging"
    install -d -o root -g kif-mmo -m 0750 /etc/kif-mmo
    install -d -o root -g caddy -m 0750 /etc/kif-mmo-caddy
    [[ -f $CONFIG ]] || install -o root -g kif-mmo -m 0640 "$release/server/multiplayer/deploy/production.json" "$CONFIG"
    [[ -f /etc/kif-mmo/backup-credentials.json ]] || install -o root -g kif-mmo -m 0640 "$release/server/multiplayer/deploy/backup-credentials.example.json" /etc/kif-mmo/backup-credentials.json
    [[ -f /etc/kif-mmo/restic-repository ]] || printf '%s\n' UNCONFIGURED > /etc/kif-mmo/restic-repository
    if [[ ! -f /etc/kif-mmo/restic-password ]]; then
        python3 - <<'PY'
import os,secrets
fd=os.open('/etc/kif-mmo/restic-password',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o640)
with os.fdopen(fd,'w') as f: f.write(secrets.token_hex(32)+'\n')
PY
    fi
    chown root:kif-mmo /etc/kif-mmo/restic-repository /etc/kif-mmo/restic-password
    chmod 0640 /etc/kif-mmo/restic-repository /etc/kif-mmo/restic-password
    for unit in "$release"/server/multiplayer/deploy/*.service "$release"/server/multiplayer/deploy/*.timer; do
        install -m 0644 "$unit" "/etc/systemd/system/$(basename -- "$unit")"
    done
    systemctl daemon-reload
    printf 'Prepared %s. No service has been started. Configure the repository, then explicitly initialize data.\n' "$(basename -- "$release")"
}
health() {
    local attempt
    for attempt in {1..15}; do
        if curl --fail --silent --max-time 2 -H 'X-KIF-Client-IP:127.0.0.1' http://127.0.0.1:8765/v1/health >/dev/null; then return 0; fi
        sleep 1
    done
    return 1
}
activate() (
    local release=$1 previous='' backup_release=$1
    local timer_active=0 cutover=0 proxy_changed=0
    systemctl is-active --quiet kif-mmo-backup.timer && timer_active=1
    cleanup_activation() {
        local result=$?
        trap - EXIT
        set +e
        if (( result != 0 && cutover == 1 )); then
            systemctl stop kif-mmo.service
            if [[ -n $previous ]]; then
                python3 "$MANAGER" activate --releases "$RELEASES" --version "$(basename -- "$previous")"
                systemctl start kif-mmo.service
            fi
            if (( proxy_changed == 1 )) && [[ -f /etc/kif-mmo-caddy/Caddyfile.previous ]]; then
                cp -p -- /etc/kif-mmo-caddy/Caddyfile.previous /etc/kif-mmo-caddy/Caddyfile
                systemctl is-active --quiet kif-mmo-proxy.service && systemctl reload kif-mmo-proxy.service
            fi
        fi
        (( timer_active == 0 )) || systemctl start kif-mmo-backup.timer
        exit "$result"
    }
    trap cleanup_activation EXIT
    [[ ! -L $APP/current ]] || previous=$(readlink -f -- "$APP/current")
    if [[ -n $previous ]]; then
        [[ $(dirname -- "$previous") == "$RELEASES" ]] || die 'Current release is outside the managed root.'
        backup_release=$previous
    fi
    ops "$release" verify
    systemctl stop kif-mmo-backup.timer
    wait_backup
    ops "$backup_release" backup || die 'Verified encrypted pre-deployment backup is required.'
    "$release/venv/bin/python" "$release/server/multiplayer/release_manager.py" render-proxy --config "$CONFIG" --output /etc/kif-mmo-caddy/Caddyfile.pending
    /opt/kif-mmo/tools/caddy adapt --config /etc/kif-mmo-caddy/Caddyfile.pending --adapter caddyfile >/dev/null
    if ! systemctl is-active --quiet kif-mmo-proxy.service; then
        [[ -z $(ss -H -ltn '( sport = :80 or sport = :443 or sport = :2020 )') ]] || die 'Proxy ports are already in use; integrate the vhost explicitly instead of stopping another service.'
    fi
    systemctl stop kif-mmo.service
    cutover=1
    python3 "$MANAGER" activate --releases "$RELEASES" --version "$(basename -- "$release")"
    if ! systemctl start kif-mmo.service || ! health; then
        die 'New code failed health checks; previous compatible code restored when available. Database was not rolled back.'
    fi
    chown root:caddy /etc/kif-mmo-caddy/Caddyfile.pending
    chmod 0640 /etc/kif-mmo-caddy/Caddyfile.pending
    [[ ! -f /etc/kif-mmo-caddy/Caddyfile ]] || cp -p -- /etc/kif-mmo-caddy/Caddyfile /etc/kif-mmo-caddy/Caddyfile.previous
    proxy_changed=1
    mv -f -- /etc/kif-mmo-caddy/Caddyfile.pending /etc/kif-mmo-caddy/Caddyfile
    if systemctl is-active --quiet kif-mmo-proxy.service; then systemctl reload kif-mmo-proxy.service; else systemctl start kif-mmo-proxy.service; fi
    systemctl enable kif-mmo.service kif-mmo-proxy.service kif-mmo-backup.timer kif-mmo-maintenance.timer kif-mmo-monitor.timer
    systemctl start kif-mmo-backup.timer kif-mmo-maintenance.timer kif-mmo-monitor.timer
    printf 'Activated %s. Verify public HTTPS from both clients before opening registration to players.\n' "$(basename -- "$release")"
)
restore_service() (
    local snapshot_id=$1 release timer_active=0 app_active=0 changed=0
    release=$(readlink -f -- "$APP/current")
    [[ $(dirname -- "$release") == "$RELEASES" ]] || die 'No managed current release.'
    systemctl is-active --quiet kif-mmo-backup.timer && timer_active=1
    systemctl is-active --quiet kif-mmo.service && app_active=1
    cleanup_restore() {
        local result=$?
        trap - EXIT
        set +e
        fix_data_owner
        if (( app_active == 1 || changed == 1 )); then systemctl start kif-mmo.service; fi
        if (( timer_active == 1 )); then systemctl start kif-mmo-backup.timer; fi
        exit "$result"
    }
    trap cleanup_restore EXIT
    systemctl stop kif-mmo-backup.timer
    wait_backup
    systemctl stop kif-mmo.service
    # Root is required to restore ownership metadata when the new machine's
    # service UID differs. No-cache prevents root-owned entries in the worker cache.
    "$release/venv/bin/python" "$release/server/multiplayer/production_ops.py" --config "$CONFIG" --release-dir "$release" restore --snapshot "$snapshot_id"
    changed=1
    fix_data_owner
    systemctl start kif-mmo.service
    health || die 'Restored database did not pass health checks.'
    ops "$release" backup
)

action=${1:-help}; shift || true
if [[ $action == help ]]; then
    printf '%s\n' 'Actions: setup ARCHIVE | prepare ARCHIVE | init-db VERSION [SOURCE] | repo-init VERSION | activate VERSION | rollback VERSION | restore SNAPSHOT | backup | status | repo-prune'
    exit 0
fi
preflight
case "$action" in
    prepare) prepare "${1:?archive required}" ;;
    setup) release=$(prepare "${1:?archive required}"); setup "$release" ;;
    init-db)
        release=$(release_path "${1:?version required}")
        args=(); [[ $# -lt 2 ]] || args=(--source "$(readlink -f -- "$2")")
        "$release/venv/bin/python" "$release/server/multiplayer/production_ops.py" --config "$CONFIG" --release-dir "$release" init-db "${args[@]}"
        fix_data_owner ;;
    repo-init) release=$(release_path "${1:?version required}"); ops "$release" repo-init ;;
    activate|rollback) release=$(release_path "${1:?version required}"); activate "$release" ;;
    restore)
        [[ ${1:-} =~ ^[a-f0-9]{64}$ ]] || die 'Use an explicit full snapshot ID.'
        restore_service "$1" ;;
    backup|status|repo-prune)
        release=$(readlink -f -- "$APP/current")
        [[ $(dirname -- "$release") == "$RELEASES" ]] || die 'No managed current release.'
        if [[ $action == status ]]; then ops "$release" verify; ops "$release" backup-status
        elif [[ $action == repo-prune ]]; then
            timer_was_active=0
            systemctl is-active --quiet kif-mmo-backup.timer && timer_was_active=1
            trap '(( timer_was_active == 0 )) || systemctl start kif-mmo-backup.timer' EXIT
            systemctl stop kif-mmo-backup.timer; wait_backup
            ops "$release" repo-prune; ops "$release" backup
        else ops "$release" backup; fi ;;
    *) die 'Unknown action. Run manage.sh help.' ;;
esac
