#!/usr/bin/env bash
set -o pipefail

LABEL="ATmega1280"
REPO="MyRetroStore/Multi-Peripheral-Tester"
API="https://api.github.com/repos/$REPO/releases/latest"
RAWV="https://raw.githubusercontent.com/$REPO/main/version"
SITE="https://myretrostore.co.uk"
VER="1.1"

T=5
PORT=""
BAUD=115200
BB=""
PROG=""
YES=false
FORCE=false
DRY=false
TAG=""
REMOTE=""
HEX_NAME=""
HEX_URL=""
HEX_DIGEST=""
CHECKSUM_NAME=""
CHECKSUM_URL=""

if [ -t 1 ]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;34m'; W=$'\033[1m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; W=""; N=""
fi
ok() { printf "%s\n" "${G}[OK]${N} $*"; }
info() { printf "%s\n" "${B}[INFO]${N} $*"; }
warn() { printf "%s\n" "${Y}[WARN]${N} $*"; }
err() { printf "%s\n" "${R}[ERROR]${N} $*" >&2; }
die() { err "$*"; exit 1; }

ver_gt() {
    local va=${1//[^0-9.]/} vb=${2//[^0-9.]/}
    local IFS=.
    local -a a=($va) b=($vb)
    local i x y
    for i in 0 1 2 3; do
        x=${a[i]:-0}; y=${b[i]:-0}
        [ -z "$x" ] && x=0
        [ -z "$y" ] && y=0
        [ "$((10#$x))" -gt "$((10#$y))" ] && return 0
        [ "$((10#$x))" -lt "$((10#$y))" ] && return 1
    done
    return 1
}

usage() {
    cat <<U
Usage: $(basename "$0") [OPTIONS] [PORT]

Reads the installed firmware version, compares it with the latest release on
GitHub, verifies the download and flashes it.  Board: $LABEL, FTDI FT231X
(USB 0403:6015).

  -p, --port <port>      serial port, auto-detected when omitted
  -b, --baud <baud>      bootloader baud (default 57600)
  -c, --programmer <id>  avrdude programmer id
  -t, --timeout <sec>    version read timeout (default $T)
  -y, --yes              flash without confirmation
  -f, --force            flash even when already up to date (debug)
  -n, --dry-run          stop just before flashing
  -v, --version          script version
  -h, --help             this text

Website: $SITE
Releases: https://github.com/$REPO
U
}

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--port) PORT="$2"; shift 2 ;;
        -b|--baud) BB="$2"; shift 2 ;;
        -c|--programmer) PROG="$2"; shift 2 ;;
        -t|--timeout) T="$2"; shift 2 ;;
        -y|--yes) YES=true; shift ;;
        -f|--force) FORCE=true; shift ;;
        -n|--dry-run) DRY=true; shift ;;
        -v|--version) printf "%s version %s\n" "$(basename "$0")" "$VER"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage; die "Unknown option: $1" ;;
        *)
            if [ -n "$PORT" ]; then usage; die "Unexpected argument: $1"; fi
            PORT="$1"; shift ;;
    esac
done

printf "%s\n" \
    "${W}====================================================${N}" \
    "${W}      Firmware updater for Multi-Peripheral Tester     ${N}" \
    "${W}                  Script version $VER                  ${N}" \
    "  $SITE" \
    "  https://github.com/$REPO" \
    "${W}====================================================${N}"
echo

command -v avrdude >/dev/null 2>&1 || die "avrdude is not installed (sudo apt install avrdude)."
ok "avrdude: $(avrdude -v 2>&1 | grep -i 'version' | head -1 | sed 's/^[[:space:]]*//')"
command -v curl >/dev/null 2>&1 || die "curl is required."

info "Checking the latest release"
JSON=$(curl -fsSL --connect-timeout 8 --max-time 15 \
    -H "Accept: application/vnd.github.v3+json" "$API" 2>/dev/null)

