#!/usr/bin/env bash
# Install the SN46 miner on this machine in one command:
#
#   curl -fsSL https://raw.githubusercontent.com/Subnet46/sn46-miner-releases/main/install.sh | sudo bash
#
# Works on a plain Ubuntu 24.04 host (a DigitalOcean GPU droplet, bare metal: a systemd
# service) and inside a GPU container without systemd (RunPod: a supervised worker, all
# state on the volume). It checks the machine, downloads the current release, verifies
# it against the signing key pinned below, asks for the miner uid and hotkey, downloads
# the checkpoint, starts the worker and waits until the platform accepts it.
#
# Re-running resumes: what is done is kept. In a container that is also how the miner
# comes back after the pod restarts.
#
# Options (environment; with sudo, pass them as `sudo env VAR=value bash`):
#   SN46_SETUP_UID, SN46_SETUP_HOTKEY      answers for the prompts (unattended install)
#   SN46_SETUP_WALLET_PATH, SN46_SETUP_HOTKEY_PATH, …  where the hotkey is (see the docs)
#   SN46_ROOT=/workspace/sn46              keep everything under one directory (the
#                                          default in a container with a volume)
#   SN46_VERSION=0.4.1                     a specific release instead of the current one
#   SN46_GITHUB_TOKEN=…                    read the releases while the repository is private
#   SN46_STOP_AFTER=host|config|install|model|services   stop early, for a dry run
set -Eeuo pipefail
umask 022

# The releases: index.json and release.pub on the repository's main branch, one GitHub
# release per version (tag v<version>) holding the signed files. SN46_RELEASES points
# the tests at a local copy of the same layout (<base>/index.json, <base>/release.pub,
# <base>/download/v<version>/<file>).
REPO=Subnet46/sn46-miner-releases
INSTALL_URL="https://raw.githubusercontent.com/$REPO/main/install.sh"
if [[ -n "${SN46_RELEASES:-}" ]]; then
  INDEX_URL="$SN46_RELEASES/index.json" KEY_URL="$SN46_RELEASES/release.pub" ASSETS_URL="$SN46_RELEASES/download"
else
  INDEX_URL="https://raw.githubusercontent.com/$REPO/main/index.json"
  KEY_URL="https://raw.githubusercontent.com/$REPO/main/release.pub"
  ASSETS_URL="https://github.com/$REPO/releases/download"
fi
# The release signing key and the digest of the verifier that checks it. A release under
# another key is refused, and the verifier runs only if it is this exact binary. Changing
# either means publishing a new installer. The SN46_TEST_* overrides exist for the
# container tests, which sign with a throwaway key.
RELEASE_PUBLIC_KEY="${SN46_TEST_RELEASE_PUBLIC_KEY:-848b6b3ac0770ca74e1d14106922f0cd4273076a38be582ad6a992d48148a6ff}"
RELEASE_VERIFIER_SHA256="${SN46_TEST_RELEASE_VERIFIER_SHA256:-fc4ce5c6457595daf0813a631d37977e10d1f3f410c15fff37740a182b2ad695}"
MIN_DRIVER=580
# The fewest cards any qualified class uses (B300 runs on two) and the least memory any of
# them has (MiB). An early screen only: the host check matches the exact class and count.
GPUS_NEEDED=2
MIN_GPU_MIB=$((90 * 1024))
# Free space a fresh install needs on the install volume: the 306 GiB checkpoint, the
# release twice while it is staged (2 × 6 GiB), its unpacked runtime (18 GiB) and 20 GiB
# of state and compiled kernels.
FRESH_GIB=360
RELEASE_GIB=50

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then
  c_dim=$'\033[2m' c_bold=$'\033[1m' c_red=$'\033[31m' c_green=$'\033[32m' c_yellow=$'\033[33m' c_off=$'\033[0m'
else
  c_dim="" c_bold="" c_red="" c_green="" c_yellow="" c_off=""
