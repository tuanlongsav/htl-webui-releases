#!/bin/sh
# =============================================================================
# bootstrap.sh — install HTL Quectel WebUI on an RM520N (RM5xx) card from the
# signed releases, starting from a freshly flashed firmware. Runs ON THE CARD
# as root (adb shell / ssh); router-install.sh brings it there from a router.
#
#   sh bootstrap.sh [--channel stable|beta] [--dry-run] [--force] [--fresh]
#                   [--any-model] [--lan-ip A.B.C.D]
#   sh bootstrap.sh --status                 what is there; changes nothing
#   sh bootstrap.sh --uninstall [--keep-data]
#
# 1. checks: root, a Quectel card of a model HTL knows (RM520N/521F/530N;
#    the SDX55 RM500Q/502Q/505Q/510Q with a warning, never tried on one;
#    --any-model for the rest — RM551E and RM500U are refused by name),
#    32-bit ARM with systemd, /dev/smd11, /usrdata, free space, and that
#    the release repository answers over HTTPS
# 2. Entware if there is none: the /opt bind mount of quectel-rgmii-toolkit's
#    installentware.sh and nothing else of it (no login/passwd swap, no root
#    shell change, no rc.unslung — it would start a second lighttpd). The
#    steps are the ones run by hand on an RM520N (docs/DEPLOY.md §2).
# 3. the packages HTL needs; install.sh adds the lighttpd modules it wants
# 4. channels.json → the channel's tag → release.json → htlwebui.tar.gz from
#    github.com/tuanlongsav/htl-webui-releases; both JSON files must carry
#    the release key's ed25519 signature (the key is below, the one the cards
#    trust), the package its signed sha256 and size
# 5. install.sh of that package (--lan-ip passed on: the card's LAN gateway,
#    its DHCP range kept, the certificate made for it). Another web UI on the
#    card (QManager, the toolkit's SimpleAdmin, a lighttpd.service) is taken
#    off first by the package's wipe-other.sh — they hold the ports HTL's
#    lighttpd needs; Entware stays. The checks name what will go.
#
# On a card HTL is already on: without options, an upgrade (settings,
# password, certificate and counters kept); --fresh removes it all with the
# package's uninstall.sh and installs from scratch (implies --force).
#
# Run from a file it detaches itself (setsid nohup) and follows its own log,
# /tmp/htl-bootstrap.log: a dropped adb/ssh session does not stop it half-way.
# The same or a newer build already there is left alone (code=already) — unless
# its web server is not running, then the release is installed over it.
# --dry-run stops before changing anything; --force installs the same or an
# older build again; --fresh wipes HTL's install and data first. One run at a time (/tmp/htl-bootstrap.lock).
#
# The last line is for programs (router-install.sh, the Rowa app) — adb
# shell does not pass exit codes on:
#   HTL-BOOTSTRAP: OK code=installed|already|dry_run|uninstalled|status k=v…
#   HTL-BOOTSTRAP: FAILED code=<code> — <what went wrong, for people>
# k=v: build (installed build or none), model, lan (the card's LAN address),
# password (admin: the default, still to be changed; kept; none), webui
# (up/down/none); --status adds other (the other web UIs, comma-joined, or
# none). Codes are listed in docs/DEPLOY.md.
#
# HTL_TEST_* variables are for tests/sh/test-bootstrap.sh only.
# =============================================================================

REPO_SLUG=tuanlongsav/htl-webui-releases
BASE="https://github.com/${REPO_SLUG}/releases/download"
ENTWARE_URL=https://bin.entware.net/armv7sf-k3.2/installer
# What a hand install on an RM520N took (DEPLOY §2); install.sh then asks
# opkg for the lighttpd modules it loads and fails on a missing hard one.
PACKAGES="lighttpd lighttpd-mod-cgi lighttpd-mod-openssl sudo jq openssl-util curl ca-bundle"
ROOT=${HTL_TEST_ROOT:-/usrdata/htlwebui}
WR=${HTL_TEST_CARD:-}
OPT=${HTL_TEST_OPT:-/opt}
USRDATA=${HTL_TEST_USRDATA:-/usrdata}
SYSD=${HTL_TEST_SYSD:-/lib/systemd/system}
LOG=${HTL_TEST_LOG:-/tmp/htl-bootstrap.log}
MIN_FREE_KB=40960
MAX_PKG=16777216
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

