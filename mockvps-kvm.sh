#!/usr/bin/env bash
#
# mockvps-kvm.sh -- spin up a disposable Debian "VPS" locally with QEMU/KVM
#
# The KVM sibling of mockvps-vbox.sh: same promise, same security posture,
# different hypervisor -- no VirtualBox, no libvirt daemon, just one
# qemu-system-x86_64 process and plain files.
#
#   * Boots an unattended, headless Debian 13 (or current stable) install.
#     The debian-installer is driven by a generated preseed. QEMU boots
#     Debian's official netboot kernel + initrd directly (downloaded over
#     HTTPS and checked against Debian's SHA256SUMS); that initrd carries the
#     NIC and disk drivers, which the smaller netinst-ISO initrd does not.
#     The preseed is appended to a private copy of the initrd as
#     /preseed.cfg (the way virt-install's --initrd-inject works).
#   * virtio disk (guest sees /dev/vda) + virtio NIC of user-mode networking.
#
# Security model (identical to mockvps-vbox):
#   * SSH is reachable from this host only: QEMU forwards a loopback port.
#     (You can bind elsewhere with -k, but you are warned.)
#   * The preseed never travels over a network: it lives only in 0600 files
#     on this host (including the private initrd copy) and is read by the
#     installer as /preseed.cfg.
#   * The guest password is random, stored 0600 in
#     "$WORKDIR/credentials/<name>.env", remembered as root/sudo in the VM.
#     SSH itself is key-only: a dedicated Ed25519 key, password auth off.
#
# Also:
#   * Provisioning: --user-data FILE (cloud-init NoCloud seed, carried in the
#     same private initrd), -P/--package NAME (installed by the installer) and
#     --provision FILE (a bash script streamed over SSH and run as root once
#     the VM is up; re-runnable with --provision-only).
#   * Snapshots: --snapshot / --restore / --snapshots / --delete-snapshot
#     (qcow2 internal snapshots; the VM is powered off for the operation).
#   * The netboot checksum file is authenticated through Debian's GPG-signed
#     InRelease when gpgv + debian-archive-keyring are present.
#
# Usage:  ./mockvps-kvm.sh            # install (5-15 min) and wait for SSH
#         ./mockvps-kvm.sh --help     # all flags
#
# Exit codes: 0 ok; 1 error; 3 VM up but key-only login refused.

set -euo pipefail

# Where the netboot installer (kernel + initrd) comes from. The suite is a
# directory name under dists/ ("stable", "trixie", ...).
DEBIAN_MIRROR_URL="https://deb.debian.org/debian"

QEMU_BIN_DEFAULT="qemu-system-x86_64"

# Characters allowed in the guest password. A strict whitelist lets the
# credentials file be parsed as plain data (never sourced) and keeps the
# preseed / late_command free of anything the installer could misread.
PW_RE='^[A-Za-z0-9._~@+=:,-]+$'

### Helpers ###########################################################

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# is_uint VALUE MIN MAX -- decimal integer in range (leading zeros handled)
is_uint() { [[ "$1" =~ ^[0-9]{1,9}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 )); }

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

confirm() {
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  [[ -t 0 ]] || die "Confirmation needed ('$1') but stdin is not a terminal; re-run with -y."
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[yY]([eE][sS])?$ ]]
}

usage() {
  cat <<'EOF'
usage: mockvps-kvm.sh [options]

Set up a disposable Debian server "VPS" locally with QEMU/KVM: unattended
install (typically 5-15 minutes), key-only SSH reachable from this host
only, no GUI. Afterwards:  ssh <name>

Requires an x86_64 Linux host with KVM support (VT-x/AMD-V and /dev/kvm),
plus wget and cpio. gpgv and debian-archive-keyring (present on Debian/Ubuntu
hosts) let the script verify Debian's signature on the installer checksums.
If qemu-system-x86 is missing, the script offers to install it with apt
(Debian/Ubuntu/derivatives); on other hosts install it yourself first.

options:
  -h, --help            show this help and exit
  -y, --yes             non-interactive; confirms prompts (deleting an
                        existing VM to reinstall, installing QEMU, ...)
  -n, --name NAME       VM name (default: mockvps-kvm)
  -u, --user USER       guest user (default: vps)
  -p, --port PORT       host port for the SSH forward (default: 2232)
  -c, --cpus N          guest vCPUs (default: 2)
  -m, --memory MIB      guest RAM in MiB (default: 2048)
  -d, --disk MB         guest disk size in MB (default: 20000)
  -w, --workdir DIR     state directory (default: ~/vpskvm)
  -s, --suite NAME      Debian release to install (default: stable)
  -f, --forward L:G     also tunnel host port L to guest port G over SSH
                        (repeatable; L must be 1024-65535), e.g. -f 8443:443
  -k, --ip IP           bind the SSH forward to this IPv4 address (default
                        127.0.0.1; only change this if you know why)
  --no-web-tunnel       do not add the default 8080 -> guest:80 tunnel
  --user-data FILE      cloud-init user-data (first line '#cloud-config', or a
                        #! script / MIME multipart; max 256 KiB). Fresh installs
                        only: seeded as the NoCloud datasource, cloud-init is
                        installed, and the script waits for it to finish.
                        Define 'users:' yourself if you do not want cloud-init's
                        default 'debian' user. SSH stays key-only whatever the
                        user-data says (a 00- sshd drop-in wins).
  -P, --package NAME    extra Debian package for the installer to install
                        (repeatable). Fresh installs only.
  --provision FILE      run FILE with bash as root in the guest once SSH is up
                        (repeatable; run in order; stops at the first failure).
                        Runs non-interactively with stdin closed. It runs on
                        every start/install it is passed to, so keep it
                        idempotent.
  --https-mirror        make the installer fetch packages over https (default
                        http; apt verifies package signatures either way)
  --require-signature   refuse to continue unless the netboot checksums can be
                        authenticated through Debian's signed InRelease

management:
  --start               boot the installed VM headless (SSH + tunnels)
  --stop                power the running VM off gracefully (ACPI)
  --status              is the VM running?
  --provision-only      run the --provision files against the already running VM
  --snapshot NAME       save the disk state as snapshot NAME (VM is powered off
                        for this and booted again if it was running)
  --restore NAME        roll the disk back to snapshot NAME (asks first)
  --snapshots           list snapshots
  --delete-snapshot NAME
                        remove snapshot NAME
  --uninstall           remove every trace of the VM: disk, keys,
                        credentials, logs, the ssh config block, host-key
                        entries and the workdir files. The repo itself is
                        kept. (Alias: --remove.)
  --dry-run             only with --uninstall: list what would be removed
  --purge-software      only with --uninstall: ALSO purge the QEMU packages
                        and drop your kvm group membership (uses sudo).
                        QEMU keeps no registry of its other users, so you
                        are the safety rail here: only use this if no other
                        QEMU VMs/scripts use this host.

Every option has an environment-variable equivalent (VM_NAME, VM_USER,
SSH_HOST_PORT, VM_VCPUS, VM_MEMORY, VM_DISK_SIZE_MB, WORKDIR, DEBIAN_SUITE,
SSH_HOST_IP, WEB_TUNNEL=0|1, UNINSTALL=1, DRY_RUN=1,
PURGE_SOFTWARE=1, START=1, STOP=1, STATUS=1,
FORWARDS="8443:443,3000:3000", USER_DATA=FILE, PACKAGES="git,curl",
PROVISION_FILES="a.sh:b.sh", PROVISION_ONLY=1, DEBIAN_MIRROR_PROTO=https,
REQUIRE_SIGNATURE=1); flags win.

The guest password is stored as a plain VM_PASSWORD=value line and must use
only A-Z a-z 0-9 . _ ~ @ + = : , - (VM_PASSWORD from the environment too).

Stall detection: if the installer's console log stops changing, the script
warns after INSTALL_STALL_WARN seconds (default 180) and shows what the
installer is asking; after INSTALL_STALL_ABORT seconds (default 600) it
gives up, stops the VM and removes the half-installed disk.
EOF
}

### Configuration #####################################################

init_defaults() {
  VM_NAME="${VM_NAME:-mockvps-kvm}"
  VM_VCPUS="${VM_VCPUS:-2}"
  VM_MEMORY="${VM_MEMORY:-2048}"            # MiB
  VM_DISK_SIZE_MB="${VM_DISK_SIZE_MB:-20000}"
  VM_USER="${VM_USER:-vps}"
  WORKDIR="${WORKDIR:-$HOME/vpskvm}"
  SSH_HOST_PORT="${SSH_HOST_PORT:-2232}"
  SSH_HOST_IP="${SSH_HOST_IP:-127.0.0.1}"
  DEBIAN_SUITE="${DEBIAN_SUITE:-stable}"
  WEB_TUNNEL="${WEB_TUNNEL:-1}"
  UNINSTALL="${UNINSTALL:-0}"
  DRY_RUN="${DRY_RUN:-0}"
  PURGE_SOFTWARE="${PURGE_SOFTWARE:-0}"
  START="${START:-0}"
  STALL_WARN_SECS="${INSTALL_STALL_WARN:-180}"
  STALL_ABORT_SECS="${INSTALL_STALL_ABORT:-600}"
  STOP="${STOP:-0}"
  STATUS="${STATUS:-0}"
  VWANT_BIN="${MOCKVPS_QEMU:-$QEMU_BIN_DEFAULT}"
  REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
  ASSUME_YES=0
  EXTRA_FORWARDS=()
  FORWARD_LIST=()
  REINSTALL=1
  PRESEED_FILE=""
  USER_DATA_FILE="${USER_DATA:-}"
  DEBIAN_MIRROR_PROTO="${DEBIAN_MIRROR_PROTO:-http}"
  REQUIRE_SIGNATURE="${REQUIRE_SIGNATURE:-0}"
  PROVISION_ONLY="${PROVISION_ONLY:-0}"
  SNAP_ACTION=""
  SNAP_NAME=""
  EXTRA_PACKAGES=()
  PROVISION_LIST=()
  PROV_FILES=()
  PKG_LINE="openssh-server"
  HAVE_PACKAGES=0
  SUMS_EXPECTED=""
}

need_arg() { [[ $2 -ge 2 ]] || die "option $1 requires an argument"; }

set_snap_action() {
  [[ -z "$SNAP_ACTION" ]] || die "only one snapshot action per run (second one: $1)"
  SNAP_ACTION="$2"; SNAP_NAME="${3:-}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      -n|--name) need_arg "$1" $#; VM_NAME="$2"; shift 2 ;;
      -u|--user) need_arg "$1" $#; VM_USER="$2"; shift 2 ;;
      -p|--port) need_arg "$1" $#; SSH_HOST_PORT="$2"; shift 2 ;;
      -c|--cpus) need_arg "$1" $#; VM_VCPUS="$2"; shift 2 ;;
      -m|--memory) need_arg "$1" $#; VM_MEMORY="$2"; shift 2 ;;
      -d|--disk) need_arg "$1" $#; VM_DISK_SIZE_MB="$2"; shift 2 ;;
      -w|--workdir) need_arg "$1" $#; WORKDIR="$2"; shift 2 ;;
      -s|--suite) need_arg "$1" $#; DEBIAN_SUITE="$2"; shift 2 ;;
      -f|--forward) need_arg "$1" $#; EXTRA_FORWARDS+=("$2"); shift 2 ;;
      -k|--ip) need_arg "$1" $#; SSH_HOST_IP="$2"; shift 2 ;;
      --user-data) need_arg "$1" $#; USER_DATA_FILE="$2"; shift 2 ;;
      -P|--package) need_arg "$1" $#; EXTRA_PACKAGES+=("$2"); shift 2 ;;
      --provision) need_arg "$1" $#; PROVISION_LIST+=("$2"); shift 2 ;;
      --provision-only) PROVISION_ONLY=1; shift ;;
      --snapshot) need_arg "$1" $#; set_snap_action "$1" create "$2"; shift 2 ;;
      --restore) need_arg "$1" $#; set_snap_action "$1" restore "$2"; shift 2 ;;
      --delete-snapshot) need_arg "$1" $#; set_snap_action "$1" delete "$2"; shift 2 ;;
      --snapshots) set_snap_action "$1" list; shift ;;
      --https-mirror) DEBIAN_MIRROR_PROTO=https; shift ;;
      --require-signature) REQUIRE_SIGNATURE=1; shift ;;
      --manual) MANUAL=1; shift ;;   # accepted for input compat; see validate
      --no-web-tunnel) WEB_TUNNEL=0; shift ;;
      --uninstall|--remove) UNINSTALL=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --purge-software) PURGE_SOFTWARE=1; shift ;;
      --start) START=1; shift ;;
      --stop) STOP=1; shift ;;
      --status) STATUS=1; shift ;;
      --) shift; break ;;
      -*) die "unknown option: $1 (try --help)" ;;
      *) warn "ignoring unexpected argument: $1"; shift ;;
    esac
  done
}