release_fields() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$JSON" | jq -r '
            [.assets[] | select(.name | test("\\.hex$"; "i"))][0] as $h
            | [.assets[] | select(.name | test("(sha256|sha256sums?|checksums?)(\\.txt)?$"; "i"))][0] as $c
            | "TAG=\(.tag_name // "")\nHEX_NAME=\($h.name // "")\nHEX_URL=\($h.browser_download_url // "")\nHEX_DIGEST=\($h.digest // "")\nCHECKSUM_NAME=\($c.name // "")\nCHECKSUM_URL=\($c.browser_download_url // "")"' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$JSON" | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
a = d.get("assets", [])
h = next((x for x in a if x.get("name", "").lower().endswith(".hex")), {})
c = next((x for x in a if re.search(r"(sha256|sha256sums?|checksums?)(\.txt)?$", x.get("name", ""), re.I)), {})
for k, v in (("TAG", d.get("tag_name", "")), ("HEX_NAME", h.get("name", "")),
             ("HEX_URL", h.get("browser_download_url", "")), ("HEX_DIGEST", h.get("digest", "")),
             ("CHECKSUM_NAME", c.get("name", "")), ("CHECKSUM_URL", c.get("browser_download_url", ""))):
    print("%s=%s" % (k, v or ""))' 2>/dev/null
    fi
}

if [ -n "$JSON" ]; then
    while IFS='=' read -r key val; do
        case "$key" in
            TAG) TAG="$val" ;;
            HEX_NAME) HEX_NAME="$val" ;;
            HEX_URL) HEX_URL="$val" ;;
            HEX_DIGEST) HEX_DIGEST="$val" ;;
            CHECKSUM_NAME) CHECKSUM_NAME="$val" ;;
            CHECKSUM_URL) CHECKSUM_URL="$val" ;;
        esac
    done < <(release_fields)
else
    warn "GitHub release API unreachable, falling back to the version file"
    TAG="v$(curl -fsSL --connect-timeout 8 --max-time 15 "$RAWV" 2>/dev/null | tr -d '\r\n ')"
fi

REMOTE="${TAG#[vV]}"
[ -n "$REMOTE" ] || die "Could not determine the latest version."
ok "Latest version: $TAG"
echo

list_ports() {
    local p
    for p in /dev/ttyACM* /dev/ttyUSB* /dev/cu.usb* /dev/cu.usbserial*; do
        [ -e "$p" ] && printf '%s\n' "$p"
    done
}

stty_flag() {
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then echo "-f"; else echo "-F"; fi
}

classify_port() {
    local props vid pid text
    props=$(udevadm info -q property -n "$1" 2>/dev/null)
    vid=$(printf '%s\n' "$props" | sed -n 's/^ID_VENDOR_ID=//p' | head -1)
    pid=$(printf '%s\n' "$props" | sed -n 's/^ID_MODEL_ID=//p' | head -1)
    text=$(printf '%s|%s|%s|%s' "$vid" "$pid" \
        "$(printf '%s\n' "$props" | sed -n 's/^ID_MODEL=//p' | head -1)" "$1" \
        | tr '[:upper:]' '[:lower:]')
    if { [ "$vid" = "0403" ] && [ "$pid" = "6015" ]; } || [[ "$text" == *ft231x* ]]; then
        echo 1
    elif [ "$vid" = "0403" ] || [[ "$text" == *ftdi* ]]; then
        echo 2
    else
        echo 3
    fi
}

if [ -z "$PORT" ]; then
    best=""
    bestrank=9
    while IFS= read -r candidate; do
        rank=$(classify_port "$candidate")
        if [ "$rank" -lt "$bestrank" ]; then
            bestrank="$rank"
            best="$candidate"
        fi
    done < <(list_ports)
    [ -n "$best" ] || die "No serial port found. Connect the board or pass -p /dev/ttyUSB0."
    PORT="$best"
    [ "$bestrank" -ge 3 ] && warn "USB descriptors do not identify the board; assuming $LABEL."