# The release key (system/keys/release-ed25519.pub; tests keep them equal).
RELEASE_KEY='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAMf3M9uio1LWhWdn1D3+AfhciR643IMc3lgxSfOyUJAc=
-----END PUBLIC KEY-----'

PATH="${HTL_TEST_PATH:+$HTL_TEST_PATH:}$OPT/bin:$OPT/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
unset LD_LIBRARY_PATH LD_PRELOAD
# `adb shell` runs with umask 000: Entware, its package lists and the units
# made here, and everything install.sh makes, would be writable by everyone.
umask 022

# --- lan_ip_ok IP — a private IPv4 address a LAN gateway can have ----------
# (the same in bootstrap.sh, install.sh and htl-lanip; tests keep them equal)
lan_ip_ok() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        { for (i = 1; i <= 4; i++) if ($i !~ /^(0|[1-9][0-9]?[0-9]?)$/ || $i > 255) exit 1 }
        $4 < 1 || $4 > 254 { exit 1 }
        $1 == 10 { exit 0 }
        $1 == 172 && $2 >= 16 && $2 <= 31 { exit 0 }
        $1 == 192 && $2 == 168 { exit 0 }
        { exit 1 }'
}

usage() {
    echo "usage: sh bootstrap.sh [--channel stable|beta] [--dry-run] [--force] [--fresh] [--any-model] [--lan-ip A.B.C.D]"
    echo "       sh bootstrap.sh --status | --uninstall [--keep-data]"
    exit 2
}
CHANNEL=stable DRY=0 FORCE=0 FRESH=0 FG=0 ANY=0 LANIP="" MODE=install KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --channel)    [ $# -ge 2 ] || usage; CHANNEL=$2; shift ;;
        --channel=*)  CHANNEL=${1#--channel=} ;;
        --dry-run)    DRY=1 ;;
        --force)      FORCE=1 ;;
        --fresh)      FRESH=1 FORCE=1 ;;
        --any-model)  ANY=1 ;;
        --lan-ip)     [ $# -ge 2 ] || usage; LANIP=$2; shift ;;
        --status)     MODE=status ;;
        --uninstall)  MODE=uninstall ;;
        --keep-data)  KEEP=1 ;;
        --foreground) FG=1 ;;
        *) usage ;;
    esac
    shift
done
case "$CHANNEL" in stable|beta) ;; *) usage ;; esac
[ -z "$LANIP" ] || lan_ip_ok "$LANIP" || {
    echo "--lan-ip: a private IPv4 address ending in 1-254 (10.x, 172.16-31.x, 192.168.x)"
    usage
}
[ "$KEEP" = 0 ] || [ "$MODE" = uninstall ] || usage
[ "$FRESH" = 0 ] || [ "$MODE" = install ] || usage
LOCK=${HTL_TEST_LOCK:-/tmp/htl-bootstrap.lock}