check_forward() {
  local lp gp
  [[ "$1" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]] \
    || die "invalid forward '$1' (expected LOCALPORT:GUESTPORT, e.g. 8443:443)"
  lp="${BASH_REMATCH[1]}"; gp="${BASH_REMATCH[2]}"   # is_uint clobbers BASH_REMATCH
  is_uint "$lp" 1024 65535 || die "forward '$1': local port must be 1024-65535"
  is_uint "$gp" 1 65535    || die "forward '$1': guest port must be 1-65535"
}

build_forwards() {
  local f lp gp seen=" " envf=()
  FORWARD_LIST=()
  if [[ "$WEB_TUNNEL" != "0" ]]; then FORWARD_LIST+=("8080:80"); fi
  if [[ -n "${FORWARDS:-}" ]]; then
    IFS=',' read -r -a envf <<<"$FORWARDS"
    for f in "${envf[@]}"; do check_forward "$f"; FORWARD_LIST+=("$f"); done
  fi
  for f in ${EXTRA_FORWARDS[@]+"${EXTRA_FORWARDS[@]}"}; do
    check_forward "$f"; FORWARD_LIST+=("$f")
  done
  for f in ${FORWARD_LIST[@]+"${FORWARD_LIST[@]}"}; do
    lp=$((10#${f%%:*})); gp=$((10#${f##*:}))
    [[ "$seen" != *" $lp "* ]] || die "local port $lp is used by more than one forward"
    seen+="$lp "
  done
}

# Extra packages for the installer (d-i pkgsel/include). openssh-server is
# always present; cloud-init is added when --user-data is used.
build_packages() {
  local p envp=() seen=" openssh-server "
  PKG_LINE="openssh-server"
  HAVE_PACKAGES=0
  if [[ -n "${PACKAGES:-}" ]]; then IFS=',' read -r -a envp <<<"$PACKAGES"; fi
  for p in ${envp[@]+"${envp[@]}"} ${EXTRA_PACKAGES[@]+"${EXTRA_PACKAGES[@]}"}; do
    if [[ -z "$p" ]]; then continue; fi
    [[ "$p" =~ ^[a-z0-9][a-z0-9+.-]{1,63}$ ]] \
      || die "invalid package name '$p' (Debian names: lowercase letters, digits, + - .)"
    HAVE_PACKAGES=1
    if [[ "$seen" == *" $p "* ]]; then continue; fi
    seen+="$p "
    PKG_LINE+=" $p"
  done
  if [[ -n "$USER_DATA_FILE" && "$seen" != *" cloud-init "* ]]; then
    PKG_LINE+=" cloud-init"
  fi
}

# cloud-init user-data travels inside the installer initrd (never over a
# network), so keep it small and make sure it is something cloud-init knows.
check_user_data() {
  local first size
  if [[ -z "$USER_DATA_FILE" ]]; then return 0; fi
  [[ -f "$USER_DATA_FILE" && -r "$USER_DATA_FILE" ]] \
    || die "--user-data: '$USER_DATA_FILE' is not a readable file"
  size="$(wc -c < "$USER_DATA_FILE")"; size="${size//[[:space:]]/}"
  (( size > 0 && size <= 262144 )) \
    || die "--user-data: file must be between 1 byte and 256 KiB (it is embedded in the installer initrd)"
  first="$(head -n1 "$USER_DATA_FILE" | tr -d '\r')"
  case "$first" in
    '#cloud-config'*|'#!'*|'Content-Type: multipart/'*|'MIME-Version:'*) ;;
    *) die "--user-data: first line must be '#cloud-config' (or a #! script / MIME multipart); got '${first:0:40}'" ;;
  esac
}

# Provisioning scripts: PROVISION_FILES="a.sh:b.sh" (env) then --provision flags.
build_provision_list() {
  local f envp=() size
  PROV_FILES=()
  if [[ -n "${PROVISION_FILES:-}" ]]; then IFS=':' read -r -a envp <<<"$PROVISION_FILES"; fi
  for f in ${envp[@]+"${envp[@]}"} ${PROVISION_LIST[@]+"${PROVISION_LIST[@]}"}; do
    if [[ -z "$f" ]]; then continue; fi
    [[ -f "$f" && -r "$f" ]] || die "--provision: '$f' is not a readable file"
    size="$(wc -c < "$f")"; size="${size//[[:space:]]/}"
    (( size <= 1048576 )) || die "--provision: '$f' is larger than 1 MiB"
    PROV_FILES+=("$f")
  done
}