else
    [ -e "$PORT" ] || die "Port $PORT does not exist."
fi

[ -r "$PORT" ] && [ -w "$PORT" ] || die "No read/write permission on $PORT (add $USER to dialout)."
ok "Board: $LABEL on $PORT"
echo

read_bash() {
    local port="$1" line version="" deadline
    stty "$(stty_flag)" "$port" "$BAUD" cs8 -cstopb -parenb -echo raw -echoe -echok \
        -echoctl -echoke -hupcl min 0 time 10 2>/dev/null || return 1
    exec 3<>"$port" || return 1
    sleep 1.6
    printf "version\r\n" >&3
    deadline=$((SECONDS + T))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if IFS= read -t 1 -r line <&3; then
            line="${line//$'\r'/}"
            line="${line//$'\n'/}"
            if [[ "$line" =~ ^FIRMWARE:[[:space:]]*[Vv]ersion[[:space:]]+([0-9]+(\.[0-9]+)*) ]] \
                || [[ "$line" =~ [Vv]ersion:[[:space:]]*([0-9]+(\.[0-9]+)*) ]] \
                || [[ "$line" =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
                version="${BASH_REMATCH[1]}"
                break
            fi
        fi
    done
    exec 3>&- 2>/dev/null
    exec 3<&- 2>/dev/null
    printf '%s' "$version"
}

read_python() {
    python3 - "$1" "$BAUD" "$T" <<'PY' 2>/dev/null
import re, sys, time
try:
    import serial
except ImportError:
    sys.exit(1)
port, baud, timeout = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    s = serial.Serial(port, baud, timeout=1)
    time.sleep(1.8)
    s.write(b"version\r\n")
    end = time.time() + timeout
    while time.time() < end:
        line = s.readline().decode("utf-8", "ignore").strip()
        m = re.search(r"FIRMWARE:\s*Version\s+([0-9]+(?:\.[0-9]+)*)", line, re.I) \
            or re.search(r"(?:Firmware\s+Version|Version):\s*([0-9]+(?:\.[0-9]+)*)", line, re.I) \
            or re.match(r"^([0-9]+\.[0-9]+(?:\.[0-9]+)?)$", line)
        if m:
            print(m.group(1))
            sys.exit(0)
    s.close()
except Exception:
    pass
sys.exit(2)
PY
}

info "Reading the installed firmware version"
VER_INSTALLED=$(read_bash "$PORT")
if [ -z "$VER_INSTALLED" ] && command -v python3 >/dev/null 2>&1; then
    VER_INSTALLED=$(read_python "$PORT")
fi
[ -n "$VER_INSTALLED" ] || die "Could not read the firmware version from $LABEL on $PORT."
ok "Installed version: $VER_INSTALLED"
echo

if [ "$VER_INSTALLED" = "$REMOTE" ]; then
    if [ "$FORCE" != true ]; then
        printf "%s\n" "${G}${W}Up to date: v$VER_INSTALLED${N}"
        exit 0
    fi
    warn "Up to date (v$VER_INSTALLED); flashing anyway because --force was given"
elif ver_gt "$REMOTE" "$VER_INSTALLED"; then
    printf "%s\n" "${Y}${W}Update available:${N} v$VER_INSTALLED -> v$REMOTE"
else
    if [ "$FORCE" != true ]; then
        printf "%s\n" "${G}${W}Board is newer than the latest release:${N} v$VER_INSTALLED vs v$REMOTE"
        printf "%s\n" "${G}Nothing to do - this updater never downgrades.${N}"
        exit 0
    fi
    warn "Board v$VER_INSTALLED is NEWER than release v$REMOTE; --force asks for a DOWNGRADE"
fi
echo

[ -n "$HEX_URL" ] || die "Release $TAG has no .hex asset to flash."
PROCEED=false
if [ "$YES" = true ]; then
    PROCEED=true
elif [ -t 0 ]; then
    read -r -p "Download and flash v$REMOTE now? [y/N]: " answer
    [[ "$answer" =~ ^[yY] ]] && PROCEED=true
else
    warn "Not running in a terminal; nothing flashed (use -y)."
fi
[ "$PROCEED" = true ] || exit 0

verify_hex() {
    local file="$1" base expected="" actual sums
    base=$(basename "$file")
    case "$HEX_DIGEST" in
        [sS][hH][aA]256:*)
            expected=$(printf '%s' "${HEX_DIGEST#*:}" | tr '[:upper:]' '[:lower:]')
            if [ "${#expected}" -ne 64 ]; then
                warn "Release digest for $base is not a 64-character SHA-256; ignoring it"
                expected=""
            fi
            ;;
    esac
    if [ -n "$expected" ]; then
        info "Verifying against the SHA-256 published for $base"
    elif [ -n "$CHECKSUM_URL" ]; then
        sums=$(mktemp "${TMPDIR:-/tmp}/mpt-sums.XXXXXX") || die "Could not create a temporary file."
        info "Downloading $CHECKSUM_NAME"
        curl -fsSL --connect-timeout 8 --max-time 30 -o "$sums" "$CHECKSUM_URL" || {
            rm -f "$sums"
            err "Could not download $CHECKSUM_NAME"
            return 1
        }
        expected=$(awk -v f="$base" '{ n = $2; sub(/^\*/, "", n); if (n == f) { print tolower($1); exit } }' "$sums")
        rm -f "$sums"
        [ -n "$expected" ] || {
            err "The checksum file does not list $base"
            return 1
        }
    else
        warn "Release $TAG publishes no SHA-256 for $base; the download cannot be verified"
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{ print tolower($1) }')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{ print tolower($1) }')
    else
        err "Neither sha256sum nor shasum is installed"
        return 1
    fi
    if [ "$actual" != "$expected" ]; then
        err "SHA-256 MISMATCH for $base"
        err "  published:  $expected"
        err "  downloaded: $actual"
        err "The image has been deleted and nothing was flashed."
        rm -f "$file"
        return 1
    fi
    ok "SHA-256 matches"
}

flash_hex() {
    local file="$1" candidate programmer baud fresh
    for candidate in arduino:57600 arduino:115200 wiring:57600; do
        programmer="${PROG:-${candidate%%:*}}"
        baud="${BB:-${candidate##*:}}"
        info "avrdude -c $programmer -p m1280 -b $baud"
        if avrdude -c "$programmer" -p m1280 -P "$PORT" -b "$baud" -D -U "flash:w:$file:i"; then
            ok "Flashed"
            sleep 5
            fresh=$(read_bash "$PORT")
            if [ -z "$fresh" ] && command -v python3 >/dev/null 2>&1; then
                fresh=$(read_python "$PORT")
            fi
            if [ -n "$fresh" ]; then
                ok "Board now reports v$fresh"
            else
                warn "No version reported after flashing; check the board"
            fi
            return 0
        fi
        warn "No response with -c $programmer -b $baud, trying the next profile"
    done
    err "Flashing failed for every programmer/baud combination"
    err "Check the connection and the bootloader, then try different -c and -b values"
    return 1
}

TARGET="$PWD/${HEX_NAME:-firmware.hex}"
info "Downloading $HEX_NAME"
curl -fSL --connect-timeout 8 --max-time 120 -o "$TARGET" "$HEX_URL" || die "Download failed."
ok "Downloaded $(wc -c <"$TARGET" | tr -d ' ') bytes"

verify_hex "$TARGET" || die "Refusing to flash an image that failed verification."

if [ "$DRY" = true ]; then
    ok "Dry run: stopping before flashing $TARGET"
    exit 0
fi

flash_hex "$TARGET" || exit 1