# lock_busy — another bootstrap run holds the lock and is alive
lock_busy() {
    _lp=$(cat "$LOCK/pid" 2>/dev/null)
    [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null
}

# --- detach: run from a file, keep going if the session drops ---------------
if [ "$FG" = 0 ] && [ "$MODE" != status ] && [ -f "$0" ] && [ -z "${HTL_TEST_NODETACH:-}" ]; then
    if lock_busy; then
        # Its log is the one being written: leave it be.
        printf '\nHTL-BOOTSTRAP: FAILED code=busy — another install is running on this card (log: %s)\n' "$LOG"
        exit 1
    fi
    _args=""
    [ "$DRY" = 1 ] && _args="$_args --dry-run"
    [ "$FORCE" = 1 ] && _args="$_args --force"
    [ "$FRESH" = 1 ] && _args="$_args --fresh"
    [ "$ANY" = 1 ] && _args="$_args --any-model"
    [ -n "$LANIP" ] && _args="$_args --lan-ip $LANIP"
    [ "$MODE" = uninstall ] && _args="$_args --uninstall"
    [ "$KEEP" = 1 ] && _args="$_args --keep-data"
    : > "$LOG"
    # shellcheck disable=SC2086
    setsid nohup sh "$0" --foreground --channel "$CHANNEL" $_args >> "$LOG" 2>&1 < /dev/null &
    _pid=$!
    echo "(log: $LOG — the install goes on if this session drops)"
    _n=1
    while :; do
        sleep 2
        _l=$(wc -l < "$LOG" | tr -d ' ')
        if [ "$_l" -ge "$_n" ]; then
            sed -n "${_n},${_l}p" "$LOG"
            _n=$((_l + 1))
        fi
        grep -q '^HTL-BOOTSTRAP: ' "$LOG" && break
        if ! kill -0 "$_pid" 2>/dev/null; then
            sed -n "${_n},\$p" "$LOG"
            grep -q '^HTL-BOOTSTRAP: ' "$LOG" && break
            printf '\nHTL-BOOTSTRAP: FAILED code=died — the installer stopped without a word (see %s)\n' "$LOG" | tee -a "$LOG"
            exit 1
        fi
    done
    grep -q '^HTL-BOOTSTRAP: OK' "$LOG"
    exit $?
fi

W="" RW=0 LOCKED=0
cleanup() {
    cd / 2>/dev/null
    [ -n "$W" ] && rm -rf "$W"
    [ "$LOCKED" = 1 ] && rm -rf "$LOCK"
    # Never leave the root filesystem writable behind us.
    [ "$RW" = 1 ] && { sync; mount -o remount,ro / 2>/dev/null; }
}
trap cleanup EXIT
trap 'exit 1' INT TERM

step() { printf '\n== %s ==\n' "$1"; }
info() { printf '  + %s\n' "$1"; }
warn() { printf '  ! %s\n' "$1"; }
# fail CODE MESSAGE / done_ok CODE [k=v…] — the last line (see the top)
fail() { printf '  x %s\n\nHTL-BOOTSTRAP: FAILED code=%s — %s\n' "$2" "$1" "$2"; exit 1; }
done_ok() { printf '\nHTL-BOOTSTRAP: OK code=%s\n' "$*"; exit 0; }

# --- the same helpers as system/bin/htl-update (tests keep them identical) --
# --- sig_ok FILE SIG KEY — FILE carries the release key's signature -------
sig_ok() {
    openssl pkeyutl -verify -pubin -inkey "$3" -rawin -in "$1" -sigfile "$2" >/dev/null 2>&1
}

# --- ed25519_ok — this openssl can verify an ed25519 signature -------------
# -rawin is OpenSSL 3. The card firmware's 1.1.1 reads the key fine and then
# fails every verify, which would read as a bad signature, not a missing tool.
ed25519_ok() {
    openssl pkeyutl -help 2>&1 | grep -q -- '-rawin'
}

# --- fetch URL DEST MAX SECS — HTTPS only, at most MAX bytes ---------------
# 0 ok, 1 failed, 2 no HTTPS client at all.
fetch() {
    rm -f "$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$4" \
            --max-filesize "$3" -o "$2" "$1" 2>/dev/null || { rm -f "$2"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        case "$1" in https://*) ;; *) return 1 ;; esac
        wget -q -T "$4" -O "$2" "$1" 2>/dev/null || { rm -f "$2"; return 1; }
    else
        return 2
    fi
    [ -f "$2" ] && [ "$(wc -c < "$2")" -le "$3" ] || { rm -f "$2"; return 1; }
    return 0
}

# check_tar PKG ID — only htlwebui-ID/…, no absolute path, no "..", no
# links, and an install.sh
check_tar() {
    _l=$(tar tzf "$1" 2>/dev/null) || return 1
    [ -n "$_l" ] || return 1
    printf '%s\n' "$_l" | while IFS= read -r e; do
        case "$e" in
            "htlwebui-$2"|"htlwebui-$2/"*) ;;
            *) echo bad; break ;;
        esac
        case "/$e/" in */../*) echo bad; break ;; esac
    done | grep -q bad && return 1
    tar tvzf "$1" 2>/dev/null | grep -q '^[lh]' && return 1
    printf '%s\n' "$_l" | grep -qx "htlwebui-$2/install.sh" || return 1
    return 0
}

# --- ver_cmp A B — 1 when A is newer, 0 when equal, -1 when older ---------
ver_cmp() {
    awk -v a="$1" -v b="$2" '
    function core(v,  i) { sub(/\+.*/, "", v); sub(/^v/, "", v); i = index(v, "-"); return i ? substr(v, 1, i - 1) : v }
    function pre(v,  i) { sub(/\+.*/, "", v); i = index(v, "-"); return i ? substr(v, i + 1) : "" }
    function ids(x, y,  nx, ny, ax, ay, i, n, p, q) {
        nx = split(x, ax, "."); ny = split(y, ay, "."); n = nx > ny ? nx : ny
        for (i = 1; i <= n; i++) {
            if (i > nx) return -1
            if (i > ny) return 1
            p = ax[i]; q = ay[i]
            if (p ~ /^[0-9]+$/ && q ~ /^[0-9]+$/) { if (p + 0 != q + 0) return p + 0 > q + 0 ? 1 : -1 }
            else if (p != q) return p > q ? 1 : -1
        }
        return 0
    }
    BEGIN {
        c = ids(core(a), core(b))
        if (c == 0) {
            pa = pre(a); pb = pre(b)
            if (pa == "" && pb != "") c = 1
            else if (pa != "" && pb == "") c = -1
            else if (pa != "") c = ids(pa, pb)
        }
        print c
    }'
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# --- the same in bootstrap.sh and install.sh (tests keep them identical) ---
# card_model — "RM520NGL" from /etc/quectel-project-version ("Project Name:
# RM520NGL_VC"); empty on a firmware without the file (not Quectel Linux)
card_model() {
    sed -n 's/^Project Name:[[:space:]]*\([A-Za-z0-9]*\).*/\1/p' \
        "${HTL_TEST_QPV:-/etc/quectel-project-version}" 2>/dev/null | head -n 1
}

