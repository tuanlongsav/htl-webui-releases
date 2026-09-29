#!/bin/sh
# =============================================================================
# router-install.sh — install HTL Quectel WebUI on the Quectel RM5xx card
# plugged into this OpenWrt router by USB. Runs ON THE ROUTER, as root:
#
#   wget -qO- https://raw.githubusercontent.com/tuanlongsav/htl-webui-releases/main/router-install.sh | sh
#   wget -qO- …/router-install.sh | sh -s -- --dry-run      (or --force, --channel beta)
#
# 1. adb, from the router's own packages (opkg or apk) when it has none
# 2. the card over adb — its USB configuration must include ADB
# 3. bootstrap.sh (same repository) onto the card and run there: Entware,
#    packages, the latest signed release, install.sh (installer/bootstrap.sh
#    checks every signature on the card itself)
# 4. its last line decides: "HTL-BOOTSTRAP: OK …" or "… FAILED …" (adb shell
#    does not pass exit codes on). If adb loses the card meanwhile, the card
#    carries on alone and this reads its log until it ends.
#
# --local FILE   push FILE instead of downloading bootstrap.sh (testing)
# --serial S     pick one card when adb sees several
# HTL_TEST_* variables are for tests/sh/test-router-install.sh only.
# =============================================================================

RAW=https://raw.githubusercontent.com/tuanlongsav/htl-webui-releases/main
CARD_SCRIPT=/tmp/htl-bootstrap.sh
CARD_LOG=/tmp/htl-bootstrap.log
CARD_ROOT=/usrdata/htlwebui
SYSFS=${HTL_TEST_SYSFS:-/sys/bus/usb/devices}
QUECTEL_VID=2c7c
WAIT_POLLS=${HTL_TEST_WAIT_POLLS:-360}   # x 5 s = 30 min for a card adb lost

usage() {
    echo "usage: router-install.sh [--dry-run] [--force] [--channel stable|beta] [--serial S] [--local FILE]"
    exit 2
}
step() { printf '\n== %s ==\n' "$1"; }
info() { printf '  + %s\n' "$1"; }
die()  { printf '  x %s\n' "$1" >&2; exit 1; }

ARGS="" LOCAL="" SERIAL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --channel)
            [ $# -ge 2 ] || usage
            case "$2" in stable|beta) ARGS="$ARGS --channel $2" ;; *) usage ;; esac
            shift ;;
        --dry-run|--force) ARGS="$ARGS $1" ;;
        --local)  [ $# -ge 2 ] || usage; LOCAL=$2; shift ;;
        --serial) [ $# -ge 2 ] || usage; SERIAL=$2; shift ;;
        *) usage ;;
    esac
    shift
done
case "$SERIAL" in *[!A-Za-z0-9._:-]*) die "not an adb serial: $SERIAL" ;; esac

TMPF=""
trap '[ -n "$TMPF" ] && rm -f "$TMPF"' EXIT
trap 'exit 1' INT TERM

[ "$(id -u)" = 0 ] || die "run as root on the router"

# --- adb --------------------------------------------------------------------
step "adb"
if command -v adb >/dev/null 2>&1; then
    info "adb present"
elif command -v apk >/dev/null 2>&1; then
    info "installing adb (apk)"
    apk update >/dev/null 2>&1
    apk add adb || die "apk add adb failed"
elif command -v opkg >/dev/null 2>&1; then
    info "installing adb (opkg)"
    opkg update >/dev/null 2>&1
    opkg install adb || die "opkg install adb failed"
else
    die "no adb, and neither apk nor opkg to install it"
fi
command -v adb >/dev/null 2>&1 || die "adb is still missing after installing it"

# --- the card ---------------------------------------------------------------
step "Card"
adb start-server >/dev/null 2>&1
_devs="" _n=0
while :; do
    _devs=$(adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }')
    [ -n "$_devs" ] && break
    _n=$((_n + 1))
    [ "$_n" -ge 10 ] && break
    sleep 2
