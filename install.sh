#!/bin/sh
#
# PAL's installer (docs/shipping-plan.md §3.5), served as https://get.trypai.ai:
#
#   curl -fsSL https://get.trypai.ai | sh
#   curl -fsSL https://get.trypai.ai | sh -s -- --channel internal --yes-eula
#
# Run it as yourself; it asks for your password (sudo) where it must.
#
#   Ubuntu, x86_64, AMD graphics (the EVO-X2 profile): Docker from Docker's apt
#     repository, then PAL under /opt/pal-releases/<version>/, /opt/pal linked
#     to it, scripts/up.sh --release, and pal-update for the overnight updates.
#   An Apple Silicon Mac (the mac-mini-24 profile): the release unpacked under
#     $PAL_MAC_DIR/releases/<version>/ (default /Users/Shared/PAL), then its
#     hardware/mac-mini-24/host/install.sh, which sets the Mac up (Homebrew,
#     the model servers, the Lima VM) and runs this script again inside the VM
#     (--in-vm) to install the release there; then pal-update's agent for the
#     Mac's side.
#   Anything else: it stops and says so, having changed nothing.
#
# Steps: the profile and its memory; the licence (type yes); what the machine needs; the
# channel pointer (channels/<channel>.json) and the release's manifest, each
# checked against PAL's release key with the minisign verifier inside this
# script; the bundle for this machine, checked against the manifest's sha256;
# unpacked; the setup the PAL app will recommend for this memory (the
# release's hardware/setups.json, as information: the choice is made in the
# app's setup, before any model downloads); scripts/box/assemble.sh (our
# images, from their public pinned sources); /opt/pal linked; RELEASE.json;
# up.sh --release; pal-update; and the pairing code, QR and "Open the PAL app".
#
# Safe to run again: each step checks before it acts, a release already
# unpacked from the same bundle is kept, and nothing that runs changes until
# the new release is assembled.
#
# A box that runs PAL from a source checkout (George's `make up`, /opt/pal a
# real folder; on a Mac, its VM's) is not installed over. The installer says
# so and asks whether to SWITCH it to the production build instead (default
# no; --switch-from-source answers yes without asking): the release is fetched,
# checked and unpacked as for an install, then the box's own pal-update
# switches it (pal-update switch-to-release; docs/releasing.md, "Switching a
# development box to production"), keeping every person's files, chats,
# settings, the .env's secrets and the models, and going back to the
# development build by itself if anything fails. On a Mac the Mac's side is
# kept to put back too ($PAL_MAC_DIR/src-source-<stamp>).
#
# Options (and environment):
#   --yes-eula             accept the licence without being asked (the release-test Mac mini)
#   --switch-from-source   on a box that runs PAL from a source checkout, switch it to the
#                          production build without asking (above)
#   --channel NAME         PAL_CHANNEL: beta (default) or internal
#   --updates-url URL      PAL_UPDATES_URL: default https://updates.trypai.ai
#   --dry-run              say what it would do, change nothing, fetch nothing
#   --detect               print this machine's profile and stop
#   --in-vm --from DIR     (the Mac's install.sh) install the release in DIR inside the VM
#   --app                  run by the Mac app ("Run PAL on this Mac", the Free tier; it
#                          bundles this file): the mac-mini-24 profile on this Mac, the
#                          licence already accepted in the app (recorded, with
#                          PAL_EULA_ACCEPTED_AT), nothing asked in a terminal (macOS's
#                          own dialog where sudo needs a password), and lines the app
#                          reads on stdout:
#                            PAL-PROGRESS <step> <n>/<total> <text>   at each step:
#                              prepare release download unpack tools models servers vm
#                              deploy updater done (tools to deploy come from the
#                              Mac's install.sh, which prints them too)
#                            PAL-PAIRING {"link","code","host","user","box_url"}   at the end
#                          and how it ended in $PAL_MAC_DIR/state/install-result.json,
#                          the file the Mac's install.sh keeps ({running, pid}, then
#                          {exit, step, code, text}); exit 3 is a paused download.
#   PAL_RELEASE_PUBKEY     the release key's base64 line, instead of the one built in
#   PAL_MAC_DIR            where the Mac keeps PAL (default /Users/Shared/PAL)
#   PAL_FIRST_ADMIN        the first admin's Linux user (default: you)
#   PAL_TTY                where the switch question is answered (default /dev/tty)
set -eu

# The release script writes keys/pal-release.pub's key line here when it
# publishes this file. Empty: this copy can't check anything, and stops.
PAL_RELEASE_PUBKEY_BUILTIN="RWSuVqd4w8/Nq0Q4g46KOraQu4NPrhZgU5O9poOB02JlhyV/ZNlvIIE7"
# release/eula.json's, written by the release script too.
PAL_EULA_VERSION="0.1-draft"
PAL_EULA_URL="https://trypai.ai/legal/eula"

DEFAULT_UPDATES_URL="https://updates.trypai.ai"
RELEASES=/opt/pal-releases
OPT=/opt/pal
NOTES_DIR=/srv/pal/system/release-notes

say() { printf '[pal] %s\n' "$*"; }
die() { DIE_TEXT="$*"; printf '[pal] %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# What this script installs itself, pinned (hardware/mac-mini-24/host/tools.lock
# carries the same lines; hardware/test/mac_tools_test.py keeps them equal).
# Docker: its apt key by fingerprint, then each package at this version, which
# apt checks against Docker's signed index ("~ubuntu.<release>~<codename>" is
# added for this box's Ubuntu). zstd, on a Mac: Meta's source release, by sha256.
DOCKER_APT_KEY="https://download.docker.com/linux/ubuntu/gpg 9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
DOCKER_PKGS="docker-ce=5:29.9.3-1 docker-ce-cli=5:29.9.3-1 containerd.io=2.4.2-4 docker-buildx-plugin=0.39.1-1 docker-compose-plugin=5.8.0-1"
ZSTD_PIN="1.6.0 https://github.com/meta/zstd/releases/download/v1.6.0/zstd-1.6.0.tar.gz 2ba599ae2a257976278e7e71e998433a387bfd18aa7b78678229fd5d84f5e9b8"
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# --- the Mac app (--app) -----------------------------------------------------------
# What it reads: a PAL-PROGRESS line at each step, and install-result.json.
APP="" APP_STATE="" APP_STEP="" HOST_RESULT="" DIE_TEXT="" WORK="" SWITCH="" MAC_SAVED=""
APP_STEPS="prepare release download unpack tools models servers vm deploy updater done"

progress() {  # step text
  APP_STEP="$1"
  [ -n "$APP" ] || return 0
  _pi=0 _pn=0
  for _ps in $APP_STEPS; do
    _pi=$((_pi + 1))
    [ "$_ps" != "$1" ] || _pn=$_pi
  done
  printf 'PAL-PROGRESS %s %s/%s %s\n' "$1" "$_pn" "$_pi" "$2"
}

json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t\r' '   '; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

app_result() {  # the JSON, written whole
  [ -n "$APP_STATE" ] || return 0
  mkdir -p "$APP_STATE" 2>/dev/null || return 0
  printf '%s\n' "$1" > "$APP_STATE/install-result.json.tmp" 2>/dev/null \
    && mv -f "$APP_STATE/install-result.json.tmp" "$APP_STATE/install-result.json" 2>/dev/null || true
}

# The problem code the app shows a stop under (as the Mac's install.sh's result_code).
app_code() {
  case "$1" in
    prepare) echo tools ;;
    release|download) echo network ;;
    ""|unpack) echo install ;;
    *) echo "$1" ;;
  esac
}

# How the run ended. Not when the Mac's install.sh stopped it: that one
# already wrote where and why, and this run exits with its code.
app_finished() {  # exit code
  [ -n "$APP" ] && [ -z "$HOST_RESULT" ] || return 0
  _code=""
  [ "$1" -eq 0 ] || _code="$(app_code "$APP_STEP")"
  app_result "$(printf '{"running":false,"exit":%s,"step":"%s","code":"%s","text":"%s","app":true,"finished_at":"%s"}' \
    "$1" "${APP_STEP:-prepare}" "$_code" "$(json_str "$DIE_TEXT")" "$(utc_now)")"
}

on_exit() {  # exit code
  [ -z "$WORK" ] || rm -rf "$WORK"
  app_finished "$1"
}