# model_class MODEL — known: the RM520N HTL is tried on, or the same SDX6x
# platform; sdx55: the same Linux layout, never tried; no: cannot work
# (RM551E is OpenWrt on 64-bit ARM, RM500U a Unisoc card with no smd11);
# unknown: anything else
model_class() {
    case "$1" in
        RM520N*|RM521F*|RM530N*) echo known ;;
        RM500Q*|RM502Q*|RM505Q*|RM510Q*) echo sdx55 ;;
        RM551E*|RM500U*) echo no ;;
        *) echo unknown ;;
    esac
}
# ---------------------------------------------------------------------------

# facts — k=v of what the card has now, the tail of every OK line
# other_webuis — the web UIs on this card, one name per line. The same in
# bootstrap.sh (tests/sh/test-wipe-other.sh keeps the two identical).
other_webuis() {
    if [ -d "$WR/usr/lib/qmanager" ] || [ -d "$WR/usrdata/qmanager" ] || [ -d "$WR/etc/qmanager" ] \
        || [ -n "$(ls "$WR"/lib/systemd/system/qmanager-* 2>/dev/null)" ]; then
        echo qmanager
    fi
    if [ -d "$WR/usrdata/simpleadmin" ] || [ -d "$WR/usrdata/simplefirewall" ] \
        || [ -d "$WR/usrdata/socat-at-bridge" ] \
        || grep -qs '/usrdata/simpleadmin' "$WR/lib/systemd/system/lighttpd.service"; then
        echo simpleadmin
    fi
    if [ -e "$WR/lib/systemd/system/lighttpd.service" ] \
        && ! grep -qs -e /usrdata/qmanager -e /usrdata/simpleadmin "$WR/lib/systemd/system/lighttpd.service"; then
        echo lighttpd
    fi
}

facts() {
    _fb=$(head -n 1 "$ROOT/VERSION" 2>/dev/null | tr -d ' \r')
    _fl=$(ip -4 addr show bridge0 2>/dev/null | awk '$1 == "inet" { sub(/\/.*/, "", $2); print $2; exit }')
    _fp=none _fu=none
    if [ -n "$_fb" ]; then
        if [ -f "$ROOT/etc/web/passwd.must_change" ]; then _fp=admin; else _fp=kept; fi
        if systemctl is-active htl-httpd >/dev/null 2>&1; then _fu=up; else _fu=down; fi
    fi
    printf 'build=%s model=%s lan=%s password=%s webui=%s' \
        "${_fb:-none}" "${MODEL:-unknown}" "${_fl:-none}" "$_fp" "$_fu"
}

MODEL=$(card_model)
if [ "$MODE" = status ]; then
    if [ -x "$OPT/bin/opkg" ]; then _e=yes; else _e=no; fi
    _ow=$(other_webuis | tr '\n' ',' | sed 's/,$//')
    done_ok "status $(facts) entware=$_e other=${_ow:-none}"
fi