done
if [ -z "$_devs" ]; then
    if grep -qix "$QUECTEL_VID" "$SYSFS"/*/idVendor 2>/dev/null; then
        die "a Quectel card is on USB but offers no ADB: turn ADB on in its USB configuration (AT+QCFG=\"usbcfg\"), replug, and run this again"
    fi
    die "no Quectel card on USB — plug the card into this router (USB) and run this again"
fi
if [ -n "$SERIAL" ]; then
    printf '%s\n' "$_devs" | grep -qx "$SERIAL" || die "adb has no card $SERIAL (it has: $(printf '%s' "$_devs" | tr '\n' ' '))"
elif [ "$(printf '%s\n' "$_devs" | wc -l | tr -d ' ')" -gt 1 ]; then
    die "adb sees several cards — pick one with --serial: $(printf '%s' "$_devs" | tr '\n' ' ')"
else
    SERIAL=$_devs
fi
info "card $SERIAL"
A="adb -s $SERIAL"

# --- bootstrap.sh -----------------------------------------------------------
step "Installer"
TMPF=$(mktemp /tmp/htl-bootstrap.XXXXXX) || die "no room in /tmp"
if [ -n "$LOCAL" ]; then
    cp "$LOCAL" "$TMPF" || die "cannot read $LOCAL"
    info "local $LOCAL"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' -o "$TMPF" "$RAW/bootstrap.sh"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$TMPF" "$RAW/bootstrap.sh"
    else
        uclient-fetch -qO "$TMPF" "$RAW/bootstrap.sh"
    fi || die "cannot download $RAW/bootstrap.sh (router online? CA certificates installed?)"
    info "bootstrap.sh from $RAW"
fi
head -n 1 "$TMPF" | grep -qx '#!/bin/sh' && grep -q 'HTL-BOOTSTRAP: ' "$TMPF" \
    || die "that is not bootstrap.sh"
$A shell "rm -f $CARD_LOG" >/dev/null 2>&1
$A push "$TMPF" "$CARD_SCRIPT" >/dev/null 2>&1 || die "adb push to the card failed"

# --- run it on the card -----------------------------------------------------
step "On the card"
$A shell "sh $CARD_SCRIPT$ARGS"
_res=$($A shell "grep '^HTL-BOOTSTRAP: ' $CARD_LOG | tail -n 1" 2>/dev/null | tr -d '\r')
if [ -z "$_res" ]; then
    # adb let go before the end; the card goes on by itself.
    info "lost the card's output — waiting for the install on the card to finish"
    _n=0
    while [ -z "$_res" ] && [ "$_n" -lt "$WAIT_POLLS" ]; do
        sleep 5
        _n=$((_n + 1))
        _res=$($A shell "grep '^HTL-BOOTSTRAP: ' $CARD_LOG | tail -n 1" 2>/dev/null | tr -d '\r')
    done
    [ -n "$_res" ] && printf '%s\n' "$_res"
fi
$A shell "rm -f $CARD_SCRIPT" >/dev/null 2>&1

case "$_res" in
    "HTL-BOOTSTRAP: OK"*) ;;
    "") die "no word from the card — its log is $CARD_LOG (adb shell cat $CARD_LOG)" ;;
    *)  die "the install on the card failed — see above, or: adb shell cat $CARD_LOG" ;;
esac

step "Done"
_ip=$($A shell "ip -4 addr show bridge0" 2>/dev/null | tr -d '\r' \
    | awk '$1 == "inet" { sub(/\/.*/, "", $2); print $2; exit }')
case "$_res" in
    *"dry run"*) info "dry run: nothing was changed" ;;
    *)
        info "Web UI: https://${_ip:-<the card IP>}/ — from a device on this router's network"
        # install.sh leaves this marker only while the password is still "admin".
        if $A shell "[ -f $CARD_ROOT/etc/web/passwd.must_change ] && echo must_change" 2>/dev/null \
            | grep -q must_change; then
            info "first login: password admin — the Web UI then asks for your own"
        else
            info "login: the password already set on this card (kept)"
        fi
        info "the browser warns about the certificate (made on the card): continue anyway"
        info "iPhone (iOS 27): turn Wi-Fi \"Connection Assist\" off for the first visit"
        info "later updates: the Update card of the Web UI"
        ;;
esac
exit 0