check_snapshot_name() {
  if [[ -n "$SNAP_ACTION" && "$SNAP_ACTION" != list ]]; then
    [[ "$SNAP_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] \
      || die "snapshot name must be 1-64 chars [A-Za-z0-9_.-], not starting with - or . (got '$SNAP_NAME')"
  fi
}

validate_config() {
  [[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] \
    || die "VM_NAME must be 1-64 chars [A-Za-z0-9_.-], not starting with - or . (got '$VM_NAME')"
  [[ "$VM_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || die "VM_USER must be a lowercase POSIX user name (got '$VM_USER')"
  is_uint "$SSH_HOST_PORT" 1 65535 || die "SSH_HOST_PORT must be 1-65535 (got '$SSH_HOST_PORT')"
  is_uint "$VM_VCPUS" 1 32         || die "VM_VCPUS must be 1-32 (got '$VM_VCPUS')"
  is_uint "$VM_MEMORY" 512 131072  || die "VM_MEMORY (MiB) must be 512-131072 (got '$VM_MEMORY')"
  is_uint "$VM_DISK_SIZE_MB" 4000 2097152 \
    || die "VM_DISK_SIZE_MB must be 4000-2097152 MiB (got '$VM_DISK_SIZE_MB')"
  [[ "$SSH_HOST_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
    || die "SSH_HOST_IP must be an IPv4 address (got '$SSH_HOST_IP')"
  [[ "$DEBIAN_SUITE" =~ ^[a-z][a-z0-9-]{1,30}$ ]] \
    || die "DEBIAN_SUITE must look like 'stable' or 'trixie' (got '$DEBIAN_SUITE')"
  is_uint "$STALL_WARN_SECS" 30 3600 || die "INSTALL_STALL_WARN must be 30-3600 seconds (got '$STALL_WARN_SECS')"
  is_uint "$STALL_ABORT_SECS" 60 7200 || die "INSTALL_STALL_ABORT must be 60-7200 seconds (got '$STALL_ABORT_SECS')"
  (( 10#$STALL_ABORT_SECS > 10#$STALL_WARN_SECS )) || die "INSTALL_STALL_ABORT must be larger than INSTALL_STALL_WARN"
  [[ "$WORKDIR" != *[[:space:]]* ]] || die "WORKDIR must not contain spaces (got '$WORKDIR')"
  if [[ "${MANUAL:-0}" -eq 1 ]]; then
    die "--manual is not supported by mockvps-kvm: the whole point is the unattended install."
  fi
  [[ "$DEBIAN_MIRROR_PROTO" == http || "$DEBIAN_MIRROR_PROTO" == https ]] \
    || die "DEBIAN_MIRROR_PROTO must be http or https (got '$DEBIAN_MIRROR_PROTO')"
  is_uint "$REQUIRE_SIGNATURE" 0 1 || die "REQUIRE_SIGNATURE must be 0 or 1 (got '$REQUIRE_SIGNATURE')"
  is_uint "$PROVISION_ONLY" 0 1    || die "PROVISION_ONLY must be 0 or 1 (got '$PROVISION_ONLY')"
  REQUIRE_SIGNATURE=$((10#$REQUIRE_SIGNATURE)); PROVISION_ONLY=$((10#$PROVISION_ONLY))
  SSH_HOST_PORT=$((10#$SSH_HOST_PORT))
  build_forwards
  build_packages
  check_user_data
  build_provision_list
  check_snapshot_name
  for f in ${FORWARD_LIST[@]+"${FORWARD_LIST[@]}"}; do
    [[ $((10#${f%%:*})) -ne "$SSH_HOST_PORT" ]] \
      || die "SSH port $SSH_HOST_PORT collides with the forward ${f%%:*}:${f##*:}: pick another -p"
  done
  if [[ "$SSH_HOST_IP" != 127.* ]]; then
    warn "SSH forward bound to $SSH_HOST_IP -- SSH will be reachable from OTHER MACHINES. Use a host firewall."
    confirm "Proceed with a non-loopback bind?" || die "aborted by user"
  fi
}

derive_paths() {
  DISK="$WORKDIR/$VM_NAME.qcow2"
  BOOT_DIR="$WORKDIR/boot"
  RUN_DIR="$WORKDIR/run"
  CRED_DIR="$WORKDIR/credentials"
  CRED_FILE="$CRED_DIR/$VM_NAME.env"
  KEY_FILE="$HOME/.ssh/${VM_NAME}_id"
  INSTALL_LOG="$WORKDIR/${VM_NAME}-install.log"
  RUN_LOG="$WORKDIR/${VM_NAME}-run.log"
  PIDFILE="$RUN_DIR/$VM_NAME.pid"
  MONITOR_SOCK="$RUN_DIR/$VM_NAME.mon.sock"
  PRESEED_FILE="$CRED_DIR/$VM_NAME.preseed"
  SSH_BEGIN="# BEGIN mockvps-kvm:$VM_NAME (managed by mockvps-kvm.sh)"
  SSH_END="# END mockvps-kvm:$VM_NAME"
  GUEST_HOST="$(printf '%s' "$VM_NAME" | LC_ALL=C tr 'A-Z_.' 'a-z--')"
}

### Host system: QEMU + KVM access ####################################

have_apt()  { command -v apt-get >/dev/null 2>&1 && [[ -r /etc/os-release ]]; }
have_qemu() { command -v "$VWANT_BIN" >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; }

install_qemu_apt() {
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    qemu-system-x86 qemu-utils \
    || die "QEMU install failed. Install it yourself:
  sudo apt-get install -y qemu-system-x86 qemu-utils"
}

ensure_qemu() {
  if have_qemu; then
    log "Using $("$VWANT_BIN" --version 2>/dev/null | head -n1 || printf 'unknown version')"
    return 0
  fi
  if ! have_apt; then
    die "qemu-system-x86 / qemu-utils are not installed, and automatic installation
only supports apt-based hosts. Install QEMU with your package manager and re-run."
  fi
  confirm "QEMU is missing. Install qemu-system-x86 + qemu-utils with apt (uses sudo)?" \
    || die "QEMU is required; aborted."
  log "Installing qemu-system-x86 and qemu-utils with apt"
  install_qemu_apt
  have_qemu || die "QEMU was installed but is still not found on PATH; check your PATH and re-run."
  log "Using $("$VWANT_BIN" --version 2>/dev/null | head -n1 || printf 'unknown version')"
}

# /dev/kvm access needs kvm group membership; sg bridges the "just added to
# the group, not yet re-logged-in" window (same pattern as mockvps-vbox).
run_kvm() {
  if [[ $EUID -eq 0 ]] || id -nG | grep -qw kvm; then
    "$@"
  else
    sg kvm -c "$(printf '%q ' "$@")"
  fi
}

ensure_kvm_host() {
  if [[ ! -c /dev/kvm ]]; then
    die "/dev/kvm does not exist. KVM is disabled or its module did not load:
check that VT-x/AMD-V is enabled in the firmware
('grep -E -q \"vmx|svm\" /proc/cpuinfo' should match), then run
'sudo modprobe kvm_intel'  (Intel CPU) or 'sudo modprobe kvm_amd'  (AMD CPU)."
  fi
  if ! id -nG "$REAL_USER" 2>/dev/null | grep -qw kvm; then
    log "Adding $REAL_USER to the kvm group (uses sudo)"
    as_root usermod -aG kvm "$REAL_USER" \
      || die "Could not add $REAL_USER to the kvm group. Do it yourself:
  sudo usermod -aG kvm $REAL_USER   (then log out and back in)"
  fi
  # Verify access through the wrapper (works without re-login thanks to sg).
  run_kvm bash -c 'test -w /dev/kvm' 2>/dev/null \
    || die "/dev/kvm is not writable even through the kvm group. Compare permissions:
  ls -l /dev/kvm; id -nG | tr ' ' '\n' | grep -x kvm"
  log "KVM acceleration available (/dev/kvm writable)"
}

### Credentials, keys, netboot installer ##############################

gen_password() {
  local pw
  while :; do
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 30)" || true
    if [[ ${#pw} -eq 30 ]]; then printf '%s' "$pw"; return 0; fi
  done
}

# Password precedence: env VM_PASSWORD > stored file > new random.
# Stored with %q so odd characters survive being sourced back.
setup_credentials() {
  mkdir -p "$WORKDIR" "$CRED_DIR"
  chmod 700 "$CRED_DIR"
  if [[ -n "${VM_PASSWORD:-}" ]]; then
    log "Using VM_PASSWORD from the environment"
  elif [[ -f "$CRED_FILE" ]]; then
    if VM_PASSWORD="$(read_cred_password "$CRED_FILE")"; then
      log "Reusing the stored password in $CRED_FILE"
    else
      warn "Stored password file is empty or not plain VM_PASSWORD=value data; generating a new password"
      VM_PASSWORD="$(gen_password)"
    fi
  else
    log "Generating a random guest password (stored in $CRED_FILE)"
    VM_PASSWORD="$(gen_password)"
  fi
  [[ "$VM_PASSWORD" =~ $PW_RE ]] \
    || die "VM_PASSWORD may only contain A-Z a-z 0-9 and . _ ~ @ + = : , - (no spaces or shell/preseed metacharacters)"
  ( umask 077; printf 'VM_PASSWORD=%s\n' "$VM_PASSWORD" > "$CRED_FILE" )
  chmod 600 "$CRED_FILE"
}

# Read VM_PASSWORD out of a credentials file WITHOUT sourcing it (sourcing
# would execute whatever the file contains). Accepts only a plain value that
# passes the same whitelist as setup_credentials.
read_cred_password() {
  local line val
  [[ -f "$1" ]] || return 1
  line="$(grep -m1 '^VM_PASSWORD=' "$1" 2>/dev/null)" || return 1
  val="${line#VM_PASSWORD=}"
  [[ "$val" =~ $PW_RE ]] || return 1
  printf '%s' "$val"
}

ensure_host_key() {
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [[ ! -f "$KEY_FILE" ]]; then
    log "Generating dedicated SSH key for $VM_NAME: $KEY_FILE"
    ssh-keygen -q -t ed25519 -N "" -f "$KEY_FILE" -C "$VM_USER@$VM_NAME"
  fi
  chmod 600 "$KEY_FILE"; chmod 644 "$KEY_FILE.pub"
}

sig_unavailable() {
  if [[ $REQUIRE_SIGNATURE -eq 1 ]]; then
    die "A GPG-verified checksum chain is required (--require-signature), but $1."
  fi
  warn "Cannot authenticate the netboot files through Debian's signature: $1.
         Falling back to HTTPS-only trust for kernel + initrd (use --require-signature to refuse this)."
}

# Authenticate the checksum file through Debian's signed InRelease:
#   gpgv(InRelease, debian-archive-keyring) -> SHA256 of SHA256SUMS -> kernel/initrd.
# Sets SUMS_EXPECTED to the signed SHA256 of installer-amd64/current/images/SHA256SUMS,
# or "" when the chain could not be established (see sig_unavailable).
# MOCKVPS_KEYRINGS (space-separated paths) overrides the keyring search; it exists for tests.
verify_release_signature() {
  local dst="$1" inrel rel gh k errf entry="main/installer-amd64/current/images/SHA256SUMS"
  local keyargs=() klist=()
  SUMS_EXPECTED=""
  inrel="$dst/InRelease"; rel="$dst/Release.verified"; errf="$dst/gpgv.err"
  if ! command -v gpgv >/dev/null 2>&1; then
    sig_unavailable "gpgv is not installed (sudo apt-get install gpgv)"; return 0
  fi
  if [[ -n "${MOCKVPS_KEYRINGS:-}" ]]; then
    read -r -a klist <<<"$MOCKVPS_KEYRINGS"
  else
    klist=(/usr/share/keyrings/debian-archive-*.gpg /usr/share/keyrings/debian-archive-*.pgp
           /etc/apt/trusted.gpg.d/debian-archive-*.gpg)
  fi
  for k in ${klist[@]+"${klist[@]}"}; do
    if [[ -r "$k" && "$k" != *removed* ]]; then keyargs+=(--keyring "$k"); fi
  done
  if [[ ${#keyargs[@]} -eq 0 ]]; then
    sig_unavailable "no Debian archive keyring found (sudo apt-get install debian-archive-keyring)"; return 0
  fi
  wget -q -O "$inrel" --timeout=60 "$DEBIAN_MIRROR_URL/dists/$DEBIAN_SUITE/InRelease" \
    || die "Could not download $DEBIAN_MIRROR_URL/dists/$DEBIAN_SUITE/InRelease."
  gh="$(mktemp -d)"; chmod 700 "$gh"
  rm -f -- "$rel"
  if ! gpgv --quiet --homedir "$gh" "${keyargs[@]}" --output "$rel" "$inrel" 2>"$errf"; then
    cat "$errf" >&2; rm -rf "$gh"
    die "The GPG signature on $DEBIAN_SUITE/InRelease did NOT verify. Refusing to continue (tampered mirror or stale keyring?)."
  fi
  rm -rf "$gh"
  SUMS_EXPECTED="$(awk -v p="$entry" '$3 == p && length($1) == 64 { print $1; exit }' "$rel")"
  if [[ -z "$SUMS_EXPECTED" ]]; then
    sig_unavailable "the signed Release file has no SHA256 entry for $entry"
    return 0
  fi
  log "InRelease signature verified (Debian archive keyring)"
}

# Download Debian's netboot installer kernel + initrd for the chosen suite and
# check them against the SHA256SUMS published beside them. When gpgv and the
# Debian archive keyring are available, that SHA256SUMS file is itself
# authenticated against the GPG-signed InRelease; otherwise the protection is
# HTTPS to the mirror (with a warning, or a hard stop under --require-signature).
# Every package the installer then installs is verified by apt as usual.
ensure_netboot() {
  local dst="$BOOT_DIR/$VM_NAME" base sums rel f expected actual
  base="$DEBIAN_MIRROR_URL/dists/$DEBIAN_SUITE/main/installer-amd64/current/images"
  rel="netboot/debian-installer/amd64"
  command -v wget >/dev/null 2>&1 || die "wget is required: sudo apt-get install -y wget"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (coreutils)."
  mkdir -p "$dst"; chmod 700 "$BOOT_DIR" "$dst"
  sums="$dst/SHA256SUMS"
  log "Fetching the $DEBIAN_SUITE netboot installer from $base"
  verify_release_signature "$dst"
  wget -q -O "$sums" --timeout=60 "$base/SHA256SUMS" \
    || die "Could not download $base/SHA256SUMS.
Check your network and the suite name ('$DEBIAN_SUITE'), then re-run."
  if [[ -n "$SUMS_EXPECTED" ]]; then
    actual="$(sha256sum "$sums" | awk '{ print $1 }')"
    [[ "$actual" == "$SUMS_EXPECTED" ]] \
      || die "SHA256SUMS does not match the hash in the GPG-signed Release file (tampered or mid-update mirror); re-run to try again."
    log "SHA256SUMS authenticated through the signed Release file"
  fi
  for f in linux initrd.gz; do
    expected="$(awk -v p="./$rel/$f" '$2 == p { print $1 }' "$sums")"
    [[ -n "$expected" ]] || die "SHA256SUMS has no entry for $rel/$f (suite '$DEBIAN_SUITE')."
    rm -f "$dst/$f.part"
    wget -q -O "$dst/$f.part" --timeout=120 "$base/$rel/$f" \
      || { rm -f "$dst/$f.part"; die "Download of $rel/$f failed."; }
    actual="$(sha256sum "$dst/$f.part" | awk '{ print $1 }')"
    if [[ "$actual" != "$expected" ]]; then
      rm -f "$dst/$f.part"
      die "SHA256 mismatch for $rel/$f (corrupt or tampered download); re-run to try again."
    fi
  done
  mv "$dst/linux.part" "$dst/vmlinuz"
  mv "$dst/initrd.gz.part" "$dst/initrd.gz"
  chmod 600 "$dst/vmlinuz" "$dst/initrd.gz"
  rm -f "$sums" "$dst/InRelease" "$dst/Release.verified" "$dst/gpgv.err"
  log "Netboot kernel + initrd verified (SHA256) in $dst"
}

### Preseed ###########################################################

# Fully self-generated d-i preseed (VirtualBox's template does not exist
# here). The generator enforces the same hard rules mockvps-vbox learned
# the hard way:
#   * late_command is ONE line with NO backslashes (d-i's parser mangles them),
#     and it is syntax-checked with sh -n before embedding,
#   * the authorized_keys chown is numeric (uid 1000), because the installer
#     user does not resolve to a name inside /target,
#   * pkgsel entries sit at top level, never inside an if-block.
# Placeholders are quoted in a 'PSEED' heredoc (nothing expands there) and
# substituted with sed, which is safe because every substituted value is
# validated against a character whitelist (no | % & \ spaces).
build_preseed() {
  local out="$CRED_DIR/$VM_NAME.preseed" pubkey latecmd tmp cicmd value1
  mkdir -p "$CRED_DIR"
  pubkey="$(tr -d '\n' < "$KEY_FILE.pub")"
  case "$pubkey" in (*[![:print:]]*) die "public key contains non-printable characters" ;; esac
  case "$pubkey" in (*[\|%\&\\]*) die "public key contains | % & or backslash" ;; esac

  # cloud-init (only with --user-data): seed the NoCloud datasource from the
  # files carried in the initrd, pin the datasource list, keep the SSH host keys
  # the installer made (so known_hosts stays valid) and leave networking to
  # the installer's ifupdown config instead of letting cloud-init re-render it.
  cicmd=""
  if [[ -n "$USER_DATA_FILE" ]]; then
    cicmd="mkdir -p /target/var/lib/cloud/seed/nocloud /target/etc/cloud/cloud.cfg.d; cp /ci-user-data /target/var/lib/cloud/seed/nocloud/user-data; cp /ci-meta-data /target/var/lib/cloud/seed/nocloud/meta-data; chmod 600 /target/var/lib/cloud/seed/nocloud/user-data; echo 'datasource_list: [ NoCloud, None ]' > /target/etc/cloud/cloud.cfg.d/90-mockvps.cfg; echo 'ssh_deletekeys: false' >> /target/etc/cloud/cloud.cfg.d/90-mockvps.cfg; echo 'network: {config: disabled}' >> /target/etc/cloud/cloud.cfg.d/90-mockvps.cfg; "
  fi

  latecmd="mkdir -p /target/home/${VM_USER}/.ssh; echo '${pubkey}' > /target/home/${VM_USER}/.ssh/authorized_keys; chown -R 1000:1000 /target/home/${VM_USER}/.ssh; chmod 700 /target/home/${VM_USER}/.ssh; chmod 600 /target/home/${VM_USER}/.ssh/authorized_keys; mkdir -p /target/etc/ssh/sshd_config.d; echo 'PasswordAuthentication no' > /target/etc/ssh/sshd_config.d/00-mockvps-hardening.conf; echo 'PubkeyAuthentication yes' >> /target/etc/ssh/sshd_config.d/00-mockvps-hardening.conf; grep -q '^Include' /target/etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /target/etc/ssh/sshd_config; ${cicmd}sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"console=tty0 console=ttyS0,115200n8\"/' /target/etc/default/grub; ln -sf /lib/systemd/system/serial-getty@.service /target/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service; chroot /target update-grub || true; true"

  [[ "$latecmd" != *\\* ]] || die "late_command contains backslashes"
  # '|', '&' and '%' are legitimate shell syntax in late_command (e.g. '||').
  # Placeholders are filled by a pure-bash loop below (no sed), so none of
  # them needs to be excluded; only backslashes and newlines stay forbidden.
  printf '%s' "$latecmd" | sh -n || die "late_command fails sh -n parse check"
  [[ "$latecmd" == *$'\n'* ]] && die "late_command must be a single line"

  tmp="$CRED_DIR/.$VM_NAME.preseed.part"
  {
    cat <<'PSEED'
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i console-setup/ask_detect boolean false
d-i netcfg/enable boolean true
d-i netcfg/disable_autoconfig boolean false
d-i netcfg/choose_interface select auto
d-i mirror/country string manual
d-i mirror/protocol string %MIRROR_PROTO%
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i mirror/https/hostname string deb.debian.org
d-i mirror/https/directory string /debian
d-i mirror/https/proxy string
d-i apt-setup/cdrom/set-first boolean false
d-i apt-setup/cdrom/set-next boolean false
d-i apt-setup/cdrom/set-failed boolean false
d-i popularity-contest/participate boolean false
d-i netcfg/get_hostname string %VM_HOST%
d-i netcfg/get_domain string localdomain
d-i hw-detect/load_firmware boolean false
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i pkgsel/include string %PKGS%
d-i pkgsel/upgrade select none
d-i pkgsel/install-language-support boolean false
d-i pkgsel/update-policy select none
tasksel tasksel/first multiselect standard
d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string lvm
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/device_remove_lvm_span boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-auto/choose_recipe select atomic
d-i partman/confirm_write_new_label boolean true
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/choose_partition select finish
d-i partman-auto-lvm/guided_size string max
d-i partman-partitioning/confirm_write_new_label boolean true
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/user-fullname string %VM_USER%
d-i passwd/username string %VM_USER%
d-i passwd/user-password password %VM_PASSWORD%
d-i passwd/user-password-again password %VM_PASSWORD%
d-i user-setup/encrypt-password boolean false
d-i user-setup/allow-password-weak boolean true
d-i passwd/user-default-groups string sudo
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string /dev/vda
d-i grub-installer/with_other_os boolean false
d-i finish-install/reboot_in_progress note
d-i preseed/late_command string %LATECMD%
PSEED
  } | {
    # Literal placeholder substitution in pure bash: sed would treat '&' and
    # the delimiter in the replacement specially. bash 5.2's patsub_replacement
    # makes '&' special too, so switch it off where it exists.
    shopt -u patsub_replacement 2>/dev/null || true
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line//%VM_HOST%/$GUEST_HOST}"
      line="${line//%VM_USER%/$VM_USER}"
      line="${line//%VM_PASSWORD%/$VM_PASSWORD}"
      line="${line//%PKGS%/$PKG_LINE}"
      line="${line//%MIRROR_PROTO%/$DEBIAN_MIRROR_PROTO}"
      line="${line//%LATECMD%/$latecmd}"
      printf '%s\n' "$line"
    done
  } > "$tmp"
  mv "$tmp" "$out"; chmod 600 "$out"

  # --- post-generation guards (the vbox lessons, asserted) ---
  [[ "$(grep -c '^d-i preseed/late_command string ' "$out")" -eq 1 ]] \
    || die "expected exactly one preseed/late_command line"
  grep -qxF "d-i pkgsel/include string $PKG_LINE" "$out" \
    || die "pkgsel/include line missing from preseed"
  if [[ -n "$USER_DATA_FILE" ]]; then
    grep -qF 'cp /ci-user-data' "$out" || die "cloud-init seed step missing from latecmd"
  fi
  grep -qF 'chown -R 1000:1000' "$out" || die "numeric chown missing from latecmd"
  grep -qF 'sshd_config.d/00-mockvps-hardening.conf' "$out" \
    || die "sshd hardening drop-in missing from latecmd"
  grep -qF "$pubkey" "$out" || die "public key not embedded in preseed"
  grep -qF 'console=ttyS0,115200n8' "$out" || die "serial console setup missing from latecmd"
  # No d-i question ever named /target/home/... with a slash in the query part:
  awk '/^d-i preseed\/late_command/ && found++ { exit 1 }' "$out" \
    || die "multiple late_command entries (post-embed check)"
  value1="$(grep '^d-i preseed/late_command string ' "$out")"
  value1="${value1#d-i preseed/late_command string }"
  [[ "$value1" == "$latecmd" ]] || die "late_command changed during placeholder substitution"
  PRESEED_FILE="$out"
  log "Preseed written: $PRESEED_FILE (0600; contains the guest password)"
}

# Append the preseed to a private copy of the installer initrd. The kernel
# unpacks concatenated gzip'd cpio archives in order, so the result carries
# /preseed.cfg and d-i finds it with file=/preseed.cfg on the command line.
# This keeps the preseed off every network and available from the very first
# installer step.
build_initrd() {
  local dst="$BOOT_DIR/$VM_NAME" stage files=(preseed.cfg)
  command -v cpio >/dev/null 2>&1 \
    || die "cpio is required to inject the preseed into the installer initrd:
  sudo apt-get install -y cpio"
  command -v gzip >/dev/null 2>&1 || die "gzip is required."
  stage="$(mktemp -d)"; chmod 700 "$stage"
  cp "$PRESEED_FILE" "$stage/preseed.cfg"
  if [[ -n "$USER_DATA_FILE" ]]; then
    # NoCloud seed files; the preseed's late_command copies them into the
    # new system as /var/lib/cloud/seed/nocloud/{user-data,meta-data}.
    cp -- "$USER_DATA_FILE" "$stage/ci-user-data"
    printf 'instance-id: mockvps-%s-%s\nlocal-hostname: %s\n' \
      "$GUEST_HOST" "$(date +%s)" "$GUEST_HOST" > "$stage/ci-meta-data"
    files+=(ci-user-data ci-meta-data)
  fi
  chmod 600 "$stage"/*
  if ! ( umask 077; cd -- "$stage" \
         && printf '%s\n' "${files[@]}" | cpio --quiet -o -H newc | gzip -9 > "$stage/preseed.cpio.gz" ); then
    rm -rf "$stage"; die "Could not build the preseed cpio archive."
  fi
  ( umask 077; cat "$dst/initrd.gz" "$stage/preseed.cpio.gz" > "$dst/initrd-preseed.gz" ) \
    || { rm -rf "$stage"; die "Could not write $dst/initrd-preseed.gz"; }
  rm -rf "$stage"
  chmod 600 "$dst/initrd-preseed.gz"
  log "Preseed${USER_DATA_FILE:+ and cloud-init user-data} injected into the installer initrd: $dst/initrd-preseed.gz"
}

### QEMU plumbing #####################################################

# Compose the QEMU command line as an array QQA. Takes the serial-log
# destination as an argument; does not run anything, so die() still aborts.
define_cmd() {
  local phase="$1" log="$2" f iface
  QQA=("$VWANT_BIN")
  QQA+=(-enable-kvm -cpu host)
  QQA+=(-smp "$VM_VCPUS" -m "$VM_MEMORY")
  QQA+=(-name "mockvps-$VM_NAME")
  QQA+=(-drive "file=$DISK,format=qcow2,if=virtio")
  if [[ $phase == install ]]; then
    # Install phase: no host-forward (nothing should reach in while the
    # installer runs); the guest only needs DHCP and internet for packages.
    iface="user,model=virtio-net-pci"
    QQA+=(-nic "$iface")
    QQA+=(-kernel "$BOOT_DIR/$VM_NAME/vmlinuz")
    QQA+=(-initrd "$BOOT_DIR/$VM_NAME/initrd-preseed.gz")
    QQA+=(-append "auto=true priority=critical console=ttyS0,115200n8 file=/preseed.cfg")
    QQA+=(-no-reboot)      # d-i's final reboot exits QEMU -> run phase follows
  else
    iface="user,model=virtio-net-pci"
    # Only SSH is exposed by QEMU. The web/other tunnels (-f, 8080->80) are
    # SSH LocalForwards written to the ssh config block, so they exist only
    # while an 'ssh <name>' session is open (and never clash with QEMU).
    iface+=",hostfwd=tcp:$SSH_HOST_IP:$SSH_HOST_PORT-:22"
    QQA+=(-nic "$iface")
  fi
  QQA+=(-boot order=c)
  QQA+=(-object rng-random,id=rng0)
  QQA+=(-device virtio-rng-pci,rng=rng0)
  QQA+=(-display none)
  QQA+=(-serial "file:$log")
  QQA+=(-monitor "unix:$MONITOR_SOCK,server,nowait")
  QQA+=(-pidfile "$PIDFILE")
}

port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{ print $4 }' | grep -qE "[.:]$1\$"
  else
    warn "Neither ss nor netstat is available; cannot check whether port $1 is free."
    return 1
  fi
}

check_port_free() {
  if port_in_use "$SSH_HOST_PORT"; then
    die "Host port $SSH_HOST_PORT is already in use (checked with a plain TCP bind probe). Pick another with -p/--port."
  fi
}

process_is_qemu() {
  local pid="$1" c
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -r "/proc/$pid/comm" ]] || return 1
  c="$(cat "/proc/$pid/comm" 2>/dev/null)"
  [[ "$c" == qemu-system-x86* ]] || [[ "$c" == qemu-system-x86_64 ]] && return 0
  # Fallback: argv0 (containers firejail namespacing may rename comm)
  c="$(head -c 200 "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | awk '{ print $1 }')" || c=""
  [[ "${c##*/}" == qemu-system-x86* ]]
}

qemu_running() {
  local pid
  [[ -s "$PIDFILE" ]] || return 1
  pid="$(head -n1 "$PIDFILE" 2>/dev/null)"
  process_is_qemu "$pid"
}

clear_stale_pidfile() {
  if [[ -s "$PIDFILE" ]] && ! qemu_running; then
    rm -f -- "$PIDFILE" "$MONITOR_SOCK"
  fi
}

# Start the VM (phase 'install' or 'run'). QEMU writes its own pidfile
# (-pidfile), which is what --stop/--status management uses.
start_phase() {
  local phase="$1" log="$2" attempt startmsg
  clear_stale_pidfile
  rm -f -- "$MONITOR_SOCK"
  define_cmd "$phase" "$log"
  mkdir -p "$RUN_DIR"
  if [[ $phase == install ]]; then
    startmsg="Starting the unattended installer console (serial log: $log)"
  else
    startmsg="Booting the VM headless (serial log: $log)"
  fi
  log "$startmsg"
  # Note: with 'sg kvm -c' the QEMU command line is visible in 'ps'. It holds
  # no secrets (password and keys live only in the initrd / 0600 files); keep
  # it that way when adding options.
  run_kvm "${QQA[@]}" >>"$log" 2>&1 &
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if [[ -s "$PIDFILE" ]] && qemu_running; then
      log "QEMU is up (pid $(cat "$PIDFILE"))"
      return 0
    fi
    sleep 0.3
  done
  die "QEMU exited immediately during the '$phase' phase. See $log.
If the disk is locked by another QEMU, stop that one first ('--stop')."
}

# Turn the installer's text-mode screen (serial log, full of cursor-movement
# escape codes) into a few readable lines: the last dialog it drew.
installer_screen_text() {
  [[ -s "$1" ]] || return 0
  # POSIX tools only: split the stream at every ESC byte, strip the CSI/charset
  # sequence left at the start of each piece, then drop all non-ASCII (box
  # drawing characters) so no locale or GNU sed extension is needed.
  tail -c 12000 "$1" 2>/dev/null \
    | tr -d '\r' \
    | tr '\033' '\n' \
    | sed -E 's#^(\[[0-9;?]*[ -/]*[@-~]|[()][A-Z0-9]|[=>])##' \
    | LC_ALL=C tr -cd '\n\040-\176' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | awk 'NF' \
    | tail -n 18
}

report_stall() {
  local idle="$1" screen title
  screen="$(installer_screen_text "$INSTALL_LOG")" || screen=""
  title="$(grep -E '\[!+\]' <<<"$screen" | tail -n1 || true)"
  warn "No installer output for $((idle / 60)) min $((idle % 60)) s."
  printf '  The installer is probably waiting on a question the preseed does not answer.\n' >&2
  if [[ -n "$title" ]]; then printf '  Last dialog: %s\n' "$title" >&2; fi
  if [[ -n "$screen" ]]; then
    printf '  ---- last text on the installer screen ----\n' >&2
    sed 's/^/  | /' <<<"$screen" >&2
    printf '  --------------------------------------------\n' >&2
  fi
}

wait_qemu_exit() {
  local i=0 size last_size=-1 idle=0 warned=0 pid
  log "Waiting for the installer to finish (serial log: $INSTALL_LOG; up to 30 min)"
  while (( i < 300 )); do
    if ! qemu_running; then
      rm -f -- "$PIDFILE" "$MONITOR_SOCK"
      return 0
    fi
    size="$(stat -c %s "$INSTALL_LOG" 2>/dev/null || echo 0)"
    if [[ "$size" == "$last_size" ]]; then
      idle=$((idle + 10))
    else
      idle=0; warned=0; last_size="$size"
    fi
    if (( idle >= 10#$STALL_ABORT_SECS )); then
      report_stall "$idle"
      pid="$(head -n1 "$PIDFILE" 2>/dev/null || true)"
      [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
      sleep 2
      die "The installer made no progress for $((idle / 60)) minutes and was stopped.
Add the missing answer to the preseed in build_preseed() and re-run.
Full console log: $INSTALL_LOG"
    elif (( idle >= 10#$STALL_WARN_SECS && warned == 0 )); then
      report_stall "$idle"
      printf '  Still waiting; the VM will be stopped after %s s of silence in total.\n' "$STALL_ABORT_SECS" >&2
      warned=1
    fi
    i=$((i + 1))
    if (( i % 6 == 0 )); then
      log "Still installing (elapsed ~$((i * 10 / 60)) min)"
    fi
    sleep 10
  done
  die "The installer did not return within 30 minutes. Inspect $INSTALL_LOG;
kill the VM with '--stop' and re-run."
}

stop_vm() {
  local pid i
  if ! qemu_running; then
    log "VM '$VM_NAME' is not running."
    rm -f -- "$PIDFILE" "$MONITOR_SOCK"
    return 0
  fi
  pid="$(head -n1 "$PIDFILE")"
  log "Powering off '$VM_NAME' gracefully (ACPI)"
  mkdir -p "$RUN_DIR"
  local sent=0
  if command -v socat >/dev/null 2>&1; then
    printf 'system_powerdown\n' | socat - "unix-connect:$MONITOR_SOCK" 2>/dev/null && sent=1
  elif command -v nc >/dev/null 2>&1; then
    printf 'system_powerdown\n' | nc -U "$MONITOR_SOCK" 2>/dev/null && sent=1
  fi
  if [[ $sent -eq 0 ]]; then
    warn "Neither socat nor nc could reach the monitor socket; will use SIGTERM if ACPI times out."
  fi
  for i in $(seq 1 15); do
    if ! qemu_running; then break; fi
    sleep 2
  done
  if qemu_running; then
    warn "ACPI powerdown did not complete within 30s; falling back to SIGTERM (potentially slower qcow2 cleanup on next boot, but safe)."
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 10); do
      if ! qemu_running; then break; fi
      sleep 1
    done
  fi
  if qemu_running; then
    die "QEMU for '$VM_NAME' is still alive. Investigate manually:
  ps aux | grep -F '$VWANT_BIN' ; kill -9 <pid>"
  fi
  rm -f -- "$PIDFILE" "$MONITOR_SOCK"
  log "Stopped."
}

status_vm() {
  if qemu_running; then
    log "Running (pid $(head -n1 "$PIDFILE")) -- ssh $SSH_HOST_IP:$SSH_HOST_PORT"
  else
    log "Not running."
    rm -f "$PIDFILE" 2>/dev/null || true
  fi
}

is_vm_installed() { [[ -f "$DISK" && -s "$DISK" ]]; }

# The guest disk must exist before QEMU starts (QEMU does not create it).
create_disk() {
  rm -f -- "$DISK"
  log "Creating a ${VM_DISK_SIZE_MB} MiB qcow2 disk: $DISK"
  qemu-img create -q -f qcow2 "$DISK" "${VM_DISK_SIZE_MB}M" \
    || die "qemu-img could not create $DISK"
  chmod 600 "$DISK"
}

# EXIT trap during install: drop the disk if the
# install did not complete so a failed run is not mistaken for an installed VM.
cleanup_install() {
  if [[ "${INSTALL_DONE:-0}" -ne 1 ]]; then
    rm -f -- "$DISK"
  fi
}

### SSH config ########################################################

write_ssh_block() {
  local cfg="$HOME/.ssh/config" blockfile out f
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  touch "$cfg"; chmod 600 "$cfg"
  if grep -qxF "$SSH_BEGIN" "$cfg" && ! grep -qxF "$SSH_END" "$cfg"; then
    die "$cfg has a '$SSH_BEGIN' line but no matching END line; fix it by hand and re-run."
  fi
  cp -p "$cfg" "$cfg.mockvps-kvm.bak"

  blockfile="$(mktemp)"; out="$(mktemp)"
  chmod 600 "$blockfile" "$out"
  {
    echo "$SSH_BEGIN"
    echo "Host $VM_NAME"
    echo "  HostName $SSH_HOST_IP"
    echo "  Port $SSH_HOST_PORT"
    echo "  User $VM_USER"
    echo "  IdentityFile $KEY_FILE"
    echo "  IdentitiesOnly yes"
    echo "  HostKeyAlias $VM_NAME"
    echo "  StrictHostKeyChecking accept-new"
    for f in ${FORWARD_LIST[@]+"${FORWARD_LIST[@]}"}; do
      echo "  LocalForward ${f%%:*} localhost:${f##*:}"
    done
    echo "$SSH_END"
  } > "$blockfile"

  awk -v bf="$blockfile" -v begin="$SSH_BEGIN" -v end="$SSH_END" '
    $0 == begin  { while ((getline l < bf) > 0) print l; close(bf); placed = 1; skip = 1; next }
    skip         { if ($0 == end) skip = 0; next }
    skip == 1    { next }
    { print }
    END { if (!placed) { if (NR > 0) print ""; while ((getline l < bf) > 0) print l } }
  ' "$cfg" > "$out" || { rm -f "$blockfile" "$out"; die "ssh config block replacement failed"; }
  cat "$out" > "$cfg"     # keep the inode, so a symlinked config still works
  rm -f "$blockfile" "$out"
  log "ssh config block for '$VM_NAME' written to $cfg (backup: $cfg.mockvps-kvm.bak)"
}

remove_ssh_block() {
  local cfg="$HOME/.ssh/config" out
  [[ -f "$cfg" ]] || return 0
  cp -p "$cfg" "$cfg.mockvps-kvm.bak"
  out="$(mktemp)"; chmod 600 "$out"
  awk -v begin="$SSH_BEGIN" -v end="$SSH_END" '
    $0 == begin   { skip = 1; next }
    skip == 1     { if ($0 == end) skip = 0; next }
    { print }
  ' "$cfg" > "$out"
  cat "$out" > "$cfg"
  rm -f "$out"; chmod 600 "$cfg"
}

forget_old_host_keys() {
  local kh="$HOME/.ssh/known_hosts"
  [[ -f "$kh" ]] || return 0
  ssh-keygen -R "$VM_NAME" -f "$kh" >/dev/null 2>&1 || true
  ssh-keygen -R "[$SSH_HOST_IP]:$SSH_HOST_PORT" -f "$kh" >/dev/null 2>&1 || true
}

ssh_banner_ready() {
  timeout 5 bash -c 'exec 3<>"$1" 2>/dev/null; read -t 3 -r line <&3; [[ $line == SSH-* ]]' _ "/dev/tcp/$SSH_HOST_IP/$SSH_HOST_PORT" 2>/dev/null
}

probe_key_login() {
  ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o HostKeyAlias="$VM_NAME" \
      -o IdentitiesOnly=yes -i "$KEY_FILE" \
      -p "$SSH_HOST_PORT" "$VM_USER@$SSH_HOST_IP" true 2>/dev/null
}

wait_for_ssh_key_login() {
  local i
  log "Waiting for SSH on $SSH_HOST_IP:$SSH_HOST_PORT"
  for i in $(seq 1 180); do
    if ssh_banner_ready; then break; fi
    sleep 10
  done
  if ! ssh_banner_ready; then
    die "SSH never came up on $SSH_HOST_IP:$SSH_HOST_PORT (30 min). Inspect $RUN_LOG;"
  fi
  log "SSH is up; checking the key-only login"
  for i in 1 2 3 4 5 6; do
    if probe_key_login; then
      log "Key-based SSH works; password authentication is disabled in the guest."
      return 0
    fi
    sleep 5
  done
  printf 'ERROR: SSH answers, but the key-only login was refused.\n' >&2
  printf '  Log in once with the stored password (see %s) and add\n' "$CRED_FILE" >&2
  printf '  %s.pub to the guest'"'"'s ~/.ssh/authorized_keys.\n' "$KEY_FILE" >&2
  exit 3
}

### Guest access: cloud-init wait + SSH provisioner ##################

# Non-interactive key-only ssh into the guest (independent of ~/.ssh/config).
guest_ssh() {
  ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new -o HostKeyAlias="$VM_NAME" \
      -o IdentitiesOnly=yes -o ServerAliveInterval=30 -o LogLevel=ERROR \
      -i "$KEY_FILE" -p "$SSH_HOST_PORT" "$VM_USER@$SSH_HOST_IP" "$@"
}

# Only after a fresh install with --user-data: cloud-init runs on that first
# boot, and SSH comes up before its runcmd/packages are done.
wait_cloud_init() {
  if [[ -z "$USER_DATA_FILE" ]]; then return 0; fi
  log "Waiting for cloud-init to finish in the guest (up to 15 min)"
  if guest_ssh 'timeout 900 cloud-init status --wait --long'; then
    log "cloud-init finished"
  else
    warn "cloud-init did not finish cleanly. Inspect with:
  ssh $VM_NAME 'cloud-init status --long; sudo tail -n 60 /var/log/cloud-init-output.log'"
  fi
}

# Run every --provision file in the guest, as root, in order. The script is
# streamed over SSH after the sudo password (read by 'sudo -S' from stdin, so
# it never appears in any process list), stored in a 0600 temp file, and run
# non-interactively with stdin closed. A failing script stops the run.
run_provisioners() {
  local f n=0 total=${#PROV_FILES[@]} remote
  if (( total == 0 )); then return 0; fi
  if [[ -z "${VM_PASSWORD:-}" ]]; then
    VM_PASSWORD="$(read_cred_password "$CRED_FILE")" \
      || die "Cannot read the guest sudo password from $CRED_FILE (needed to run provisioning scripts as root).
Set VM_PASSWORD in the environment, or reinstall."
  fi
  remote="$(cat <<'EOS'
sudo -S -p '' bash -c 'f=$(mktemp /tmp/mockvps-prov.XXXXXX) || exit 1; cat > "$f"; DEBIAN_FRONTEND=noninteractive bash "$f" </dev/null; rc=$?; rm -f "$f"; exit $rc'
EOS
)"
  for f in "${PROV_FILES[@]}"; do
    n=$((n + 1))
    log "Provisioning ($n/$total): running $f in the guest as root"
    if ! { printf '%s\n' "$VM_PASSWORD"; cat -- "$f"; } | guest_ssh "$remote"; then
      die "Provisioning script '$f' failed (output above). The VM is left running;
fix the script and re-run with:  --provision-only --provision '$f'"
    fi
  done
  log "Provisioning finished ($total script(s))"
}

provision_only_run() {
  (( ${#PROV_FILES[@]} > 0 )) \
    || die "--provision-only needs at least one --provision FILE (or PROVISION_FILES=a.sh:b.sh)"
  qemu_running || die "'$VM_NAME' is not running; boot it with --start first."
  probe_key_login || die "Key-only SSH login to '$VM_NAME' failed; see 'ssh $VM_NAME'."
  run_provisioners
}

### Snapshots (qcow2 internal snapshots; VM must be off) ##############

snapshot_exists() {
  qemu-img snapshot -U -l "$DISK" 2>/dev/null \
    | awk -v n="$1" '$1 ~ /^[0-9]+$/ && $2 == n { f = 1 } END { exit !f }'
}

# Run "$@" with the VM powered off (qemu-img needs the disk lock); boot it
# again afterwards if it was running before.
with_vm_stopped() {
  local was_running=0 rc=0
  if qemu_running; then
    confirm "'$VM_NAME' is running. Power it off for this operation and boot it again afterwards?" \
      || die "Aborted; nothing changed."
    stop_vm
    was_running=1
  fi
  "$@" || rc=$?
  if [[ $was_running -eq 1 ]]; then
    log "Booting '$VM_NAME' again"
    check_port_free
    start_phase run "$RUN_LOG"
    wait_for_ssh_key_login
  fi
  return "$rc"
}

do_snapshot_create() {
  log "Creating snapshot '$SNAP_NAME' of $DISK"
  qemu-img snapshot -c "$SNAP_NAME" "$DISK" || die "qemu-img could not create the snapshot."
  log "Snapshot '$SNAP_NAME' created. Roll back with: ${0##*/} --restore $SNAP_NAME"
}

do_snapshot_restore() {
  log "Rolling '$VM_NAME' back to snapshot '$SNAP_NAME'"
  qemu-img snapshot -a "$SNAP_NAME" "$DISK" || die "qemu-img could not apply the snapshot."
  log "Restored. The snapshot is kept; it can be restored again."
}

do_snapshot_delete() {
  log "Deleting snapshot '$SNAP_NAME'"
  qemu-img snapshot -d "$SNAP_NAME" "$DISK" || die "qemu-img could not delete the snapshot."
  log "Snapshot '$SNAP_NAME' deleted (the disk file may stay large; qcow2 reuses the space)."
}

snapshot_run() {
  local out
  command -v qemu-img >/dev/null 2>&1 || die "qemu-img is not installed (sudo apt-get install -y qemu-utils)."
  is_vm_installed || die "No installed VM disk at $DISK."
  case "$SNAP_ACTION" in
    list)
      out="$(qemu-img snapshot -U -l "$DISK" 2>&1)" || die "qemu-img could not list snapshots: $out"
      log "Snapshots of '$VM_NAME'"
      if [[ -n "$out" ]]; then printf '%s\n' "$out"; else echo "  (none)"; fi
      ;;
    create)
      if snapshot_exists "$SNAP_NAME"; then
        die "A snapshot named '$SNAP_NAME' already exists (remove it with --delete-snapshot $SNAP_NAME)."
      fi
      with_vm_stopped do_snapshot_create
      ;;
    restore)
      snapshot_exists "$SNAP_NAME" || die "No snapshot named '$SNAP_NAME' (see --snapshots)."
      confirm "Roll '$VM_NAME' back to '$SNAP_NAME'? Everything written to its disk since then is lost." \
        || die "Aborted; nothing changed."
      with_vm_stopped do_snapshot_restore
      ;;
    delete)
      snapshot_exists "$SNAP_NAME" || die "No snapshot named '$SNAP_NAME' (see --snapshots)."
      with_vm_stopped do_snapshot_delete
      ;;
    *) die "internal error: unknown snapshot action '$SNAP_ACTION'" ;;
  esac
}

### Uninstall #########################################################

# Lists only the artifacts that currently exist (or are explicitly kept).
uninstall_items() {
  if [[ $PURGE_SOFTWARE -eq 1 ]]; then
    local vp
    vp="$(dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /^qemu-(system|utils)/ { print $2 }')"
    if [[ -n "$vp" ]]; then echo "software   QEMU packages: ${vp//$'\n'/, }"; fi
    if id -nG "$REAL_USER" 2>/dev/null | grep -qw kvm; then
      echo "software   kvm group membership for $REAL_USER"
    fi
  else
    echo "keep       QEMU software and your kvm group membership (add --purge-software to remove)"
  fi
  if [[ -e "$DISK" ]]; then echo "file       $DISK (guest disk)"; fi
  if [[ -d "$BOOT_DIR/$VM_NAME" ]]; then echo "dir        $BOOT_DIR/$VM_NAME (extracted installer kernel/initrd)"; fi
  if [[ -f "$CRED_FILE" ]]; then echo "file       $CRED_FILE (guest sudo password)"; fi
  if [[ -f "$PRESEED_FILE" ]]; then echo "file       $PRESEED_FILE (preseed copy)"; fi
  local f
  for f in "$WORKDIR"/debian-*-amd64-netinst.iso "$WORKDIR"/debian-*-amd64-netinst.iso.part; do
    if [[ -e "$f" ]]; then echo "file       $f (install ISO left by an older version of this script)"; fi
  done
  if [[ -d "$WORKDIR/verify" ]]; then echo "dir        $WORKDIR/verify (checksum files left by an older version)"; fi
  if [[ -f "$INSTALL_LOG" ]]; then echo "file       $INSTALL_LOG (install serial console)"; fi
  if [[ -f "$RUN_LOG" ]]; then echo "file       $RUN_LOG (run serial console)"; fi
  if [[ -e "$PIDFILE" ]]; then echo "file       $PIDFILE (+ monitor socket $MONITOR_SOCK)"; fi
  if [[ -f "$KEY_FILE" ]]; then echo "file       $KEY_FILE (dedicated ssh key)"; fi
  if [[ -f "$KEY_FILE.pub" ]]; then echo "file       $KEY_FILE.pub"; fi
  local cfg="$HOME/.ssh/config"
  if [[ -f "$cfg" ]]; then
    if grep -qxF "$SSH_BEGIN" "$cfg" && ! grep -qxF "$SSH_END" "$cfg"; then
      die "$cfg has a '$SSH_BEGIN' line but no matching END line; fix it by hand and re-run."
    fi
    if grep -qxF "$SSH_BEGIN" "$cfg"; then
      echo "ssh-block  $cfg (managed block for '$VM_NAME')"
    fi
  fi
  local kh="$HOME/.ssh/known_hosts"
  if [[ -f "$kh" ]] && grep -qE "(^|[[:space:]])$VM_NAME([[:space:]]|\$)|\[$SSH_HOST_IP\]:$SSH_HOST_PORT" "$kh"; then
    echo "known-hosts  entries for '$VM_NAME' and/or [$SSH_HOST_IP]:$SSH_HOST_PORT in $kh"
  fi
  return 0
}

# Opt-in host software purge (--purge-software). QEMU has no VM registry,
# so unlike VirtualBox there is no reliable way to detect other users of
# the packages -- the confirm prompt IS the safety rail, plus:
# the kvm system group itself is NEVER deleted (libvirt, other users and
# udev rules may rely on it; it came with the system, not with our VM).
purge_host_software() {
  confirm "Purge the QEMU packages and drop the kvm group membership? (uses sudo)" \
    || die "Software purge skipped; everything else was removed."
  local pkgs
  pkgs="$(dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /^qemu-(system|utils)/ { print $2 }')"
  if [[ -n "$pkgs" ]]; then
    log "Purging: $(printf '%s' "$pkgs" | tr '\n' ' ')"
    as_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs \
      || warn "apt-get purge failed; clean it up manually if wanted."
    as_root env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y \
      || warn "apt-get autoremove failed; run it manually if wanted."
  else
    log "No QEMU packages are installed via dpkg; nothing to purge."
  fi
  if getent group kvm >/dev/null 2>&1 && id -nG "$REAL_USER" 2>/dev/null | grep -qw kvm; then
    as_root deluser "$REAL_USER" kvm || true
    log "Revoked kvm group membership for $REAL_USER"
  fi
  log "Note: the kvm system group itself is never removed (other users/libvirt may rely on it)."
}

uninstall_run() {
  log "Uninstall plan for VM '$VM_NAME' (workdir: $WORKDIR)"
  uninstall_items
  if [[ $DRY_RUN -eq 1 ]]; then
    log "dry-run: nothing was removed. Re-run without --dry-run to delete for real."
    return 0
  fi
  confirm "Permanently delete everything listed above?" || die "Aborted; nothing was removed."

  if qemu_running; then
    log "Stopping the running VM first"
    stop_vm
  fi

  local f
  rm -f -- "$DISK" "$CRED_FILE" "$PRESEED_FILE" "$INSTALL_LOG" "$RUN_LOG" \
           "$PIDFILE" "$MONITOR_SOCK" "$KEY_FILE" "$KEY_FILE.pub"
  for f in "$WORKDIR"/debian-*-amd64-netinst.iso "$WORKDIR"/debian-*-amd64-netinst.iso.part; do
    if [[ -e "$f" ]]; then rm -f -- "$f"; fi
  done
  if [[ -d "$WORKDIR/verify" ]]; then rm -rf "$WORKDIR/verify"; fi
  rm -rf "$BOOT_DIR/$VM_NAME"
  rmdir "$BOOT_DIR" 2>/dev/null || true
  rmdir "$RUN_DIR" 2>/dev/null || true
  rmdir "$CRED_DIR" 2>/dev/null || true
  if [[ -d "$WORKDIR" ]] && [[ -z "$(find "$WORKDIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    rmdir "$WORKDIR" || true
  fi

  remove_ssh_block
  if [[ -f "$HOME/.ssh/known_hosts" ]]; then
    forget_old_host_keys
  fi

  if [[ $PURGE_SOFTWARE -eq 1 ]]; then
    purge_host_software
  fi

  log "Removal of '$VM_NAME' is complete."
  local script_path repo_dir
  script_path="$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null)" || script_path="${BASH_SOURCE[0]:-$0}"
  repo_dir="$(dirname -- "$script_path")"
  cat <<EOF

Deliberately NOT touched (do these yourself if you truly want a clean slate):
  * this repo:  rm -rf "$repo_dir"
  * ~/.ssh/known_hosts.old and ~/.ssh/config.mockvps-kvm.bak, if kept or useful
EOF
}

### Summary ###########################################################

print_summary() {
  local f
  cat <<EOF

VM is ready.

Connect:
  ssh $VM_NAME                    # dedicated key; key-only login
  (or) ssh -p $SSH_HOST_PORT $VM_USER@$SSH_HOST_IP

Install something in the guest (sudo asks for the password in):
  ssh $VM_NAME
  cat '$CRED_FILE'                # VM_PASSWORD (root/sudo in the guest)

Forgot the password? It is already in the guest as sudo; the file is 0600.

SSH tunnels (live while an 'ssh $VM_NAME' session is open):
EOF
  if [[ ${#FORWARD_LIST[@]} -eq 0 ]]; then
    echo "  (none)"
  else
    for f in "${FORWARD_LIST[@]}"; do
      echo "  http://localhost:${f%%:*}  ->  guest:${f##*:}"
    done
  fi
  cat <<EOF

Management:
  --start / --stop              boot / gracefully power off
  --status                      is it running?
  --snapshot|--restore NAME     --snapshots  --delete-snapshot NAME
  --provision FILE --provision-only   re-run a script in the running guest
  --uninstall [--dry-run]       remove every trace (preview with --dry-run)
  --uninstall --purge-software  also purge QEMU + kvm membership
Serial consoles: $INSTALL_LOG (install) / $RUN_LOG (run)
EOF
}

### Main ##############################################################

main() {
  init_defaults
  parse_args "$@"
  validate_config
  derive_paths

  [[ "$(uname -s)" == "Linux" ]] || die "This script supports Linux hosts only."
  [[ "$(uname -m)" == "x86_64" ]] || die "This script supports x86_64 hosts only (ARM: look at Lima/multipass)."

  local snap_flag=0 install_opts=0
  if [[ -n "$SNAP_ACTION" ]]; then snap_flag=1; fi
  if [[ -n "$USER_DATA_FILE" || $HAVE_PACKAGES -eq 1 ]]; then install_opts=1; fi

  if (( UNINSTALL + START + STOP + STATUS + PROVISION_ONLY + snap_flag > 1 )); then
    die "--uninstall, --start, --stop, --status, --provision-only and the snapshot actions are mutually exclusive; pick exactly one."
  fi
  if (( UNINSTALL + STOP + STATUS + snap_flag > 0 )) && (( install_opts + ${#PROV_FILES[@]} > 0 )); then
    die "--user-data, --package and --provision cannot be combined with --uninstall, --stop, --status or the snapshot actions."
  fi
  if (( START + PROVISION_ONLY > 0 )) && (( install_opts == 1 )); then
    die "--user-data and --package only apply to a fresh install (the installer bakes them in)."
  fi

  if [[ $UNINSTALL -eq 1 ]]; then
    uninstall_run
    return 0
  fi
  if [[ $DRY_RUN -ne 0 || $PURGE_SOFTWARE -ne 0 ]]; then
    die "--dry-run and --purge-software are only meaningful with --uninstall"
  fi

  if [[ $STOP -eq 1 ]]; then stop_vm; return 0; fi
  if [[ $STATUS -eq 1 ]]; then status_vm; return 0; fi
  if [[ $snap_flag -eq 1 ]]; then snapshot_run; return 0; fi
  if [[ $PROVISION_ONLY -eq 1 ]]; then provision_only_run; return 0; fi

  # From here it is install or --start; both need QEMU + KVM access.
  ensure_qemu
  ensure_kvm_host
  log "Preparing VM '$VM_NAME'"

  if [[ $START -eq 1 ]]; then
    is_vm_installed || die "No installed VM disk at $DISK. Run a plain install first."
    if qemu_running; then
      log "Already running (pid $(head -n1 "$PIDFILE")); ssh $SSH_HOST_IP:$SSH_HOST_PORT"
      run_provisioners
      return 0
    fi
    check_port_free
    start_phase run "$RUN_LOG"
    write_ssh_block
    wait_for_ssh_key_login
    run_provisioners
    print_summary
    return 0
  fi

  if is_vm_installed; then
    log "A VM already exists (disk: $DISK)"
    if qemu_running; then
      die "'$VM_NAME' is running; power it off with '--stop' before reinstalling."
    fi
    if confirm "Delete the existing VM and reinstall from scratch?"; then
      REINSTALL=1
      rm -f -- "$DISK" "$CRED_FILE" "$PRESEED_FILE" "$INSTALL_LOG" "$RUN_LOG"
    else
      log "Reusing the existing VM"
      REINSTALL=0
      if [[ $install_opts -eq 1 ]]; then
        warn "--user-data / --package are ignored: they only apply to a fresh install."
        USER_DATA_FILE=""
      fi
    fi
  fi

  if [[ $REINSTALL -eq 1 ]]; then
    setup_credentials
    ensure_host_key
    ensure_netboot
    build_preseed
    forget_old_host_keys
    INSTALL_DONE=0
    trap cleanup_install EXIT
    create_disk
    build_initrd
    start_phase install "$INSTALL_LOG"
    wait_qemu_exit
    INSTALL_DONE=1
    trap - EXIT
    # The injected initrd holds the guest password (and any user-data): once
    # the install is over it has no further use.
    rm -f -- "$BOOT_DIR/$VM_NAME/initrd-preseed.gz"
    is_vm_installed || die "The installer finished but $DISK is missing or empty; see $INSTALL_LOG."
    log "Install finished. Booting the installed system."
  fi

  check_port_free
  start_phase run "$RUN_LOG"
  write_ssh_block
  wait_for_ssh_key_login
  if [[ $REINSTALL -eq 1 ]]; then wait_cloud_init; fi
  run_provisioners
  print_summary
}

# Allow `source mockvps-kvm.sh` (tests) without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi


