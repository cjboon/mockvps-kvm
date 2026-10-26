# mockvps-kvm

Spin up a disposable Debian "VPS" on your own machine with QEMU/KVM. One script, one `qemu-system-x86_64` process, plain files. No libvirt daemon, no VirtualBox, no GUI.

```console
$ ./mockvps-kvm.sh        # unattended Debian install, typically 5-15 minutes
$ ssh mockvps-kvm         # key-only login, ready to use
```

Use it to try out server setup scripts, practice sysadmin tasks, test Ansible playbooks, or run a throwaway web server, then delete every trace with one command.

## Features

- **Unattended install.** Boots Debian's official netboot kernel and initrd directly. A generated preseed drives the installer, and no ISO is needed.
- **Verified downloads.** Kernel and initrd are checked against Debian's `SHA256SUMS`. When `gpgv` and `debian-archive-keyring` are available, that checksum file is authenticated through Debian's GPG-signed `InRelease`.
- **Secure by default.** SSH is key-only (a dedicated Ed25519 key) and reachable from your host only. The guest password is random and used for `sudo` only.
- **cloud-init support.** Pass `--user-data` to configure the guest on first boot.
- **SSH provisioner.** Run your own bash scripts as root in the guest with `--provision`, and re-run them any time.
- **Snapshots.** Save and roll back the disk state with qcow2 internal snapshots.
- **Clean removal.** `--uninstall` removes the disk, keys, credentials, logs, the `~/.ssh/config` block and the `known_hosts` entries, with a `--dry-run` preview.
- **Stall detection.** If the installer stops producing output, the script shows what it is waiting on and eventually aborts and cleans up.

## Requirements

- An x86_64 Linux host with KVM (`/dev/kvm`; VT-x/AMD-V enabled in firmware)
- `qemu-system-x86` and `qemu-utils` (on apt-based hosts the script offers to install them)
- `wget`, `cpio`, `gzip`, `sha256sum` and an OpenSSH client
- Optional but recommended: `gpgv` and `debian-archive-keyring` (signature verification), `socat` or `nc` (graceful ACPI shutdown), `ss` or `netstat` (port-in-use check)

The script adds your user to the `kvm` group if needed (uses `sudo`). It does not need to run as root.

## Quick start

```bash
git clone <this repo>
cd <this repo>
chmod +x mockvps-kvm.sh

./mockvps-kvm.sh                 # install and wait for SSH
ssh mockvps-kvm                  # log in (dedicated key, ~/.ssh/config entry added)
cat ~/vpskvm/credentials/mockvps-kvm.env   # the guest's sudo password
```

Day-to-day:

```bash
./mockvps-kvm.sh --stop          # graceful power off
./mockvps-kvm.sh --start         # boot it again
./mockvps-kvm.sh --status
./mockvps-kvm.sh --uninstall     # remove everything (asks first)
```

By default the guest gets 2 vCPUs, 2 GiB RAM and a 20 GB disk, and an SSH tunnel makes the guest's port 80 available at `http://localhost:8080` while an `ssh mockvps-kvm` session is open.

## Viewing a website from your host

The VM is headless, so you browse from your own machine. The script sets up an SSH tunnel for this: `http://localhost:8080` on your host reaches port 80 in the guest.

```bash
ssh mockvps-kvm                          # keep this session open
# inside the VM:
sudo apt-get install -y apache2          # or nginx, etc.
# on your host, in any browser:
#   http://localhost:8080
```

- **The tunnel only exists while an `ssh <name>` session is open.** If the browser says "connection refused", check that first. To hold the tunnel open without a shell, run `ssh -N mockvps-kvm`.
- **Other ports:** add tunnels with `-f LOCAL:GUEST`, for example `-f 8443:443`. Use `--no-web-tunnel` to drop the default 8080 tunnel.
- **Port already in use on the host?** SSH warns and carries on without that tunnel. Pick another local port, for example `--no-web-tunnel -f 9090:80`.
- **Troubleshooting:** inside the VM, `curl -I http://localhost` checks that the web server is up. On the host, `curl -I http://localhost:8080` checks the tunnel. If the first works and the second doesn't, the problem is the tunnel.

By default nothing is exposed to your network: the tunnels listen on your host's loopback only (unless you changed `-k` or your own SSH settings).

## Provisioning

### cloud-init (`--user-data`)