step "Checks"
[ "$(id -u)" = 0 ] || fail not_root "run as root (adb shell is root on the card)"
if ! mkdir "$LOCK" 2>/dev/null; then
    lock_busy && fail busy "another install is running on this card (log: $LOG)"
    rm -rf "$LOCK"   # its run died without letting go
    mkdir "$LOCK" 2>/dev/null || fail busy "cannot take $LOCK"
fi
echo $$ > "$LOCK/pid"
LOCKED=1

if [ "$MODE" = uninstall ]; then
    step "Uninstall"
    [ -f "$ROOT/var/update/installed.tar.gz" ] || fail not_installed "HTL WebUI is not installed on this card"
    W=$(mktemp -d /tmp/htl-bootstrap.XXXXXX) || fail no_space "no scratch space in /tmp"
    tar xzf "$ROOT/var/update/installed.tar.gz" -C "$W" 2>/dev/null \
        || fail package_bad "the installed package does not unpack"
    set -- "$W"/*/uninstall.sh
    [ -f "$1" ] || fail package_bad "the installed package has no uninstall.sh"
    if [ "$KEEP" = 1 ]; then sh "$1" --keep-data; else sh "$1"; fi \
        || fail uninstall_failed "uninstall.sh failed (see above)"
    done_ok "uninstalled $(facts)"
fi

_class=$(model_class "$MODEL")
[ "$_class" = no ] && fail model "$MODEL cannot run HTL WebUI (RM551E: OpenWrt on 64-bit ARM; RM500U: a Unisoc card, no /dev/smd11)"
_arch=${HTL_TEST_ARCH:-$(uname -m)}
case "$_arch" in
    armv7*) ;;
    *) fail platform "this card runs $_arch — HTL WebUI is built for Quectel's 32-bit ARM (armv7) Linux" ;;
esac
[ -d "${HTL_TEST_RUNSD:-/run/systemd/system}" ] \
    || fail platform "no systemd — HTL WebUI needs Quectel's own Linux firmware, not OpenWrt"
[ -c "${HTL_TEST_SMD:-/dev/smd11}" ] && [ -d "$USRDATA" ] \
    || fail not_card "this is not a Quectel RM5xx card (no /dev/smd11 or /usrdata) — run it on the card"
case "$_class" in
    known) info "model: $MODEL" ;;
    sdx55) warn "model: $MODEL — an SDX55 card: the RM520N's Linux, but HTL WebUI was never tried on one" ;;
    *)
        [ "$ANY" = 1 ] || fail model "${MODEL:-this card} is not a model HTL WebUI knows (RM520N, RM521F, RM530N; RM500Q, RM502Q, RM505Q, RM510Q) — --any-model installs anyway"
        warn "model: ${MODEL:-unknown} — not one HTL WebUI knows; installing anyway (--any-model)"
        ;;
esac
# Available KB; a long device name wraps df's row, hence NF >= 3.
_free=$(df -k "$USRDATA" 2>/dev/null | awk 'NR > 1 && NF >= 3 { v = $(NF-2) } END { print v }')
case "$_free" in ''|*[!0-9]*) _free=0 ;; esac
[ "$_free" -ge "$MIN_FREE_KB" ] || fail no_space "/usrdata has ${_free} KB free, ${MIN_FREE_KB} needed"
info "/usrdata: ${_free} KB free"
OTHERS=$(other_webuis | tr '\n' ' ')
if [ -n "$OTHERS" ] && [ "$DRY" = 1 ]; then
    warn "another web UI on the card: ${OTHERS% } — an install would remove it first (Entware stays)"
elif [ -n "$OTHERS" ]; then
    warn "another web UI on the card: ${OTHERS% } — it is removed before HTL goes on (Entware stays)"
fi
W=$(mktemp -d /tmp/htl-bootstrap.XXXXXX) || fail no_space "no scratch space in /tmp"
fetch "$BASE/channels/channels.json.sig" "$W/probe" 1024 30
case $? in
    0) info "github.com reachable" ;;
    2) fail no_https_client "no curl or wget on the card" ;;
    *) fail offline "cannot reach github.com over HTTPS — is the card online (data call up, clock set)?" ;;
esac

step "Entware"
# Installed, but /opt not mounted yet (a boot where the unit did not run).
if [ ! -x "$OPT/bin/opkg" ] && [ -f "$SYSD/opt.mount" ] && ! mount | grep -q " $OPT "; then
    systemctl start opt.mount 2>/dev/null && info "started opt.mount"
fi
if [ -x "$OPT/bin/opkg" ]; then
    info "Entware present"
elif [ "$DRY" = 1 ]; then
    info "no Entware — would install it ($USRDATA/opt bound to $OPT)"
else
    if ! mount | grep -q " $OPT "; then
        mount -o remount,rw / || fail rootfs "cannot remount / read-write"
        RW=1
        mkdir -p "$OPT" "$USRDATA/opt" || fail entware "mkdir $OPT"
        cat > "$SYSD/opt.mount" <<UNIT || fail entware "cannot write $SYSD/opt.mount"
[Unit]
Description=Bind $USRDATA/opt to $OPT

[Mount]
What=$USRDATA/opt
Where=$OPT
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
UNIT
        cat > "$SYSD/start-opt-mount.service" <<'UNIT' || fail entware "cannot write start-opt-mount.service"
[Unit]
Description=Ensure opt.mount is started at boot
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/systemctl start opt.mount

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        mkdir -p "$SYSD/multi-user.target.wants"
        ln -sf "$SYSD/start-opt-mount.service" "$SYSD/multi-user.target.wants/start-opt-mount.service"
        sync
        mount -o remount,ro / 2>/dev/null && RW=0
        systemctl start opt.mount || fail entware "opt.mount did not start"
        mount | grep -q " $OPT " || fail entware "$OPT is not mounted"
        info "$OPT bound to $USRDATA/opt (kept across reboots by start-opt-mount.service)"
    fi
    for d in bin etc lib/opkg tmp var/lock; do mkdir -p "$OPT/$d"; done
    fetch "$ENTWARE_URL/opkg" "$OPT/bin/opkg" 4194304 120 || fail entware "cannot download opkg"
    fetch "$ENTWARE_URL/opkg.conf" "$OPT/etc/opkg.conf" 65536 60 || fail entware "cannot download opkg.conf"
    chmod 755 "$OPT/bin/opkg"
    "$OPT/bin/opkg" update || fail entware "opkg update"
    "$OPT/bin/opkg" install entware-opt || fail entware "opkg install entware-opt"
    chmod 1777 "$OPT/tmp"
    for f in passwd group shells shadow gshadow; do
        [ -f "/etc/$f" ] && ln -sf "/etc/$f" "$OPT/etc/$f"
    done
    [ -f /etc/localtime ] && ln -sf /etc/localtime "$OPT/etc/localtime"
    info "Entware installed"
fi

step "Packages"
if [ ! -x "$OPT/bin/opkg" ]; then
    info "would install: $PACKAGES"
else
    _miss=""
    for p in $PACKAGES; do
        "$OPT/bin/opkg" list-installed 2>/dev/null | grep -q "^$p " || _miss="$_miss $p"
    done
    if [ -z "$_miss" ]; then
        info "all present"
    elif [ "$DRY" = 1 ]; then
        info "would install:$_miss"
    else
        "$OPT/bin/opkg" update >/dev/null 2>&1 || warn "opkg update failed — trying with the lists there are"
        # shellcheck disable=SC2086
        "$OPT/bin/opkg" install $_miss || fail packages "opkg install$_miss"
        info "installed:$_miss"
    fi
fi

step "Release ($CHANNEL)"
if ! ed25519_ok || ! command -v jq >/dev/null 2>&1; then
    if [ "$DRY" = 1 ]; then
        info "no jq / OpenSSL 3 yet (they come with the packages) — the dry run stops here"
        done_ok "dry_run $(facts)"
    fi
    fail tools "jq or an ed25519-capable openssl is missing (Entware jq, openssl-util)"
fi
KEY="$W/release.pub"
if [ -n "${HTL_TEST_KEY:-}" ]; then cp "$HTL_TEST_KEY" "$KEY"; else printf '%s\n' "$RELEASE_KEY" > "$KEY"; fi
fetch "$BASE/channels/channels.json" "$W/channels.json" 65536 30 || fail download "cannot download channels.json"
fetch "$BASE/channels/channels.json.sig" "$W/channels.json.sig" 1024 30 || fail download "cannot download channels.json.sig"
sig_ok "$W/channels.json" "$W/channels.json.sig" "$KEY" || fail signature "channels.json is not signed by the release key"
TAG=$(jq -r --arg c "$CHANNEL" '.[$c] // empty' "$W/channels.json" 2>/dev/null)
printf '%s' "$TAG" | grep -Eq "$TAG_RE" || fail no_release "no $CHANNEL release is published"
fetch "$BASE/$TAG/release.json" "$W/release.json" 65536 30 || fail download "cannot download release.json of $TAG"
fetch "$BASE/$TAG/release.json.sig" "$W/release.json.sig" 1024 30 || fail download "cannot download release.json.sig of $TAG"
sig_ok "$W/release.json" "$W/release.json.sig" "$KEY" || fail signature "release.json of $TAG is not signed by the release key"
[ "$(jq -r '.tag // empty' "$W/release.json")" = "$TAG" ] || fail signature "release.json is not $TAG's"
REL_ID=$(jq -r '.build_id // empty' "$W/release.json")
REL_SHA=$(jq -r '.sha256 // empty' "$W/release.json")
REL_SIZE=$(jq -r '.size // empty' "$W/release.json")
case "$REL_ID" in ''|*[!0-9A-Za-z.+-]*) fail signature "release.json has no valid build id" ;; esac
case "$REL_SIZE" in ''|*[!0-9]*) fail signature "release.json has no size" ;; esac
[ "$REL_SIZE" -le "$MAX_PKG" ] || fail too_large "the package is larger than 16 MB"
info "$TAG = build $REL_ID, signature good"

CUR=$(head -n 1 "$ROOT/VERSION" 2>/dev/null | tr -d ' \r')
# "already" is only said of an install that runs: one whose web server is down
# (01/10: units never installed, the card lost power half-way) is installed
# again, which is what puts it right.
REPAIR=0
if [ -n "$CUR" ] && [ "$FORCE" = 0 ] && [ "$(ver_cmp "$REL_ID" "$CUR")" != 1 ]; then
    if systemctl is-active htl-httpd >/dev/null 2>&1; then
        info "installed: $CUR — $TAG is not newer, nothing to do (--force installs it again)"
        info "later updates: the Update card of the Web UI"
        done_ok "already $(facts)"
    fi
    REPAIR=1
fi
if [ -n "$CUR" ] && [ "$FRESH" = 1 ]; then
    info "installed: $CUR — --fresh: it and all its data go, then $REL_ID from scratch"
elif [ "$REPAIR" = 1 ]; then
    info "installed: $CUR — but its Web UI is not running: will install $REL_ID over it (settings kept)"
elif [ -n "$CUR" ]; then
    info "installed: $CUR — will install $REL_ID"
fi
if [ "$DRY" = 1 ]; then
    info "dry run: would download and install $REL_ID"
    done_ok "dry_run $(facts) release=$REL_ID"
fi

step "Download"
fetch "$BASE/$TAG/htlwebui.tar.gz" "$W/htlwebui.tar.gz" "$MAX_PKG" 600 || fail download "cannot download the package of $TAG"
[ "$(wc -c < "$W/htlwebui.tar.gz" | tr -d ' ')" -eq "$REL_SIZE" ] || fail package_bad "the package size is not the signed one"
[ "$(sha256_of "$W/htlwebui.tar.gz")" = "$REL_SHA" ] || fail package_bad "the package sha256 is not the signed one"
check_tar "$W/htlwebui.tar.gz" "$REL_ID" || fail package_bad "the package holds more than htlwebui-$REL_ID/"
info "htlwebui.tar.gz: size and sha256 are the signed ones"

step "Install"
( cd "$W" && tar xzf htlwebui.tar.gz ) || fail package_bad "the package does not unpack"
set --
[ "$ANY" = 1 ] && set -- "$@" --any-model
[ -n "$LANIP" ] && set -- "$@" --lan-ip "$LANIP"
# --fresh: whatever HTL left (an install, or the etc/ var/ of --keep-data)
if [ "$FRESH" = 1 ] && { [ -n "$CUR" ] || [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; }; then
    [ -f "$W/htlwebui-$REL_ID/uninstall.sh" ] || fail package_bad "the package has no uninstall.sh"
    ( cd "$W/htlwebui-$REL_ID" && sh uninstall.sh ) || fail uninstall_failed "uninstall.sh of $REL_ID failed (see above)"
    info "the old install and its data removed — installing from scratch"
fi
( cd "$W/htlwebui-$REL_ID" && sh install.sh "$@" ) || fail install_failed "install.sh of $REL_ID failed (see above)"
done_ok "installed $(facts)"