# sudo's askpass, with no terminal to ask in: macOS's own dialog (Homebrew's
# installer takes it too). The Mac's install.sh makes its own for its steps.
app_askpass() {
  cat > "$WORK/pal-askpass" <<'ASKPASS'
#!/bin/sh
exec /usr/bin/osascript -e 'text returned of (display dialog "PAL is setting up this Mac and needs an administrator'"'"'s password for a moment (the tools it installs)." default answer "" with hidden answer with title "Set up PAL" with icon caution buttons {"Cancel", "OK"} default button "OK")'
ASKPASS
  chmod 700 "$WORK/pal-askpass"
  SUDO_ASKPASS="$WORK/pal-askpass"
  export SUDO_ASKPASS
}

# When the licence was accepted, as a JSON-safe UTC time: the app's
# (PAL_EULA_ACCEPTED_AT), or now.
eula_time() {
  case "${PAL_EULA_ACCEPTED_AT:-}" in
    ""|*[!0-9A-Za-z:.+-]*) utc_now ;;
    *) printf '%s\n' "$PAL_EULA_ACCEPTED_AT" ;;
  esac
}

# --- the machine ---------------------------------------------------------------
# PROFILE (evo-x2 | mac-mini-24) and ARCH (amd64 | arm64), or WHY it is neither.
detect() {
  PROFILE="" ARCH="" WHY=""
  os="$(uname -s 2>/dev/null || echo unknown)"
  m="$(uname -m 2>/dev/null || echo unknown)"
  case "$os" in
    Darwin)
      # Apple silicon even in a shell under Rosetta, whose uname says x86_64.
      if [ "$m" = arm64 ] || [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
        PROFILE=mac-mini-24 ARCH=arm64
      else
        WHY="a Mac with an Intel processor"
      fi ;;
    Linux)
      osr="${PAL_OS_RELEASE:-/etc/os-release}"
      distro="$( [ -r "$osr" ] && . "$osr" && printf '%s' "${ID:-}" || true)"
      pretty="$( [ -r "$osr" ] && . "$osr" && printf '%s' "${PRETTY_NAME:-}" || true)"
      if [ "$m" != x86_64 ]; then
        WHY="Linux on $m"
      elif [ "$distro" != ubuntu ]; then
        WHY="${pretty:-a Linux other than Ubuntu}"
      elif amd_gpu; then
        PROFILE=evo-x2 ARCH=amd64
      else
        WHY="Ubuntu without an AMD graphics chip"
      fi ;;
    *) WHY="$os on $m" ;;
  esac
}

amd_gpu() {
  if have lspci; then
    lspci -nn 2>/dev/null | grep -Ei 'vga|display|3d' | grep -Eqi '\[1002:|advanced micro devices|amd/ati' && return 0
  fi
  for v in /sys/class/drm/card*/device/vendor; do
    [ -r "$v" ] && [ "$(cat "$v")" = 0x1002 ] && return 0
  done
  return 1
}

# --- the memory, and the setup for it ---------------------------------------------
# What hardware/setups.py counts (bootstrap and the app count the same): a
# Mac's hw.memsize; on Linux MemTotal plus each GPU's own memory, since an AMD
# APU's carve-out is missing from MemTotal and is where the models live.
memory_bytes() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    sysctl -n hw.memsize 2>/dev/null || echo 0
    return 0
  fi
  _kb="$(sed -n 's/^MemTotal:[[:space:]]*\([0-9][0-9]*\) kB$/\1/p' "${PAL_MEMINFO:-/proc/meminfo}" 2>/dev/null | head -n1)"
  _total=$(( ${_kb:-0} * 1024 ))
  for _v in "${PAL_DRM:-/sys/class/drm}"/card*/device/mem_info_vram_total; do
    [ -r "$_v" ] || continue
    _card="${_v%/device/mem_info_vram_total}"
    case "${_card##*/}" in *-*) continue ;; esac   # card0-DP-1: a connector, not a card
    _n="$(cat "$_v" 2>/dev/null)"
    case "$_n" in ""|*[!0-9]*) continue ;; esac
    _total=$(( _total + _n ))
  done
  echo "$_total"
}

gib() { awk -v b="$1" 'BEGIN { printf "%.0f", b / 1073741824 }'; }

# say_setup DIR MACHINE — information only: the memory found, and the setup the
# PAL app will recommend for it, from the release in DIR (its hardware/setups.py).
# Nothing here chooses: the app asks, before any model downloads.
say_setup() {
  _setups="$1/hardware/setups.py"
  [ -f "$_setups" ] || return 0
  _mem="$(memory_bytes)"
  _sum="$(py "$_setups" recommend --machine "$2" --memory-bytes "$_mem" --json 2>/dev/null || true)"
  [ -n "$_sum" ] || return 0
  _rec="$(printf '%s' "$_sum" | py -c 'import json, sys; print(json.load(sys.stdin)["recommended"] or "")' 2>/dev/null || true)"
  _gb="$(printf '%s' "$_sum" | py -c 'import json, sys; print(json.load(sys.stdin)["memory_gb"])' 2>/dev/null || gib "$_mem")"
  if [ -n "$_rec" ]; then
    say "memory: ${_gb} GB. The PAL app will recommend: $(py "$_setups" describe "$_rec" 2>/dev/null || echo "$_rec")"
    say "  (you choose in the app's setup, before any model downloads)"
  else
    _floor="$(printf '%s' "$_sum" | py -c 'import json, sys; print(json.load(sys.stdin)["smallest_gb"])' 2>/dev/null || echo 32)"
    say "WARNING: memory: ${_gb} GB. PAL needs at least ${_floor} GB here; the app can still install its smallest setup, but it won't fit well."
  fi
}

unsupported() {
  die "PAL installs on Ubuntu (x86_64) with an AMD graphics chip, like the GMKtec EVO-X2, or on an Apple Silicon Mac mini. This machine is $WHY, so the installer stops here. Nothing was changed."
}

# --- the licence ---------------------------------------------------------------
accept_eula() {
  say "PAL's licence (EULA ${PAL_EULA_VERSION}): ${PAL_EULA_URL}"
  if [ -n "$APP" ]; then
    # Agreed on the app's own screen before it ran this; recorded below
    # ($PAL_MAC_DIR/state/eula.json) and in the VM, by "app".
    EULA_AT="$(eula_time)" EULA_BY=app
    say "accepted in the PAL app ($EULA_AT)"
    return 0
  fi
  if [ -n "$YES_EULA" ]; then
    say "accepted (--yes-eula)"
  else
    ( : </dev/tty ) 2>/dev/null \
      || die "Read the licence at ${PAL_EULA_URL}, then run this in a terminal (or add --yes-eula)."
    printf '[pal] Type yes to accept it and install PAL: ' >/dev/tty
    answer=""
    read -r answer </dev/tty || answer=""
    [ "$answer" = yes ] || die "Not installed: the licence wasn't accepted (type yes to accept it)."
  fi
  EULA_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# --- fetching and checking -----------------------------------------------------
fetch() {  # url dest
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$2" "$1" \
    || die "can't reach $1 — check the network, then run this again"
}

py() { python3 -I "$@"; }

jget() {  # file key.path — one value from a JSON file ("" when it isn't there)
  py - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for k in sys.argv[2].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else (json.dumps(d) if isinstance(d, (dict, list)) else d))
PY
}

relpath_ok() {  # a manifest's URLs are paths under the updates root, nothing else
  case "$1" in ""|/*|*..*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
}

the_key() {
  key="${PAL_RELEASE_PUBKEY:-$PAL_RELEASE_PUBKEY_BUILTIN}"
  [ -n "$key" ] || die "this copy of the installer has no release key built in, so it can't check what it downloads. Use the one at https://get.trypai.ai."
  printf '%s\n' "$key" > "$WORK/pal-release.pub"
}

verify() {  # file — its .minisig beside it, against the release key
  py "$WORK/minisign_verify.py" -q -p "$WORK/pal-release.pub" -m "$1" -x "$1.minisig" \
    || die "$(basename "$1") is not signed by PAL's release key: nothing from it was used."
}

# CHANNEL_FILE, MANIFEST, VERSION, BUNDLE_URL, BUNDLE_SHA, BUNDLE_SIZE
find_release() {
  fetch "$URL/channels/$CHANNEL.json" "$WORK/channel.json"
  fetch "$URL/channels/$CHANNEL.json.minisig" "$WORK/channel.json.minisig"
  verify "$WORK/channel.json"
  [ "$(jget "$WORK/channel.json" channel)" = "$CHANNEL" ] || die "channels/$CHANNEL.json is another channel's pointer."
  VERSION="$(jget "$WORK/channel.json" version)"
  rel="$(jget "$WORK/channel.json" manifest)"
  relpath_ok "$rel" || die "the channel pointer names an odd manifest path: $rel"
  MANIFEST="$WORK/manifest.json"
  fetch "$URL/$rel" "$MANIFEST"
  fetch "$URL/$rel.minisig" "$MANIFEST.minisig"
  verify "$MANIFEST"
  [ "$(jget "$MANIFEST" schema)" = 1 ] || die "this installer doesn't read that manifest (schema $(jget "$MANIFEST" schema)); get the current one from https://get.trypai.ai"
  [ "$(jget "$MANIFEST" version)" = "$VERSION" ] || die "the manifest is not the release the channel points at."
  # The box bundle's own release: an app-only release carries an earlier one.
  box_v="$(jget "$MANIFEST" box.version)"
  [ -n "$box_v" ] && VERSION="$box_v"
  case "$VERSION" in ""|*[!0-9A-Za-z.+-]*) die "odd version: $VERSION" ;; esac
  BUNDLE_URL="$(jget "$MANIFEST" "box.bundles.$ARCH.url")"
  BUNDLE_SHA="$(jget "$MANIFEST" "box.bundles.$ARCH.sha256" | tr 'A-F' 'a-f' | sed 's/^sha256://')"
  BUNDLE_SIZE="$(jget "$MANIFEST" "box.bundles.$ARCH.size")"
  relpath_ok "$BUNDLE_URL" && [ -n "$BUNDLE_SHA" ] || die "PAL $VERSION has no $ARCH bundle."
  say "PAL $VERSION ($CHANNEL), signed and checked"
}

sha256() { py -c 'import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for b in iter(lambda: f.read(1 << 20), b""):
        h.update(b)
print(h.hexdigest())' "$1"; }

download_bundle() {  # → BUNDLE
  BUNDLE="$WORK/$(basename "$BUNDLE_URL")"
  say "downloading PAL $VERSION ($(( ${BUNDLE_SIZE:-0} / 1048576 )) MB)"
  fetch "$URL/$BUNDLE_URL" "$BUNDLE"
  if [ -n "$BUNDLE_SIZE" ] && [ "$(wc -c < "$BUNDLE" | tr -d ' ')" != "$BUNDLE_SIZE" ]; then
    die "the download is not the size the manifest signed: run this again"
  fi
  [ "$(sha256 "$BUNDLE")" = "$BUNDLE_SHA" ] || die "the download is not the file the manifest signed (sha256): nothing from it was used. Run this again."
}

# unpack DEST [root]: the bundle, whole, into DEST (via DEST.partial). Kept as
# it is when it was unpacked from this very bundle before.
unpack() {
  dest="$1" sudo_="${2:-}"
  if [ -f "$dest/.pal-unpacked" ] && [ "$(cat "$dest/.pal-unpacked")" = "$BUNDLE_SHA" ]; then
    say "PAL $VERSION is already unpacked in $dest"
    return 0
  fi
  if [ -e "$dest" ] && [ "$(readlink "$OPT" 2>/dev/null || true)" = "$dest" ]; then
    die "$dest is running, and holds another build of $VERSION. Nothing was changed."
  fi
  ${sudo_:+as_root} rm -rf "$dest.partial"
  ${sudo_:+as_root} mkdir -p "$dest.partial"
  zstd -dcq "$BUNDLE" | ${sudo_:+as_root} tar -x -C "$dest.partial" --no-same-owner \
    || die "couldn't unpack the bundle"
  ${sudo_:+as_root} mkdir -p "$dest.partial/release"
  ${sudo_:+as_root} cp "$MANIFEST" "$MANIFEST.minisig" "$dest.partial/release/"
  printf '%s\n' "$BUNDLE_SHA" | ${sudo_:+as_root} tee "$dest.partial/.pal-unpacked" >/dev/null
  ${sudo_:+as_root} rm -rf "$dest"
  ${sudo_:+as_root} mv "$dest.partial" "$dest"
  say "unpacked to $dest"
}

# --- the box (Linux) -------------------------------------------------------------
prereqs_linux() {
  # scripts/lib/prereqs.sh's packages (up.sh checks them again), plus what
  # this script itself uses: zstd for the bundle, qrencode for the QR.
  missing=""
  for p in rsync:rsync openssl:openssl setfacl:acl nft:nftables python3:python3 curl:curl \
           zstd:zstd qrencode:qrencode; do
    have "${p%%:*}" || missing="$missing ${p#*:}"
  done
  if [ -n "$missing" ]; then
    say "installing:$missing"
    as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # shellcheck disable=SC2086 # one word per package
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates $missing >/dev/null
  fi
  if ! { have docker && as_root docker compose version >/dev/null 2>&1; }; then
    say "installing Docker from Docker's apt repository (docs.docker.com/engine/install/ubuntu), at the pinned versions"
    codename="$(. "${PAL_OS_RELEASE:-/etc/os-release}" && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
    release="$(. "${PAL_OS_RELEASE:-/etc/os-release}" && printf '%s' "${VERSION_ID:-}")"
    have gpg || as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gpg >/dev/null
    key_url="${DOCKER_APT_KEY% *}"
    key_fpr="${DOCKER_APT_KEY#* }"
    curl -fsSL "$key_url" -o "$WORK/docker.asc" || die "couldn't fetch Docker's apt key ($key_url)"
    fpr="$(gpg --show-keys --with-colons "$WORK/docker.asc" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
    [ "$fpr" = "$key_fpr" ] || die "Docker's apt key is not the pinned one (fingerprint ${fpr:-none}, pinned $key_fpr)"
    as_root install -m 0755 -d /etc/apt/keyrings
    as_root install -m 0644 "$WORK/docker.asc" /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$(dpkg --print-architecture)" "$codename" | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
    as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    pkgs=""
    for p in $DOCKER_PKGS; do pkgs="$pkgs $p~ubuntu.$release~$codename"; done
    # shellcheck disable=SC2086 # one word per package
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >/dev/null
    as_root systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  # The model servers run on the AMD GPU through ROCm (prereqs.sh's check).
  [ -e /dev/kfd ] && [ -e /dev/dri ] \
    || die "PAL's model servers need an AMD GPU with ROCm (/dev/kfd and /dev/dri are missing on this box)."
}

not_source_box() {
  if source_box; then
    die "This machine runs PAL from a source checkout ($OPT is a folder, kept up to date with make up). The installer leaves it alone."
  fi
}

# --- a source box: the switch to the production build ------------------------------
# /opt/pal a real folder: PAL runs from a checkout (make up).
source_box() { [ -e "$OPT" ] && [ ! -L "$OPT" ]; }

# The Mac's VM runs PAL from a checkout (hardware/mac-mini-24/host/install.sh
# without a release): its /opt/pal is a folder there.
mac_vm_source() {
  _lc="${MAC_DIR:-${PAL_MAC_DIR:-/Users/Shared/PAL}}/bin/limactl"
  [ -x "$_lc" ] || _lc="$(command -v limactl 2>/dev/null || true)"
  [ -n "$_lc" ] || return 1
  "$_lc" list -q 2>/dev/null | grep -qx "${PAL_VM_NAME:-pal}" || return 1
  "$_lc" shell "${PAL_VM_NAME:-pal}" sh -c 'test -d /opt/pal && ! test -L /opt/pal' 2>/dev/null
}

# decide_switch PROFILE — on a source box: SWITCH=1 (--switch-from-source, or
# a yes to the question), else stop having changed nothing. Elsewhere SWITCH
# stays empty and the install goes on as it always has.
decide_switch() {
  _src=""
  case "$1" in
    evo-x2) source_box && _src=1 ;;
    mac-mini-24) mac_vm_source && _src=1 ;;
  esac
  if [ -z "$_src" ]; then
    [ -z "$SWITCH" ] || say "this machine doesn't run PAL from a source checkout, so there is nothing to switch: installing"
    SWITCH=""
    return 0
  fi
  if [ -n "$APP" ]; then
    die "This Mac runs PAL from a source checkout. Switch it to the production build from the PAL app (Settings › Updates), or in Terminal with --switch-from-source. Nothing was changed."
  fi
  if [ -n "$SWITCH" ]; then
    say "This machine runs PAL from a source checkout: switching it to the production build (--switch-from-source)."
    say "Your files, people, chats, settings and models stay."
    return 0
  fi
  _tty="${PAL_TTY:-/dev/tty}"
  ( : <"$_tty" ) 2>/dev/null \
    || die "This machine runs PAL from a source checkout ($OPT is a folder, kept up to date with make up). The installer leaves it alone: to switch it to the production build, run this in a terminal, or add --switch-from-source."
  printf '[pal] This machine runs PAL from a source checkout. Switch it to the production build? Your files, people, chats, settings and models stay. [y/N] '
  _answer=""
  read -r _answer <"$_tty" || _answer=""
  case "$_answer" in
    y|Y|yes|Yes|YES) SWITCH=1 ;;
    *) say "Not switched: nothing was changed."; exit 0 ;;
  esac
}

# The box's own pal-update (its source checkout's) runs the switch; one from
# before the switch existed can't.
switch_runner() {  # tree — prints its pal-update
  _pu="$1/pal-update/bin/pal-update"
  if [ ! -f "$_pu" ] || ! grep -q 'switch-to-release' "$1/pal-update/pal_update/cli.py" 2>/dev/null; then
    die "This PAL's source checkout is from before the switch to the production build: update it (git pull, then make up), then run this again. Nothing was changed."
  fi
  printf '%s\n' "$_pu"
}

# switch_release DIR [--no-host-side] — the box's pal-update switches it to the
# release unpacked and checked in DIR, keeping everything; it goes back by
# itself if anything fails (its own lines say each step).
switch_release() {
  _pu="$(switch_runner "$OPT")"
  _rc=0
  as_root python3 -I "$_pu" switch-to-release --release-dir "$1" --channel "$CHANNEL" --updates-url "$URL" \
    --pubkey "$(cat "$WORK/pal-release.pub")" ${2:+"$2"} || _rc=$?
  case "$_rc" in
    0) ;;
    4) die "Not switched: the lines above say why. Nothing was changed." ;;
    1) die "It went back to the development build (the lines above say why). Nothing else was changed." ;;
    3) die "This machine already runs the production build." ;;
    *) die "The switch failed and going back to the development build didn't finish cleanly either: the lines above say where (sudo pal-update status)." ;;
  esac
}

# switch_linux — a source box to the production build: the release found,
# checked, downloaded and unpacked exactly as for an install, then switched to.
switch_linux() {
  the_key
  find_release
  download_bundle
  dest="$RELEASES/$VERSION"
  as_root mkdir -p "$RELEASES"
  unpack "$dest" root
  switch_release "$dest"
  updater
  say "PAL now runs the production build, PAL $VERSION. Your phones and Macs stay paired."
}

# The Mac's side, kept before a switch so a failed one puts it back: the copy
# its jobs run ($PAL_MAC_DIR/src; copied, not moved, since the VM mounts it)
# and the com.pal.* launchd jobs. MAC_SAVED is where.
mac_save_host() {
  MAC_SAVED="$MAC_DIR/src-source-$(date -u +%Y%m%d-%H%M%S)"
  say "keeping this Mac's side of the development build in $MAC_SAVED (the way back)"
  mkdir -p "$MAC_SAVED/LaunchAgents" "$MAC_SAVED/LaunchDaemons"
  if [ -d "$MAC_DIR/src" ]; then cp -Rp "$MAC_DIR/src" "$MAC_SAVED/src"; fi
  for _f in "$HOME"/Library/LaunchAgents/com.pal.*.plist; do
    [ -f "$_f" ] && cp -p "$_f" "$MAC_SAVED/LaunchAgents/"
  done
  [ ! -f /Library/LaunchDaemons/com.pal.lan.plist ] || cp -p /Library/LaunchDaemons/com.pal.lan.plist "$MAC_SAVED/LaunchDaemons/"
}

# Everything mac_save_host kept, put back: the copy, the jobs as they were
# (restarted on it), and no pal-update agent the switch added.
mac_restore_host() {
  [ -n "${MAC_SAVED:-}" ] && [ -d "$MAC_SAVED" ] || return 0
  say "putting this Mac's side of the development build back ($MAC_SAVED)"
  if [ -d "$MAC_SAVED/src" ]; then
    mkdir -p "$MAC_DIR/src"
    rsync -a --delete "$MAC_SAVED/src/" "$MAC_DIR/src/" 2>/dev/null || cp -Rp "$MAC_SAVED/src/." "$MAC_DIR/src/"
  fi
  _uid="$(id -u)"
  for _f in "$MAC_SAVED"/LaunchAgents/*.plist; do
    [ -f "$_f" ] || continue
    _dest="$HOME/Library/LaunchAgents/${_f##*/}"
    if ! cmp -s "$_f" "$_dest"; then
      launchctl bootout "gui/$_uid/$(basename "$_f" .plist)" 2>/dev/null || true
      cp -p "$_f" "$_dest"
      launchctl bootstrap "gui/$_uid" "$_dest" 2>/dev/null || true
    fi
  done
  for _f in "$HOME"/Library/LaunchAgents/com.pal.*.plist; do
    [ -f "$_f" ] && [ ! -f "$MAC_SAVED/LaunchAgents/${_f##*/}" ] || continue
    launchctl bootout "gui/$_uid/$(basename "$_f" .plist)" 2>/dev/null || true
    rm -f "$_f"
  done
  if [ -f "$MAC_SAVED/LaunchDaemons/com.pal.lan.plist" ] \
     && ! cmp -s "$MAC_SAVED/LaunchDaemons/com.pal.lan.plist" /Library/LaunchDaemons/com.pal.lan.plist; then
    as_root launchctl bootout system/com.pal.lan 2>/dev/null || true
    as_root install -m 0644 "$MAC_SAVED/LaunchDaemons/com.pal.lan.plist" /Library/LaunchDaemons/com.pal.lan.plist
    as_root launchctl bootstrap system /Library/LaunchDaemons/com.pal.lan.plist 2>/dev/null || true
  fi
  for _f in "$MAC_SAVED"/LaunchAgents/*.plist; do
    [ -f "$_f" ] || continue
    launchctl kickstart -k "gui/$_uid/$(basename "$_f" .plist)" 2>/dev/null || true
  done
}

env_put() {  # file key value — replace the line, or add it; the file stays 0600
  as_root python3 -I - "$1" "$2" "$3" <<'PY'
import os, sys
path, key, value = sys.argv[1:]
lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
out, done = [], False
for line in lines:
    if line.startswith(key + "="):
        if not done:
            out.append(f"{key}={value}")
            done = True
        continue
    out.append(line)
if not done:
    out.append(f"{key}={value}")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
os.chmod(path, 0o600)
PY
}

# The release's .env: the running one's carried over (it holds the box's
# secrets), and what the updater reads from it.
release_env() {  # dir profile
  dir="$1"
  current="$(readlink "$OPT" 2>/dev/null || true)"
  if [ ! -e "$dir/.env" ] && [ -n "$current" ] && [ "$current" != "$dir" ] && [ -f "$current/.env" ]; then
    as_root cp -p "$current/.env" "$dir/.env"
  fi
  env_put "$dir/.env" PAL_UPDATE_MODE release
  env_put "$dir/.env" PAL_CHANNEL "$CHANNEL"
  [ "$URL" = "$DEFAULT_UPDATES_URL" ] || env_put "$dir/.env" PAL_UPDATES_URL "$URL"
  [ "$2" = evo-x2 ] || env_put "$dir/.env" PAL_HARDWARE "$2"
}

assemble() {  # dir
  [ -x "$1/scripts/box/assemble.sh" ] || die "the bundle has no scripts/box/assemble.sh"
  say "assembling PAL's images from their public sources (the first time takes a while)"
  ( cd "$1" && as_root env PAL_RELEASE_DIR="$1" ./scripts/box/assemble.sh ) \
    || die "assembling stopped (the lines above say why). Nothing that runs was changed: run this again later."
}

link_release() {  # dir — /opt/pal at it, in one rename
  [ "$(readlink "$OPT" 2>/dev/null || true)" = "$1" ] && return 0
  # A new link renamed over the old one (os.replace): never a moment with no
  # /opt/pal, and never the new link moved INTO the folder the old one names.
  as_root python3 -I -c 'import os, sys
t, link = sys.argv[1], sys.argv[2]
if os.path.lexists(link + ".next"):
    os.unlink(link + ".next")
os.symlink(t, link + ".next")
os.replace(link + ".next", link)' "$1" "$OPT"
  say "$OPT -> $1"
}

write_release() {  # dir manifest profile
  as_root python3 -I - "$1" "$2" "$CHANNEL" "$3" <<'PY'
import json, os, sys, time
d, manifest, channel, profile = sys.argv[1:]
m = json.load(open(manifest, encoding="utf-8"))
box = m.get("box") or {}
# The box bundle's own release (box.version), else the manifest's.
rec = {"version": box.get("version") or m["version"],
       "build": int((box.get("build") if box.get("build") is not None else m.get("build")) or 0),
       "git_rev": box.get("git_rev") or m.get("git_rev") or "unknown",
       "channel": channel, "edition": m.get("edition") or "free", "profile": profile,
       "installed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
       "min_app": box.get("min_app") or {"android": "0.0.0", "mac": "0.0.0", "ios": "0.0.0"},
       "data_epoch": int(m.get("data_epoch") or 0), "opencode": box.get("opencode") or ""}
tmp = os.path.join(d, ".RELEASE.json.tmp")
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(rec, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.chmod(tmp, 0o644)
os.replace(tmp, os.path.join(d, "RELEASE.json"))
PY
  notes="$1/release/notes/$VERSION.md"
  if [ -f "$notes" ]; then
    as_root mkdir -p "$NOTES_DIR"
    as_root install -m 0644 "$notes" "$NOTES_DIR/$VERSION.md"
  fi
}

up_release() {  # profile
  say "starting PAL (scripts/up.sh --release)"
  if [ "$1" = evo-x2 ]; then set -- --release; else set -- --release --hardware "$1"; fi
  as_root env ${PAL_FIRST_ADMIN:+PAL_FIRST_ADMIN="$PAL_FIRST_ADMIN"} "$OPT/scripts/up.sh" "$@" \
    || die "PAL didn't start (the [up] lines above say where). Fix that, then run this again; it carries on."
}

updater() {
  if [ -f "$OPT/pal-update/systemd/pal-update.service" ]; then
    # install-host.sh (run by up.sh) installs the unit on a release box; this
    # makes sure, and starts it.
    as_root install -m 644 "$OPT/pal-update/systemd/pal-update.service" /etc/systemd/system/pal-update.service
    as_root ln -sf "$OPT/pal-update/bin/pal-update" /usr/local/bin/pal-update
    as_root systemctl daemon-reload
    as_root systemctl enable pal-update >/dev/null 2>&1 || true
    as_root systemctl start pal-update || say "WARNING: pal-update didn't start (journalctl -u pal-update)"
    say "pal-update installed: PAL updates itself overnight (sudo pal-update status)"
  else
    say "WARNING: this release has no pal-update; it won't update itself"
  fi
  as_root mkdir -p /var/lib/pal/update
  # Inside a Mac's VM the licence was accepted on the Mac (by the installer
  # in Terminal, or in the PAL app): its time and who come in the environment.
  if [ -z "${EULA_AT:-}" ] && [ -n "${PAL_EULA_ACCEPTED_AT:-}" ]; then EULA_AT="$(eula_time)"; fi
  case "${PAL_EULA_BY:-}" in app) by=app ;; *) by=installer ;; esac
  printf '{"eula": {"version": "%s", "accepted_at": "%s", "by": "%s"}, "channel": "%s", "version": "%s"}\n' \
    "$PAL_EULA_VERSION" "${EULA_AT:-}" "${EULA_BY:-$by}" "$CHANNEL" "$VERSION" | as_root tee /var/lib/pal/update/install.json >/dev/null
}

# --- the pairing code ------------------------------------------------------------
# What Setup's "pair a phone" shows (pal-api onboarding_core.pair_code): the
# pal://pair link the QR carries, with a six-digit code beside it to compare.
pairing() {  # box_url lan_host user
  status=""
  i=0
  while [ "$i" -lt 30 ]; do
    status="$(curl -fsS --max-time 3 "$1/api/discovery/status" 2>/dev/null || true)"
    [ -n "$status" ] && break
    i=$((i + 1)); sleep 2
  done
  link="$(py - "$2" "$status" <<'PY' 2>/dev/null || true
import json, sys
from urllib.parse import quote, urlencode
host = sys.argv[1]
try:
    s = json.loads(sys.argv[2] or "{}")
except ValueError:
    s = {}
params = {"host": host}
if s.get("nasId"):
    params["id"] = s["nasId"]
params["name"] = s.get("name") or "PAL"
print("pal://pair?" + urlencode(params, quote_via=quote))
PY
)"
  [ -n "$link" ] || link="pal://pair?host=$2"
  # The first line only: macOS's od ends with a blank one, which made twelve digits.
  code="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ' | awk 'NF {printf "%06d", $1 % 1000000; exit}')"
  echo
  echo "──────────────────────────────────────────────────────────────────────"
  echo "  PAL is installed. Open the PAL app on your phone or Mac."
  echo
  if have qrencode; then
    qrencode -t ANSIUTF8 -m 1 "$link" 2>/dev/null | sed 's/^/  /' || true
  fi
  echo "  Pairing code  ${code%???} ${code#???}   (check the app shows the same)"
  echo "  Or open       $link"
  echo "  Sign in as    $3, with that account's password"
  echo "  Updates       overnight, 03:00–05:00 (sudo pal-update status)"
  echo "──────────────────────────────────────────────────────────────────────"
  # The same, as one line the Mac app reads.
  if [ -n "$APP" ]; then
    printf 'PAL-PAIRING %s\n' "$(py -c 'import json, sys
print(json.dumps(dict(zip(("link", "code", "host", "user", "box_url"), sys.argv[1:])), separators=(",", ":")))' \
      "$link" "$code" "$2" "$3" "$1")"
  fi
}

first_admin() { printf '%s' "${PAL_FIRST_ADMIN:-${SUDO_USER:-$(id -un)}}"; }

install_linux() {
  if [ -n "$SWITCH" ]; then
    prereqs_linux
    switch_linux
    return 0
  fi
  not_source_box
  prereqs_linux
  the_key
  find_release
  download_bundle
  dest="$RELEASES/$VERSION"
  as_root mkdir -p "$RELEASES"
  unpack "$dest" root
  say_setup "$dest" nas
  release_env "$dest" evo-x2
  assemble "$dest"
  link_release "$dest"
  write_release "$dest" "$dest/release/manifest.json" evo-x2
  up_release evo-x2
  updater
  lan="$(sed -n 's/^NAS_LAN_IP=//p' "$OPT/.env" 2>/dev/null | tail -n1)"
  [ -n "$lan" ] || lan="$(hostname -I 2>/dev/null | awk '{print $1}')"
  pairing http://127.0.0.1:3000 "${lan:-$(hostname)}" "$(first_admin)"
}

# --- the Mac mini ------------------------------------------------------------------
# Apple's command line tools, unattended, the way Homebrew's installer fetched
# them: the one thing not pinned (Apple offers only the current tools for each
# macOS, and signs them).
mac_command_line_tools() {
  if xcode-select -p >/dev/null 2>&1 && /usr/bin/xcrun --find make >/dev/null 2>&1; then return 0; fi
  say "installing Apple's command line tools (from Apple's software update; your password once)"
  local flag=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress label
  as_root touch "$flag"
  label="$(softwareupdate -l 2>/dev/null | grep -B 1 -E 'Command Line Tools' \
    | awk -F'*' '/^ *\*/ {print $2}' | sed -e 's/^ *Label: //' -e 's/^ *//' | sort -V | tail -n1)"
  if [ -z "$label" ]; then
    as_root rm -f "$flag"
    die "Apple's software update offers no command line tools right now: run xcode-select --install, then this again."
  fi
  as_root softwareupdate -i "$label" || { as_root rm -f "$flag"; die "Apple's command line tools did not install ($label)"; }
  as_root rm -f "$flag"
  as_root xcode-select --switch /Library/Developer/CommandLineTools
}

# zstd, to unpack the bundle: the pinned source release (ZSTD_PIN), checked by
# sha256, built once into $MAC_DIR/opt and linked into $MAC_DIR/bin. One this
# Mac already has is used as it is.
mac_zstd() {
  have zstd && return 0
  local ver url sha file dir src
  set -- $ZSTD_PIN
  ver="$1" url="$2" sha="$3"
  dir="$MAC_DIR/opt/zstd-$ver"
  if [ ! -x "$dir/zstd" ]; then
    mkdir -p "$MAC_DIR/opt/dl"
    file="$MAC_DIR/opt/dl/${url##*/}"
    if ! { [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; }; then
      say "downloading zstd $ver ($url)"
      curl -fL --retry 5 --retry-delay 5 -o "$file.part" "$url" || die "couldn't download zstd ($url)"
      [ "$(shasum -a 256 "$file.part" | cut -d' ' -f1)" = "$sha" ] \
        || { rm -f "$file.part"; die "zstd from $url is not the pinned file (its sha256 differs)"; }
      mv -f "$file.part" "$file"
    fi
    src="$MAC_DIR/opt/src/zstd-$ver"
    rm -rf "$src"
    mkdir -p "$src"
    tar -xzf "$file" -C "$src" --strip-components 1
    make -C "$src/programs" -j "$(sysctl -n hw.ncpu)" zstd >/dev/null 2>&1 || die "zstd $ver did not build"
    mkdir -p "$dir"
    install -m 0755 "$src/programs/zstd" "$dir/zstd"
    rm -rf "$src"
  fi
  mkdir -p "$MAC_DIR/bin"
  ln -sfn "$dir/zstd" "$MAC_DIR/bin/zstd"
  PATH="$MAC_DIR/bin:$PATH"
  export PATH
}

install_mac() {
  [ "$(id -u)" -ne 0 ] || die "run this as yourself (an administrator of this Mac), not as root"
  MAC_DIR="${PAL_MAC_DIR:-/Users/Shared/PAL}"
  case "$MAC_DIR" in *" "*) die "PAL_MAC_DIR must not contain spaces: $MAC_DIR" ;; esac
  progress prepare "Getting this Mac ready"
  # With no terminal (the Mac app), sudo asks in macOS's own dialog.
  [ -z "$APP" ] || app_askpass
  # Apple's command line tools (python3, and a compiler for zstd), from Apple's
  # own software update; then zstd, pinned. No Homebrew: it installed whatever
  # was current that day. (The QR is printed when qrencode is already here.)
  mac_command_line_tools
  mac_zstd
  python3 -c '' 2>/dev/null || die "python3 doesn't run on this Mac yet: install Apple's command line tools (xcode-select --install), then run this again."
  if [ -n "$APP" ]; then
    # The licence the app showed, accepted there: kept beside the install's state.
    mkdir -p "$MAC_DIR/state"
    printf '{"version": "%s", "url": "%s", "accepted_at": "%s", "by": "app"}\n' \
      "$(json_str "$PAL_EULA_VERSION")" "$(json_str "$PAL_EULA_URL")" "$EULA_AT" > "$MAC_DIR/state/eula.json"
  fi
  progress release "Finding the newest PAL"
  the_key
  find_release
  progress download "Downloading PAL $VERSION ($(( ${BUNDLE_SIZE:-0} / 1048576 )) MB)"
  download_bundle
  dest="$MAC_DIR/releases/$VERSION"
  mkdir -p "$MAC_DIR/releases"
  progress unpack "Unpacking PAL $VERSION"
  unpack "$dest"
  host_install="$dest/hardware/mac-mini-24/host/install.sh"
  [ -x "$host_install" ] || die "the bundle has no hardware/mac-mini-24/host/install.sh"
  say "setting up this Mac and its VM ($host_install)"
  # Its own steps' PAL-PROGRESS lines come from it (tools … deploy), numbered
  # in this run's list.
  tty=/dev/null
  [ -n "$APP" ] || { ( : </dev/tty ) 2>/dev/null && tty=/dev/tty; } || true
  # A switch from source: the Mac's side kept first, and put back if this stops
  # (the VM's own switch goes back by itself).
  [ -z "$SWITCH" ] || mac_save_host
  host_rc=0
  env PAL_RELEASE_VERSION="$VERSION" PAL_CHANNEL="$CHANNEL" PAL_UPDATES_URL="$URL" \
    PAL_RELEASE_PUBKEY="${PAL_RELEASE_PUBKEY:-$PAL_RELEASE_PUBKEY_BUILTIN}" PAL_MAC_DIR="$MAC_DIR" \
    PAL_EULA_ACCEPTED_AT="${EULA_AT:-}" PAL_EULA_BY="${EULA_BY:-installer}" \
    ${APP:+"PAL_PROGRESS_STEPS=$APP_STEPS"} ${SWITCH:+PAL_SWITCH_FROM_SOURCE=1} \
    "$host_install" ${APP:+--app} <"$tty" || host_rc=$?
  if [ "$host_rc" -ne 0 ]; then
    if [ -n "$SWITCH" ]; then
      mac_restore_host
      die "It went back to the development build (the lines above say why). The Mac's side is as it was."
    fi
    host_stopped "$host_rc"
  fi
  progress updater "Setting up PAL's overnight updates"
  /usr/bin/python3 -I "$dest/pal-update/bin/pal-update" mac-install --from "$dest" --vm "${PAL_VM_NAME:-pal}" \
    --mac-dir "$MAC_DIR" || say "WARNING: pal-update's Mac agent didn't install; the Mac's side won't update itself"
  if [ -n "$SWITCH" ]; then
    say "PAL now runs the production build, PAL $VERSION. Your phones and Macs stay paired."
    say "The development build's Mac side is kept in $MAC_SAVED (the VM keeps its own in /opt/pal-source-<stamp>)."
    progress done "PAL is ready"
    return 0
  fi
  lan="$("$MAC_DIR/src/hardware/mac-mini-24/host/pal-address" --print "${PAL_VM_NETWORK:-forward}" "${PAL_VM_NAME:-pal}" 2>/dev/null || true)"
  port="$(sed -n 's/^PAL_HOST_PORT_BOX=//p' "$dest/hardware/mac-mini-24/hardware.env" | tail -n1)"
  pairing "http://127.0.0.1:${port:-13000}" "${lan:-$(ipconfig getifaddr en0 2>/dev/null || hostname)}" \
    "${PAL_VM_USER:-$(id -un | tr 'A-Z' 'a-z')}"
  progress done "PAL is ready"
}

# The Mac's install.sh stopped. From the app, its install-result.json already
# says at which step and why, and its exit code (3: the download was paused)
# is this run's too.
host_stopped() {  # its exit code
  if [ -n "$APP" ]; then
    HOST_RESULT=1
    exit "$1"
  fi
  die "setting up the Mac stopped (the lines above say where). Run this again; it carries on."
}

# Inside the Mac's VM, run by hardware/mac-mini-24/host/install.sh (as root,
# through limactl shell): the release the Mac unpacked and checked, seen
# here at FROM (its read-only mount), installed like a box's.
install_in_vm() {
  [ "$(id -u)" -eq 0 ] || die "--in-vm runs as root"
  [ -f "$FROM/release/manifest.json" ] || die "--from $FROM holds no release (release/manifest.json)"
  if [ -n "$SWITCH" ] && source_box; then
    # The switch's runner must be here before anything is copied.
    switch_runner "$OPT" >/dev/null
  else
    not_source_box
  fi
  MANIFEST="$FROM/release/manifest.json"
  if [ -n "${PAL_RELEASE_PUBKEY:-$PAL_RELEASE_PUBKEY_BUILTIN}" ]; then
    the_key
    verify "$MANIFEST"
  fi
  VERSION="$(jget "$MANIFEST" box.version)"
  [ -n "$VERSION" ] || VERSION="$(jget "$MANIFEST" version)"
  case "$VERSION" in ""|*[!0-9A-Za-z.+-]*) die "odd version: $VERSION" ;; esac
  BUNDLE_SHA="$(cat "$FROM/.pal-unpacked" 2>/dev/null || echo copied)"
  dest="$RELEASES/$VERSION"
  mkdir -p "$RELEASES"
  if [ "$(cat "$dest/.pal-unpacked" 2>/dev/null || true)" != "$BUNDLE_SHA" ] || [ "$BUNDLE_SHA" = copied ]; then
    rm -rf "$dest.partial"
    mkdir -p "$dest.partial"
    # The Mac's copy, without what is the Mac's own (install.sh's REVISION) or a box's (.env).
    (cd "$FROM" && tar -cf - --exclude ./.env .) | tar -x -C "$dest.partial" --no-same-owner
    printf '%s\n' "$BUNDLE_SHA" > "$dest.partial/.pal-unpacked"
    [ "$(readlink "$OPT" 2>/dev/null || true)" = "$dest" ] && [ -f "$dest/.env" ] && cp -p "$dest/.env" "$dest.partial/.env"
    rm -rf "$dest"
    mv "$dest.partial" "$dest"
  fi
  if [ -n "$SWITCH" ] && source_box; then
    # The Mac's install.sh does the Mac's side itself (and puts it back on a stop).
    [ -n "${PAL_RELEASE_PUBKEY:-$PAL_RELEASE_PUBKEY_BUILTIN}" ] || die "no release key to check the release with"
    switch_release "$dest" --no-host-side
    updater
    return 0
  fi
  release_env "$dest" mac-mini-24
  assemble "$dest"
  link_release "$dest"
  write_release "$dest" "$MANIFEST" mac-mini-24
  up_release mac-mini-24
  updater
}

# --- the plan, for --dry-run -----------------------------------------------------
plan() {
  say "dry run: nothing is changed or fetched"
  say "this machine: $PROFILE ($ARCH), $(gib "$(memory_bytes)") GB of memory"
  n=0
  step() { n=$((n + 1)); say "  $n. $*"; }
  if [ -n "$APP" ]; then
    step "the licence ($PAL_EULA_URL): accepted in the PAL app, recorded in ${PAL_MAC_DIR:-/Users/Shared/PAL}/state/eula.json"
  else
    step "show the licence ($PAL_EULA_URL) and ask for yes"
  fi
  if [ -n "$SWITCH" ] || { [ "$PROFILE" = evo-x2 ] && source_box; }; then
    step "this machine runs PAL from a source checkout: ask, or with --switch-from-source go straight on, to switch it to the production build"
    step "fetch $URL/channels/$CHANNEL.json and its manifest; check both with PAL's release key; download and check the $ARCH bundle; unpack it to $RELEASES/<version>/"
    step "the box's own pal-update switches to it, keeping everything: the version check, assemble.sh, a snapshot, $OPT set aside as $OPT-source-<stamp>, $OPT linked to the release, the .env carried over, RELEASE.json, up.sh --release and the health checks; back to the development build by itself if anything fails"
    return 0
  fi
  case "$PROFILE" in
    evo-x2)
      step "install what is missing (rsync, openssl, acl, nftables, python3, curl, zstd, qrencode) and Docker from Docker's apt repository (its key by fingerprint, pinned versions)"
      step "fetch $URL/channels/$CHANNEL.json and its manifest; check both with PAL's release key"
      step "download the $ARCH bundle and check its sha256 against the manifest"
      step "unpack it to $RELEASES/<version>/"
      step "say the setup the PAL app will recommend for this memory (its hardware/setups.json)"
      step "run its scripts/box/assemble.sh"
      step "link $OPT to it and write $OPT/RELEASE.json"
      step "run $OPT/scripts/up.sh --release"
      step "install and start pal-update"
      step "print the pairing code and QR, and 'Open the PAL app'" ;;
    mac-mini-24)
      step "install Apple's command line tools if there are none, then zstd (pinned, built from its source release)"
      step "fetch $URL/channels/$CHANNEL.json and its manifest; check both with PAL's release key"
      step "download the $ARCH bundle and check its sha256 against the manifest"
      step "unpack it to ${PAL_MAC_DIR:-/Users/Shared/PAL}/releases/<version>/"
      step "run its hardware/mac-mini-24/host/install.sh: the Mac's tools, models and servers, the Lima VM, and this release installed inside the VM (--in-vm)"
      step "install pal-update's Mac agent (launchd)"
      step "print the pairing code and QR, and 'Open the PAL app'" ;;
  esac
}