Use a normal `#cloud-config` file. It is seeded as the NoCloud datasource during the install, and the script waits for cloud-init to finish before reporting the VM ready. It applies to fresh installs only.

```yaml
#cloud-config
package_update: true
packages: [nginx, git]
write_files:
  - path: /var/www/html/index.html
    content: "hello from mockvps"
runcmd:
  - systemctl enable --now nginx
```

```bash
./mockvps-kvm.sh --user-data my-config.yaml
# then browse http://localhost:8080 while `ssh mockvps-kvm` is open
```

Notes:

- The first line must be `#cloud-config` (a `#!` script or MIME multipart also works). Maximum size is 256 KiB.
- SSH stays key-only whatever the user-data says; the hardening drop-in sorts first and wins.
- Debian's cloud-init may create its default `debian` user (locked password, no key). Define `users:` in your user-data if you don't want it.
- cloud-init is told not to regenerate SSH host keys or re-render the network config, so `known_hosts` entries stay valid.

### Install extra packages (`-P`)

```bash
./mockvps-kvm.sh -P git -P curl -P htop
```

The Debian installer installs them. Repeatable, fresh installs only.

### SSH provisioner (`--provision`)

Run one or more bash scripts as root inside the guest once SSH is up:

```bash
./mockvps-kvm.sh --provision setup-base.sh --provision setup-app.sh
```

- Scripts run in order and the run stops at the first failure. The VM is left running so you can debug.
- They run non-interactively (`DEBIAN_FRONTEND=noninteractive`) with stdin closed.
- The sudo password is sent over the SSH channel, never on a command line.
- Scripts are also run on `--start`, so write them to be idempotent.

Iterate on a script against a running VM without reinstalling:

```bash
./mockvps-kvm.sh --provision-only --provision setup-app.sh
```

## Snapshots

Snapshots are qcow2 internal snapshots of the disk. The VM is powered off for the operation (the script asks, then boots it again if it was running). They capture disk state only, not RAM.

```bash
./mockvps-kvm.sh --snapshot before-upgrade
# ... break things ...
./mockvps-kvm.sh --restore before-upgrade      # asks first; everything written since is lost
./mockvps-kvm.sh --snapshots                   # list
./mockvps-kvm.sh --delete-snapshot before-upgrade
```

Names are 1-64 characters from `A-Za-z0-9_.-`, not starting with `-` or `.`. A restore keeps the snapshot, so you can roll back to it again.

## Options

| Option | Default | Meaning |
|---|---|---|
| `-n, --name NAME` | `mockvps-kvm` | VM name (also the `ssh` host alias) |
| `-u, --user USER` | `vps` | Guest user |
| `-p, --port PORT` | `2232` | Host port for the SSH forward |
| `-c, --cpus N` | `2` | vCPUs |
| `-m, --memory MIB` | `2048` | RAM in MiB |
| `-d, --disk MB` | `20000` | Disk size in MB |
| `-w, --workdir DIR` | `~/vpskvm` | State directory (no spaces) |
| `-s, --suite NAME` | `stable` | Debian release, e.g. `trixie` |
| `-f, --forward L:G` | | Also tunnel host port `L` to guest port `G` over SSH (repeatable, `L` 1024-65535) |
| `-k, --ip IP` | `127.0.0.1` | Bind the SSH forward to another address (you are warned and asked to confirm) |
| `--no-web-tunnel` | | Skip the default `8080 -> guest:80` tunnel |
| `--user-data FILE` | | cloud-init user-data (fresh install) |
| `-P, --package NAME` | | Extra package for the installer (repeatable, fresh install) |
| `--provision FILE` | | Script to run as root in the guest (repeatable) |
| `--https-mirror` | off | Installer fetches packages over https |
| `--require-signature` | off | Refuse to continue unless the netboot checksums are GPG-authenticated |
| `-y, --yes` | | Non-interactive: confirm all prompts |
| `-h, --help` | | Full help |

Management actions (use exactly one):

| Action | Meaning |
|---|---|
| `--start` / `--stop` / `--status` | Boot headless / graceful ACPI power off / is it running? |
| `--provision-only` | Run the `--provision` files against the running VM |
| `--snapshot NAME` / `--restore NAME` / `--snapshots` / `--delete-snapshot NAME` | Snapshots |
| `--uninstall` (alias `--remove`) | Remove every trace of the VM |
| `--uninstall --dry-run` | Only list what would be removed |
| `--uninstall --purge-software` | Also purge the QEMU packages and drop your `kvm` group membership. QEMU keeps no registry of other users, so only use this if nothing else on the host uses QEMU. |

### Environment variables

Every option has an environment equivalent; flags win.

`VM_NAME`, `VM_USER`, `SSH_HOST_PORT`, `VM_VCPUS`, `VM_MEMORY`, `VM_DISK_SIZE_MB`, `WORKDIR`, `DEBIAN_SUITE`, `SSH_HOST_IP`, `WEB_TUNNEL=0|1`, `FORWARDS="8443:443,3000:3000"`, `USER_DATA=FILE`, `PACKAGES="git,curl"`, `PROVISION_FILES="a.sh:b.sh"`, `PROVISION_ONLY=1`, `DEBIAN_MIRROR_PROTO=http|https`, `REQUIRE_SIGNATURE=1`, `UNINSTALL=1`, `DRY_RUN=1`, `PURGE_SOFTWARE=1`, `START=1`, `STOP=1`, `STATUS=1`, `VM_PASSWORD` (see below).

Installer stall detection: `INSTALL_STALL_WARN` (default 180 s) and `INSTALL_STALL_ABORT` (default 600 s). `MOCKVPS_QEMU` selects a different QEMU binary.

## Security model

- **SSH is loopback-only.** QEMU forwards `127.0.0.1:<port>` to the guest's port 22. Other forwards (`-f`, the default 8080) are SSH `LocalForward`s that exist only while an `ssh <name>` session is open. Binding elsewhere with `-k` warns you first.
- **Key-only login.** A dedicated Ed25519 key (`~/.ssh/<name>_id`) is installed and `PasswordAuthentication` is disabled in the guest. Root login is off.
- **The preseed never crosses a network.** It lives in 0600 files on the host and in a private copy of the installer initrd, and it is read by the installer as `/preseed.cfg`. The initrd copy (which also carries your user-data) is deleted after the install.
- **Random guest password.** 30 alphanumeric characters, stored 0600 in `<workdir>/credentials/<name>.env` as a plain `VM_PASSWORD=value` line. The file is parsed, never sourced. A password you supply via `VM_PASSWORD` may only contain `A-Z a-z 0-9 . _ ~ @ + = : , -`.
- **Download verification.** SHA256 checks on the kernel and initrd, plus GPG verification of the checksum file when the Debian keyring and `gpgv` are present. Packages installed by the installer are verified by apt as usual.

## Where things live

| Path | Contents |
|---|---|
| `~/vpskvm/<name>.qcow2` | Guest disk (and its snapshots) |
| `~/vpskvm/credentials/<name>.env` | Guest sudo password (0600) |
| `~/vpskvm/<name>-install.log`, `-run.log` | Serial console logs |
| `~/vpskvm/boot/`, `run/` | Netboot files; QEMU pidfile and monitor socket |
| `~/.ssh/<name>_id` (+ `.pub`) | Dedicated SSH key |
| `~/.ssh/config` | A managed block between `# BEGIN/END mockvps-kvm:<name>` markers (a `.mockvps-kvm.bak` backup is kept) |

`--uninstall` removes all of the above (and the matching `known_hosts` entries) but never this repository.

## Exit codes

`0` success, `1` error, `3` the VM is up but key-only SSH login was refused (the message says how to recover using the stored password).

## Troubleshooting

- **`/dev/kvm does not exist`**: enable VT-x/AMD-V in firmware, then `sudo modprobe kvm_intel` (or `kvm_amd`). Inside a VM you need nested virtualization.
- **Installer seems stuck**: the script warns after `INSTALL_STALL_WARN` seconds and prints the installer's last screen. The full console log is `~/vpskvm/<name>-install.log`.
- **Port already in use**: pick another with `-p`.
- **Signature warning**: install `gpgv` and `debian-archive-keyring`, or pass `--require-signature` to make this a hard error.
- **Run several VMs**: give each its own `-n NAME` and `-p PORT`.

## Limitations

- x86_64 Linux hosts only.
- Snapshots are offline, disk-only snapshots.
- `--https-mirror` depends on the Debian installer's https support and is less tested than the default.
- Tested in pieces rather than on every distro and QEMU version, so please open an issue if you hit a problem on your setup.

## License

Add your license here (for example MIT) and include a `LICENSE` file in the repository.