fi
step() { printf '\n%s[%s/7]%s %s%s%s\n' "$c_dim" "$1" "$c_off" "$c_bold" "$2" "$c_off"; }
ok()   { printf '%s✓%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%s! %s%s\n' "$c_yellow" "$*" "$c_off" >&2; }
die()  {
  printf '\n%s✗ %s%s\n' "$c_red" "$*" "$c_off" >&2
  [[ -z "${hint:-}" ]] || printf '  %s\n' "$hint" >&2
  exit 1
}
auth=()
fetch() { curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-all-errors --connect-timeout 15 "${auth[@]}" "$@"; }
# One release file into $2, resumable; $3… are extra curl options (a progress bar).
asset() {
  local name="$1" target="$2" url
  shift 2
  if [[ -n "${SN46_GITHUB_TOKEN:-}" ]]; then
    url="$(awk -v n="$name" '$1 == n { print $2 }' "$work/assets")"
    [[ -n "$url" ]] || return 1
  else
    url="$ASSETS_URL/v$version/$name"
  fi
  curl --proto '=https' --tlsv1.2 -fL --retry 5 --retry-all-errors --connect-timeout 15 "${auth[@]}" \
    -H 'Accept: application/octet-stream' "${@:--sS}" -C - -o "$target" "$url" \
    || { rm -f -- "$target"; fetch -H 'Accept: application/octet-stream' -o "$target" "$url"; }
}

# One function, so that `curl | bash` has read the whole script before any of it runs,
# and nothing it starts can read the rest of the script from stdin.
main() {
step 1 "Check this machine"
[[ "$(id -u)" == 0 ]] || { hint="Run it as root: curl -fsSL … | sudo bash"; die "this installer needs root"; }
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die "Linux on x86_64 is required"
for command in curl python3 sha256sum df; do
  command -v "$command" >/dev/null || { hint="Install it: apt-get install -y $command"; die "missing command: $command"; }
done
[[ -r /etc/os-release ]] || die "cannot identify the operating system (no /etc/os-release)"
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] \
  || { hint="The runtime is built for Ubuntu 24.04; use that image or host."; die "Ubuntu 24.04 is required, this is ${PRETTY_NAME:-unknown}"; }
if [[ -d /run/systemd/system ]]; then
  mode="systemd host"
else
  mode="container"
  # A container keeps only its volume; RunPod mounts it at /workspace.
  if [[ -z "${SN46_ROOT:-}" ]]; then
    for candidate in /workspace /runpod-volume; do
      [[ -d "$candidate" ]] && { export SN46_ROOT="$candidate/sn46"; break; }
    done
    [[ -n "${SN46_ROOT:-}" ]] || warn "no volume found (/workspace): everything goes on the container's own disk and is lost when it is removed. Set SN46_ROOT to a persistent directory to change that."
  fi
fi
root="${SN46_ROOT:-}"
[[ -z "$root" || "$root" == /* ]] || die "SN46_ROOT must be an absolute path"
ok "$PRETTY_NAME, $mode${root:+, installing under $root}"
# The signed manifest records each file's mode, and the release is verified where it is
# installed. Some network volumes (RunPod's in some data centers) ignore chmod.
where="${root:-/opt}"
until [[ -d "$where" ]]; do where="$(dirname "$where")"; done
probe="$(mktemp -p "$where" .sn46-mode.XXXXXX)"
chmod 0640 "$probe"
kept="$(stat -c %a "$probe")"
rm -f -- "$probe"
[[ "$kept" == 640 ]] || {
  hint="Install on a disk that keeps permissions: on RunPod, a container disk of at least 450 GB and SN46_ROOT=/sn46."
  die "$where does not keep file permissions (chmod 640 gave $kept), so the signed release cannot be verified there"; }
# The worker runs as its own user, which must be able to enter every directory above the
# install (root's home, /root, is closed to it).
up="$where"
while [[ "$up" != / ]]; do
  (( 0$(stat -c %a "$up") & 1 )) \
    || { hint="Choose a directory every user can enter, such as SN46_ROOT=/sn46."; die "the worker's user cannot enter $up"; }
  up="$(dirname "$up")"
done

command -v nvidia-smi >/dev/null \
  || { hint="Install the NVIDIA driver ($MIN_DRIVER or newer) first."; die "nvidia-smi not found"; }
driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | awk 'NR == 1')" \
  || { hint="The NVIDIA driver is not working; check \`nvidia-smi\`."; die "nvidia-smi failed"; }
[[ "${driver%%.*}" =~ ^[0-9]+$ ]] || die "could not read the NVIDIA driver version"
cuda_note=""
if (( ${driver%%.*} < MIN_DRIVER )); then
  # Data-center GPUs can run CUDA 13 on an older driver through NVIDIA's forward-compatibility
  # library (RunPod images ship it); what counts is the CUDA version the driver API reports.
  api="$(python3 -c 'import ctypes; c = ctypes.CDLL("libcuda.so.1"); v = ctypes.c_int(); print(v.value if c.cuInit(0) == 0 and c.cuDriverGetVersion(ctypes.byref(v)) == 0 else 0)' 2>/dev/null || echo 0)"
  (( api >= 13000 )) \
    || { hint="Install driver $MIN_DRIVER or newer, or the CUDA 13 forward-compatibility package."; die "NVIDIA driver $driver is too old for CUDA 13"; }
  cuda_note=" (CUDA 13 through forward compatibility)"
fi
gpus="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)"
count="$(grep -c . <<< "$gpus")"
big="$(awk -F', *' -v min="$MIN_GPU_MIB" '$2 + 0 >= min' <<< "$gpus" | grep -c . || true)"
(( big >= GPUS_NEEDED )) \
  || { hint="This release runs on the GPU classes in the README's table."; die "found $count GPU(s), $big with enough memory"; }
ok "driver $driver$cuda_note, $count GPUs:"
sort <<< "$gpus" | uniq -c | sed 's/^ *\([0-9]*\) /    \1 × /'

step 2 "Download the release"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
if [[ -n "${SN46_GITHUB_TOKEN:-}" ]]; then
  # A private repository: the token goes in a header file, never on a command line.
  ( umask 077; printf 'Authorization: token %s\n' "$SN46_GITHUB_TOKEN" > "$work/auth" )
  auth=(-H "@$work/auth")
fi
fetch -o "$work/index.json" "$INDEX_URL" \
  || { hint="Is github.com reachable from this machine?"; die "could not read the release index at $INDEX_URL"; }
version="${SN46_VERSION:-$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$work/index.json")}"
[[ "$version" =~ ^[0-9A-Za-z.+-]{1,64}$ ]] || die "the release index names no valid version"
prefix="$root/opt/sn46-miner"
staging="$prefix/.download/$version"
installed=false
[[ "$(readlink "$prefix/current" 2>/dev/null)" == "releases/$version" ]] && installed=true
# Space for what this run adds: nothing if the release is installed, the release if a
# checkpoint is already there, otherwise both. Checked before anything is downloaded.
volume="${root:-/opt}"
until [[ -d "$volume" ]]; do volume="$(dirname "$volume")"; done
free_gib="$(df -P --block-size=1G "$volume" | awk 'NR == 2 { print $4 }')"
if [[ "$installed" == true ]]; then need_gib=0
elif [[ -n "$(ls -A "$root/opt/models" 2>/dev/null)" ]]; then need_gib=$RELEASE_GIB
else need_gib=$FRESH_GIB; fi
(( free_gib >= need_gib )) \
  || { hint="Free space on $volume, or attach a larger volume and set SN46_ROOT to a directory on it."; die "$free_gib GiB free on $volume; this install needs $need_gib GiB"; }
if [[ "$installed" == true ]]; then
  # Installed already (a re-run, or a pod that restarted): nothing to download.
  release="$prefix/current"
  rm -rf -- "$prefix/.download"
  ok "release $version is installed; checking it"
else
  release="$staging"
  mkdir -p "$release/payload" "$release/parts"
  if [[ -n "${SN46_GITHUB_TOKEN:-}" ]]; then
    fetch -o "$work/release-api.json" "https://api.github.com/repos/$REPO/releases/tags/v$version" \
      || die "no release v$version in $REPO (or the token cannot read it)"
    python3 -c 'import json, sys
for a in json.load(open(sys.argv[1]))["assets"]: print(a["name"], a["url"])' "$work/release-api.json" > "$work/assets"
  fi
  for file in release.json release.sig parts.json; do
    asset "$file" "$release/$file" || die "release $version has no $file"
  done
  # name, mode, sha256 and the parts of every payload file, from the manifest the
  # signature covers; a file over GitHub's 2 GiB limit comes in parts, joined here.
  python3 - "$release/release.json" "$release/parts.json" > "$work/files" <<'PY'
import json, re, sys
files = json.load(open(sys.argv[1]))["files"]
parts = json.load(open(sys.argv[2]))
for name, entry in sorted(files.items()):
    assert re.fullmatch(r"[A-Za-z0-9._-]+", name), name
    pieces = parts.get(name, [name])
    assert all(re.fullmatch(r"[A-Za-z0-9._-]+", p) for p in pieces), pieces
    print(name, entry["mode"], entry["sha256"], *pieces)
PY
  while read -r name mode sha pieces; do
    target="$release/payload/$name"
    if [[ -f "$target" ]] && sha256sum --check --status <<< "$sha  $target"; then continue; fi
    read -r -a pieces <<< "$pieces"
    # A bar for the runtime (about 6 GB); the rest are small.
    show=()
    [[ "$name" != runtime.tar.zst ]] || { printf '  the runtime (about 6 GB)\n'; show=(--progress-bar); }
    if [[ "${#pieces[@]}" == 1 && "${pieces[0]}" == "$name" ]]; then
      asset "$name" "$target" "${show[@]}" || die "download of $name failed; run the installer again to resume"
    else
      for piece in "${pieces[@]}"; do
        asset "$piece" "$release/parts/$piece" "${show[@]}" \
          || die "download of $piece failed; run the installer again to resume"
      done
      for piece in "${pieces[@]}"; do cat -- "$release/parts/$piece"; done > "$target"
    fi
    sha256sum --check --status <<< "$sha  $target" \
      || { rm -f -- "$target" "${pieces[@]/#/$release/parts/}"; die "$name does not match the release manifest; run the installer again"; }
    rm -f -- "${pieces[@]/#/$release/parts/}"
    chmod "$mode" "$target"
  done < "$work/files"
  ok "release $version downloaded ($free_gib GiB were free on $volume)"
fi

step 3 "Verify the release"
verifier="$release/payload/sn46-release-verify"
[[ -f "$verifier" ]] || die "the release holds no verifier"
sha256sum --check --status <<< "$RELEASE_VERIFIER_SHA256  $verifier" \
  || { hint="The release server may be compromised, or this installer is out of date: fetch it again."; die "the release verifier is not the pinned binary"; }
printf '%s\n' "$RELEASE_PUBLIC_KEY" > "$work/release.pub"
if published="$(fetch "$KEY_URL" 2>/dev/null)" && [[ "${published//[[:space:]]/}" != "$RELEASE_PUBLIC_KEY" ]]; then
  hint="Fetch the installer again: curl -fsSL $INSTALL_URL"
  die "the server publishes a different signing key than this installer trusts"
fi
"$verifier" --manifest "$release/release.json" --signature "$release/release.sig" \
  --public-key "$work/release.pub" --payload-root "$release/payload" >/dev/null \
  || die "the release did not verify against the pinned signing key; nothing was installed"
ok "signed by key ${RELEASE_PUBLIC_KEY:0:16}…, every file verified"

# Steps 4-7 are the release's own installer: host check, identity, the release and the
# checkpoint, the service and the wait for the platform.
stop=()
[[ -z "${SN46_STOP_AFTER:-}" ]] || stop=("--stop-after=$SN46_STOP_AFTER")
bash "$release/payload/install.sh" "$release" "$work/release.pub" "$verifier" "${stop[@]}"
[[ -n "${SN46_STOP_AFTER:-}" ]] || rm -rf -- "$prefix/.download"

[[ -n "${SN46_STOP_AFTER:-}" ]] && exit 0
printf '\n%s✓ sn46-miner %s is installed and serving.%s\n\n' "$c_green" "$version" "$c_off"
printf '  sudo sn46-miner status      phase, readiness, requests\n'
printf '  sudo sn46-miner logs -f     follow the log\n'
printf '  sudo sn46-miner doctor      every check, with a fix for each failure\n'
if [[ "$mode" == container ]]; then
  printf '\n  After the pod restarts, run the same install command again: it starts the\n'
  printf '  worker from %s without downloading anything.\n' "${root:-the container disk}"
fi
printf '\n  To update later, run the install command again: it installs a newer release\n'
printf '  and keeps this one for `sudo sn46-miner rollback`.\n'

}

main "$@" < /dev/null
