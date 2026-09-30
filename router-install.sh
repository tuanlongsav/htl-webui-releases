#!/bin/sh
# =============================================================================
# router-install.sh — install HTL Quectel WebUI on the Quectel RM5xx card
# plugged into this OpenWrt router by USB. Runs ON THE ROUTER, as root:
#
#   wget -qO- https://raw.githubusercontent.com/tuanlongsav/htl-webui-releases/main/router-install.sh | sh
#   wget -qO- …/router-install.sh | sh -s -- --dry-run      (or any option below)
#
# 1. adb, from the router's own packages (opkg or apk) when it has none
# 2. the card over adb — its USB configuration must include ADB
# 3. bootstrap.sh (same repository) onto the card and run there: Entware,
#    packages, the latest signed release, install.sh (installer/bootstrap.sh
#    checks every signature on the card itself)
# 4. its last line decides (adb shell does not pass exit codes on). If adb
#    loses the card meanwhile, the card carries on alone and this reads its
#    log until it ends.
#
# Options:
#   --dry-run            change nothing, on the router or the card
#   --force              install the same or an older build again
#   --fresh              HTL already on the card: remove it and all its data,
#                        then install from scratch (default: an upgrade that
#                        keeps settings, password, certificate, counters)
#   --channel stable|beta
#   --any-model          a card model HTL does not know (see bootstrap.sh)
#   --lan-ip A.B.C.D     the card's LAN gateway address (default: kept)
#   --status             what is there: adb, the card, its build; no change
#   --uninstall [--keep-data]
#   --detach             run in the background, log in /tmp/htl-router-install.log
#                        (needs this script as a file, not piped)
#   --serial S           pick one card when adb sees several
#   --local FILE         push FILE instead of downloading bootstrap.sh (testing)
#
# The last line is for programs (the Rowa app); exit 0 / 1 / 2 (usage):
#   HTL-INSTALL: OK code=installed|already|dry_run|uninstalled|status k=v…
#   HTL-INSTALL: FAILED code=<code> — <what went wrong, for people>
# k=v: serial, url (https://<card LAN address>/), and the card's own —
# build, model, lan, password (admin: the default, still to be changed;
# kept), webui. Codes: docs/DEPLOY.md. One run at a time; opkg/apk only
# under Rowa's /var/run/rowa-install.lock — which Rowa itself already holds
# when it is the one running this (under_rowa).
#
# Rowa (router/rowa `webui_install`) reads the log as it goes: the step is
# the last "== X ==" line at the start of a line, an error the last "  x"
# line, matched on words kept here on purpose ("install on the card failed",
# "apk add adb", "offers no ADB", …). The card's own output is therefore
# indented ("  | "), so its headers never read as this script's steps; its
# result line is printed again at the start of a line.
#
# HTL_TEST_* variables are for tests/sh/test-router-install.sh only.
# =============================================================================

RAW=https://raw.githubusercontent.com/tuanlongsav/htl-webui-releases/main
CARD_SCRIPT=/tmp/htl-bootstrap.sh
CARD_LOG=/tmp/htl-bootstrap.log
SYSFS=${HTL_TEST_SYSFS:-/sys/bus/usb/devices}
QUECTEL_VID=2c7c
WAIT_POLLS=${HTL_TEST_WAIT_POLLS:-360}   # x 5 s = 30 min for a card adb lost
LOCK=${HTL_TEST_LOCK:-/var/lock/htl-router-install}
PM_LOCK=${HTL_TEST_PM_LOCK:-/var/run/rowa-install.lock}
RLOG=${HTL_TEST_RLOG:-/tmp/htl-router-install.log}

usage() {
    echo "usage: router-install.sh [--dry-run] [--force] [--fresh] [--channel stable|beta] [--any-model] [--lan-ip A.B.C.D]"
    echo "                         [--status | --uninstall [--keep-data]] [--detach] [--serial S] [--local FILE]"
    exit 2
}
step() { printf '\n== %s ==\n' "$1"; }
# under_rowa — Rowa started this, holding its package-manager lock for the
# whole run (its copy is webui-router-install.sh, run by webui_install_bg):
# asking for that lock again would wait on ourselves.
under_rowa() {
    case "${0##*/}" in webui-router-install.sh) return 0 ;; esac
    tr '\0' ' ' < "${HTL_TEST_PPID_CMDLINE:-/proc/$PPID/cmdline}" 2>/dev/null | grep -q 'webui_install_bg'
}
info() { printf '  + %s\n' "$1"; }
# die CODE MESSAGE / ok CODE [k=v…] — the last line (see the top)
die()  { printf '  x %s\n\nHTL-INSTALL: FAILED code=%s — %s\n' "$2" "$1" "$2"; exit 1; }
ok()   { printf '\nHTL-INSTALL: OK code=%s\n' "$*"; exit 0; }

ARGS="" LOCAL="" SERIAL="" MODE=install DRY=0 DETACH=0 KEEP=0 FRESH=0 ALL="$*"
while [ $# -gt 0 ]; do
    case "$1" in
        --channel)
            [ $# -ge 2 ] || usage
            case "$2" in stable|beta) ARGS="$ARGS --channel $2" ;; *) usage ;; esac
            shift ;;
        --dry-run)   DRY=1; ARGS="$ARGS --dry-run" ;;
        --force|--any-model) ARGS="$ARGS $1" ;;
        --fresh)     FRESH=1; ARGS="$ARGS --fresh" ;;
        --lan-ip)
            [ $# -ge 2 ] || usage
            # checked again on the card; here it only has to be harmless
            case "$2" in *[!0-9.]*|'') usage ;; esac
            ARGS="$ARGS --lan-ip $2"; shift ;;
        --status)    MODE=status ;;
        --uninstall) MODE=uninstall ;;
        --keep-data) KEEP=1 ;;
        --detach)    DETACH=1 ;;
        --local)  [ $# -ge 2 ] || usage; LOCAL=$2; shift ;;
        --serial) [ $# -ge 2 ] || usage; SERIAL=$2; shift ;;
        *) usage ;;
    esac
    shift
done
[ "$KEEP" = 0 ] || [ "$MODE" = uninstall ] || usage
[ "$FRESH" = 0 ] || [ "$MODE" = install ] || usage
case "$SERIAL" in *[!A-Za-z0-9._:-]*) die bad_serial "not an adb serial: $SERIAL" ;; esac

# --- detach: the session may drop, the install must not -------------------------
if [ "$DETACH" = 1 ]; then
    [ -f "$0" ] || die usage "--detach needs this script saved as a file (not piped into sh)"
    _a=$(printf '%s\n' "$ALL" | sed 's/--detach//')
    # shellcheck disable=SC2086
    setsid nohup sh "$0" $_a > "$RLOG" 2>&1 < /dev/null &
    printf 'HTL-INSTALL: STARTED pid=%s log=%s\n' "$!" "$RLOG"
    exit 0
fi
# A dropped ssh session sends HUP: carry on, the card side does too.
trap '' HUP

[ "$(id -u)" = 0 ] || die not_root "run as root on the router"