# --- the embedded minisign verifier (release/lib/minisign_verify.py, verbatim) ---
write_verifier() {
  cat > "$1" <<'PAL_MINISIGN_VERIFY_PY'
#!/usr/bin/env python3
"""Verify minisign signatures with nothing but Python's standard library.

What signs PAL's releases (docs/shipping-plan.md §3.4, docs/shipping-interfaces.md
§4): the channel pointers and the manifest are signed with minisign (Ed25519),
and a box checks them before it trusts a byte. A fresh host has only `python3`,
so this has no dependencies: Ed25519 is done here in plain integers (RFC 8032),
SHA-512 and BLAKE2b come from hashlib. It is slow next to libsodium (tens of
milliseconds a signature), which is fine for the few files a release has.

Both signature algorithms minisign writes:

  * `Ed` — the legacy one: the signature is over the file itself.
  * `ED` — prehashed (minisign's default since 0.9): over BLAKE2b-512 of the file.

and the trusted comment's global signature, over the file's signature followed
by the trusted comment, so the comment (minisign puts a timestamp and the file
name there) can't be swapped either. The key id in the signature must be the
public key's.

As a module:

    import minisign_verify as mv
    key = mv.load_public_key(open("pal-release.pub").read())
    comment = mv.verify(key, data, open("manifest.json.minisig").read())   # raises mv.VerifyError

As a command, with minisign's own flags:

    python3 minisign_verify.py -p pal-release.pub -m manifest.json [-x manifest.json.minisig]
    python3 minisign_verify.py -P RWQ… -m manifest.json

exit 0 when the signature and the comment's signature both check, 1 when not
(the reason on stderr), 2 for a usage error.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import sys
from dataclasses import dataclass

__all__ = ["PublicKey", "Signature", "VerifyError", "load_public_key", "parse_signature",
           "verify", "verify_file", "ed25519_verify", "main"]

# ----------------------------------------------------------------- Ed25519
# RFC 8032 §5.1, points in extended coordinates (X, Y, Z, T) with x = X/Z,
# y = Y/Z and x*y = T/Z. Verification only needs public data, so nothing
# here has to run in constant time.
_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)


def _inv(x: int) -> int:
    return pow(x, _P - 2, _P)


def _recover_x(y: int, sign: int) -> int | None:
    if y >= _P:
        return None
    x2 = (y * y - 1) * _inv(_D * y * y + 1) % _P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P:
        x = x * _SQRT_M1 % _P
    if (x * x - x2) % _P:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


def _add(a: tuple, b: tuple) -> tuple:
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    pa = (y1 - x1) * (y2 - x2) % _P
    pb = (y1 + x1) * (y2 + x2) % _P
    pc = 2 * t1 * t2 * _D % _P
    pd = 2 * z1 * z2 % _P
    e, f, g, h = pb - pa, pd - pc, pd + pc, pb + pa
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _mul(s: int, point: tuple) -> tuple:
    q = (0, 1, 1, 0)  # the neutral element
    while s > 0:
        if s & 1:
            q = _add(q, point)
        point = _add(point, point)
        s >>= 1
    return q


def _same(a: tuple, b: tuple) -> bool:
    return (a[0] * b[2] - b[0] * a[2]) % _P == 0 and (a[1] * b[2] - b[1] * a[2]) % _P == 0


def _compress(point: tuple) -> bytes:
    zi = _inv(point[2])
    x, y = point[0] * zi % _P, point[1] * zi % _P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _decompress(raw: bytes) -> tuple | None:
    if len(raw) != 32:
        return None
    y = int.from_bytes(raw, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % _P)


_GY = 4 * _inv(5) % _P
_G = (_recover_x(_GY, 0), _GY, 1, _recover_x(_GY, 0) * _GY % _P)


def _hash_int(data: bytes) -> int:
    return int.from_bytes(hashlib.sha512(data).digest(), "little") % _L


def ed25519_verify(public: bytes, message: bytes, signature: bytes) -> bool:
    """RFC 8032 Ed25519 verification: True when `signature` is `public`'s over
    `message`. Never raises on bad input; anything malformed is False."""
    if len(public) != 32 or len(signature) != 64:
        return False
    a = _decompress(public)
    r = _decompress(signature[:32])
    if a is None or r is None:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= _L:
        return False
    h = _hash_int(signature[:32] + public + message)
    return _same(_mul(s, _G), _add(r, _mul(h, a)))


# ---------------------------------------------------------------- minisign
class VerifyError(Exception):
    """The signature, the key or the file is not what it should be."""


@dataclass(frozen=True)
class PublicKey:
    key_id: bytes   # 8 bytes, as minisign writes it (little-endian on the wire)
    key: bytes      # 32 bytes, the Ed25519 public key

    @property
    def key_id_hex(self) -> str:
        """The id the way `minisign -V` prints it (the bytes reversed, hex)."""
        return self.key_id[::-1].hex().upper()


@dataclass(frozen=True)
class Signature:
    algorithm: bytes          # b"Ed" (legacy) or b"ED" (prehashed with BLAKE2b-512)
    key_id: bytes
    signature: bytes          # 64 bytes
    trusted_comment: str
    global_signature: bytes   # 64 bytes, over signature + trusted comment
    untrusted_comment: str = ""


_UNTRUSTED = "untrusted comment:"
_TRUSTED = "trusted comment: "


def _b64(text: str, what: str) -> bytes:
    try:
        return base64.b64decode(text.strip(), validate=True)
    except (binascii.Error, ValueError):
        raise VerifyError(f"{what} is not base64") from None


def load_public_key(text: str) -> PublicKey:
    """A minisign public key: the file's two lines, or the base64 line alone
    (what `minisign -P` takes)."""
    lines = [ln.strip() for ln in str(text).splitlines() if ln.strip()]
    if lines and lines[0].lower().startswith(_UNTRUSTED):
        lines = lines[1:]
    if len(lines) != 1:
        raise VerifyError("a public key is one base64 line (after its untrusted comment)")
    raw = _b64(lines[0], "the public key")
    if len(raw) != 42 or raw[:2] != b"Ed":
        raise VerifyError("not a minisign Ed25519 public key")
    return PublicKey(key_id=raw[2:10], key=raw[10:])


def parse_signature(text: str) -> Signature:
    """A `.minisig` file: untrusted comment, signature, trusted comment, global signature."""
    lines = [ln.rstrip("\r") for ln in str(text).split("\n")]
    while lines and not lines[-1].strip():
        lines.pop()
    if len(lines) < 4:
        raise VerifyError("a minisign signature has four lines")
    untrusted, sig_line, trusted_line, global_line = lines[:4]
    if not untrusted.lower().startswith(_UNTRUSTED):
        raise VerifyError("the signature's first line is not its untrusted comment")
    raw = _b64(sig_line, "the signature")
    if len(raw) != 74 or raw[:2] not in (b"Ed", b"ED"):
        raise VerifyError("not a minisign Ed25519 signature")
    if not trusted_line.startswith(_TRUSTED):
        raise VerifyError("the signature has no trusted comment")
    global_sig = _b64(global_line, "the trusted comment's signature")
    if len(global_sig) != 64:
        raise VerifyError("the trusted comment's signature is the wrong length")
    return Signature(algorithm=raw[:2], key_id=raw[2:10], signature=raw[10:],
                     trusted_comment=trusted_line[len(_TRUSTED):], global_signature=global_sig,
                     untrusted_comment=untrusted[len(_UNTRUSTED):].strip())


def _check(key: PublicKey, sig: Signature, signed: bytes) -> str:
    if sig.key_id != key.key_id:
        raise VerifyError(f"signed with another key (id {sig.key_id[::-1].hex().upper()}, "
                          f"expected {key.key_id_hex})")
    if not ed25519_verify(key.key, signed, sig.signature):
        raise VerifyError("signature verification failed")
    comment = sig.trusted_comment.encode("utf-8")
    if not ed25519_verify(key.key, sig.signature + comment, sig.global_signature):
        raise VerifyError("comment signature verification failed")
    return sig.trusted_comment


def verify(key: PublicKey | str, data: bytes, signature: Signature | str, *,
           allow_legacy: bool = True) -> str:
    """Check `signature` over `data` with `key`. Returns the trusted comment;
    raises VerifyError otherwise."""
    if isinstance(key, str):
        key = load_public_key(key)
    if isinstance(signature, str):
        signature = parse_signature(signature)
    if signature.algorithm == b"ED":
        signed = hashlib.blake2b(data, digest_size=64).digest()
    elif allow_legacy:
        signed = bytes(data)
    else:
        raise VerifyError("legacy (non-prehashed) signatures are not accepted here")
    return _check(key, signature, signed)


def verify_file(key: PublicKey | str, path: str, sig_path: str | None = None, *,
                allow_legacy: bool = True) -> str:
    """`verify` for a file on disk (its signature at `<path>.minisig` unless
    said). A prehashed signature is checked without reading the file whole."""
    if isinstance(key, str):
        key = load_public_key(key)
    with open(sig_path or f"{path}.minisig", encoding="utf-8") as fh:
        signature = parse_signature(fh.read())
    if signature.algorithm == b"ED":
        h = hashlib.blake2b(digest_size=64)
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return _check(key, signature, h.digest())
    if not allow_legacy:
        raise VerifyError("legacy (non-prehashed) signatures are not accepted here")
    with open(path, "rb") as fh:
        return _check(key, signature, fh.read())


# ------------------------------------------------------------------ the CLI
_USAGE = """usage: minisign_verify.py (-p PUBKEY_FILE | -P PUBKEY) -m FILE [-x SIGFILE] [-q] [-Q]

  -p FILE   public key file (default ./minisign.pub)
  -P KEY    public key, as its base64 line
  -m FILE   the file that was signed
  -x FILE   its signature (default FILE.minisig)
  -q        quiet: print nothing on success
  -Q        print only the trusted comment
  -l        refuse legacy (non-prehashed) signatures"""


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    opts: dict[str, str] = {}
    flags: set[str] = set()
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-p", "-P", "-m", "-x"):
            if i + 1 >= len(args):
                print(_USAGE, file=sys.stderr)
                return 2
            opts[a] = args[i + 1]
            i += 2
        elif a in ("-q", "-Q", "-l", "-V"):   # -V: minisign's verify mode, which this always is
            flags.add(a)
            i += 1
        elif a in ("-h", "--help"):
            print(_USAGE)
            return 0
        else:
            print(f"unknown argument: {a}\n{_USAGE}", file=sys.stderr)
            return 2
    if "-m" not in opts:
        print(_USAGE, file=sys.stderr)
        return 2
    try:
        if "-P" in opts:
            key = load_public_key(opts["-P"])
        else:
            with open(opts.get("-p", "minisign.pub"), encoding="utf-8") as fh:
                key = load_public_key(fh.read())
        comment = verify_file(key, opts["-m"], opts.get("-x"), allow_legacy="-l" not in flags)
    except (OSError, VerifyError) as exc:
        print(f"minisign_verify: {exc}", file=sys.stderr)
        return 1
    if "-Q" in flags:
        print(comment)
    elif "-q" not in flags:
        print("Signature and comment signature verified")
        print(f"Trusted comment: {comment}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PAL_MINISIGN_VERIFY_PY
}

main() {
  YES_EULA="" DRY="" DETECT="" IN_VM="" FROM="" SWITCH=""
  CHANNEL="${PAL_CHANNEL:-beta}"
  URL="${PAL_UPDATES_URL:-$DEFAULT_UPDATES_URL}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes-eula) YES_EULA=1 ;;
      --dry-run) DRY=1 ;;
      --detect) DETECT=1 ;;
      --in-vm) IN_VM=1 ;;
      --from) FROM="${2:-}"; shift ;;
      --channel) CHANNEL="${2:-}"; shift ;;
      --updates-url) URL="${2:-}"; shift ;;
      --app) APP=1 ;;
      --switch-from-source) SWITCH=1 ;;
      -h|--help) sed -n '2,/^set -eu$/p' "$0" 2>/dev/null | sed '$d' || say "see https://get.trypai.ai"; return 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
  done
  URL="${URL%/}"
  trap 'on_exit $?' EXIT
  # From the Mac app: it reads how this run goes in install-result.json, from
  # the first line on (a stop before the download included).
  if [ -n "$APP" ] && [ -z "$DETECT$DRY$IN_VM" ]; then
    case "${PAL_MAC_DIR:-/Users/Shared/PAL}" in
      *" "*) ;;   # install_mac stops on it, with nowhere to say so
      *) APP_STATE="${PAL_MAC_DIR:-/Users/Shared/PAL}/state" ;;
    esac
    app_result "$(printf '{"running":true,"pid":%s,"app":true,"installer":"release","started_at":"%s"}' "$$" "$(utc_now)")"
  fi
  case "$CHANNEL" in ""|*[!a-z0-9-]*) die "a channel is a name like beta: $CHANNEL" ;; esac

  if [ -n "$IN_VM" ]; then
    [ -n "$FROM" ] || die "--in-vm needs --from <the release folder>"
    WORK="$(mktemp -d)"
    write_verifier "$WORK/minisign_verify.py"
    install_in_vm
    return 0
  fi

  detect
  if [ -n "$DETECT" ]; then
    if [ -n "$PROFILE" ]; then echo "$PROFILE $ARCH"; return 0; fi
    echo "unsupported: $WHY"
    return 1
  fi
  # The app runs PAL on the Mac it is on: the mac-mini-24 profile.
  if [ -n "$APP" ] && [ "$PROFILE" != mac-mini-24 ]; then
    die "Run PAL on this Mac needs a Mac with Apple silicon (M1 or later), and this is ${WHY:-$PROFILE}. Nothing was changed."
  fi
  [ -n "$PROFILE" ] || unsupported
  if [ -n "$DRY" ]; then
    plan
    return 0
  fi
  say "installing PAL on this machine ($PROFILE, $(gib "$(memory_bytes)") GB of memory)"
  decide_switch "$PROFILE"
  accept_eula
  WORK="$(mktemp -d)"
  write_verifier "$WORK/minisign_verify.py"
  case "$PROFILE" in
    evo-x2) install_linux ;;
    mac-mini-24) install_mac ;;
  esac
}

# Last, so a download cut off half way runs nothing at all.
main "$@"