# --- one run at a time -----------------------------------------------------------
LOCKED=0 ADB_WAS=1 TMPF=""
cleanup() {
    [ -n "$TMPF" ] && rm -f "$TMPF"
    # The adb server this run started goes with it.
    [ "$ADB_WAS" = 0 ] && adb kill-server >/dev/null 2>&1 < /dev/null
    [ "$LOCKED" = 1 ] && rm -rf "$LOCK"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
if ! mkdir "$LOCK" 2>/dev/null; then
    _p=$(cat "$LOCK/pid" 2>/dev/null)
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && die busy "another HTL install is running on this router"
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || die busy "cannot take $LOCK"
fi
echo $$ > "$LOCK/pid"
LOCKED=1

# --- adb --------------------------------------------------------------------
step "adb"
if command -v adb >/dev/null 2>&1; then
    info "adb present"
elif [ "$DRY" = 1 ] || [ "$MODE" = status ]; then
    info "no adb — an install would add it from the router's packages"
    ok "$( [ "$DRY" = 1 ] && echo dry_run || echo status ) adb=missing"
else
    # Rowa's lock around the package manager: never two opkg/apk at once.
    PM_HELD=0
    if under_rowa; then
        info "run by Rowa, which holds the package lock for it"
    else
        mkdir "$PM_LOCK" 2>/dev/null || die busy_pm "the router's package manager is busy (another install) — try again later"
        PM_HELD=1
    fi
    if command -v apk >/dev/null 2>&1; then
        _pm="apk add adb"
        info "installing adb (apk)"
        apk update >/dev/null 2>&1
        apk add adb; _r=$?
    elif command -v opkg >/dev/null 2>&1; then
        _pm="opkg install adb"
        info "installing adb (opkg)"
        opkg update >/dev/null 2>&1
        opkg install adb; _r=$?
    else
        [ "$PM_HELD" = 1 ] && rmdir "$PM_LOCK" 2>/dev/null
        die no_adb "no adb, and neither apk nor opkg to install it"
    fi
    [ "$PM_HELD" = 1 ] && rmdir "$PM_LOCK" 2>/dev/null
    [ "$_r" = 0 ] || die adb_install "$_pm failed (router online? package lists?)"
fi
command -v adb >/dev/null 2>&1 || die adb_install "adb is still missing after installing it"

# --- the card ---------------------------------------------------------------
step "Card"
pidof adb >/dev/null 2>&1 || ADB_WAS=0
adb start-server >/dev/null 2>&1 < /dev/null
_devs="" _n=0
while :; do
    _devs=$(adb devices 2>/dev/null < /dev/null | awk 'NR > 1 && $2 == "device" { print $1 }')
    [ -n "$_devs" ] && break
    _n=$((_n + 1))
    [ "$_n" -ge 10 ] && break
    sleep 2
done
if [ -z "$_devs" ]; then
    if grep -qix "$QUECTEL_VID" "$SYSFS"/*/idVendor 2>/dev/null; then
        die adb_off "a Quectel card is on USB but offers no ADB: turn ADB on in its USB configuration (AT+QCFG=\"usbcfg\"), replug, and run this again"
    fi
    die no_card "no Quectel card on USB — plug the card into this router (USB) and run this again"
fi
if [ -n "$SERIAL" ]; then
    printf '%s\n' "$_devs" | grep -qx "$SERIAL" || die no_such_card "adb has no card $SERIAL (it has: $(printf '%s' "$_devs" | tr '\n' ' '))"
elif [ "$(printf '%s\n' "$_devs" | wc -l | tr -d ' ')" -gt 1 ]; then
    die several_cards "adb sees several cards — pick one with --serial: $(printf '%s' "$_devs" | tr '\n' ' ')"
else
    SERIAL=$_devs
fi
info "card $SERIAL"
# Never hand adb this script's stdin: under `wget … | sh` it is the rest of
# the script.
A() { adb -s "$SERIAL" "$@" < /dev/null; }

# --- bootstrap.sh -----------------------------------------------------------
step "Installer"
TMPF=$(mktemp /tmp/htl-bootstrap.XXXXXX) || die no_space "no room in /tmp"
if [ -n "$LOCAL" ]; then
    cp "$LOCAL" "$TMPF" || die download "cannot read $LOCAL"
    info "local $LOCAL"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --connect-timeout 20 --max-time 120 -o "$TMPF" "$RAW/bootstrap.sh"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$TMPF" "$RAW/bootstrap.sh"
    else
        uclient-fetch -q -T 30 -O "$TMPF" "$RAW/bootstrap.sh"
    fi || die download "cannot download $RAW/bootstrap.sh (router online? CA certificates installed?)"
    info "bootstrap.sh from $RAW"
fi
head -n 1 "$TMPF" | grep -qx '#!/bin/sh' && grep -q 'HTL-BOOTSTRAP: ' "$TMPF" \
    || die not_bootstrap "that is not bootstrap.sh"
[ "$MODE" = status ] || A shell "rm -f $CARD_LOG" >/dev/null 2>&1
A push "$TMPF" "$CARD_SCRIPT" >/dev/null 2>&1 || die push "adb push to the card failed"

# --- run it on the card -----------------------------------------------------
step "On the card"
case "$MODE" in
    status)    _run="--status" ;;
    uninstall) _run="--uninstall$( [ "$KEEP" = 1 ] && echo ' --keep-data')" ;;
    *)         _run="${ARGS# }" ;;
esac
if [ "$MODE" = status ]; then
    # Quick and read-only: no detaching on the card, the answer is the output.
    _res=$(A shell "sh $CARD_SCRIPT --status" 2>/dev/null | tr -d '\r' | grep '^HTL-BOOTSTRAP: ' | tail -n 1)
else
    # Indented, flushed line by line (a log someone reads while it grows).
    A shell "sh $CARD_SCRIPT${_run:+ $_run}" 2>&1 | awk '{ sub(/\r$/, ""); print "  | " $0; fflush() }'
    _res=$(A shell "grep '^HTL-BOOTSTRAP: ' $CARD_LOG | tail -n 1" 2>/dev/null | tr -d '\r')
    if [ -z "$_res" ]; then
        # adb let go before the end; the card goes on by itself.
        info "lost the card's output — waiting for the install on the card to finish"
        _n=0
        while [ -z "$_res" ] && [ "$_n" -lt "$WAIT_POLLS" ]; do
            sleep 5
            _n=$((_n + 1))
            _res=$(A shell "grep '^HTL-BOOTSTRAP: ' $CARD_LOG | tail -n 1" 2>/dev/null | tr -d '\r')
        done
    fi
    [ -n "$_res" ] && printf '%s\n' "$_res"
fi
A shell "rm -f $CARD_SCRIPT" >/dev/null 2>&1

case "$_res" in
    "HTL-BOOTSTRAP: OK code="*) ;;
    "HTL-BOOTSTRAP: FAILED code="*)
        _c=$(printf '%s\n' "$_res" | sed -n 's/^HTL-BOOTSTRAP: FAILED code=\([a-z_]*\).*/\1/p')
        _m=$(printf '%s\n' "$_res" | sed -n 's/^HTL-BOOTSTRAP: FAILED code=[a-z_]* — //p')
        die "${_c:-card_failed}" "install on the card failed: ${_m:-see above} (adb shell cat $CARD_LOG)" ;;
    "") die card_silent "no word from the card — its log is $CARD_LOG (adb shell cat $CARD_LOG)" ;;
    *)  die card_failed "install on the card failed: it answered something else — adb shell cat $CARD_LOG" ;;
esac

# "OK code=installed build=… model=… lan=… password=… webui=…"
_kv=${_res#HTL-BOOTSTRAP: OK code=}
_code=${_kv%% *}
_lan=$(printf '%s\n' "$_kv" | sed -n 's/.* lan=\([0-9.]*\).*/\1/p')
_url=""
[ -n "$_lan" ] && _url="https://$_lan/"

step "Done"
case "$_code" in
    dry_run) info "dry run: nothing was changed" ;;
    status|uninstalled) ;;
    *)
        info "Web UI: ${_url:-https://<the card IP>/} — from a device on this router's network"
        case "$_kv" in
            *password=admin*) info "first login: password admin — the Web UI then asks for your own" ;;
            *) info "login: the password already set on this card (kept)" ;;
        esac
        info "the browser warns about the certificate (made on the card): continue anyway"
        info "iPhone (iOS 27): turn Wi-Fi \"Connection Assist\" off for the first visit"
        info "later updates: the Update card of the Web UI"
        ;;
esac
ok "$_code serial=$SERIAL${_url:+ url=$_url} ${_kv#* }"
