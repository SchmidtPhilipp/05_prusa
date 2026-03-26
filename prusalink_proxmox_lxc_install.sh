#!/usr/bin/env bash
set -euo pipefail
#
# =============================================================================
# PrusaLink on Proxmox — LXC install (guide + automation)
# =============================================================================
#
# This script automates the workflow described in community notes for running
# PrusaLink in a Debian LXC on Proxmox with USB printer (and optional USB
# webcam) pass-through. It aligns with the official repo install paths:
#   - https://github.com/prusa3d/Prusa-Link
#   - https://github.com/compenguy/PrusaLinkDocker (container-oriented deps)
#
# --- Guide summary (condensed) ------------------------------------------------
#
# 1) Create CT: Debian 12, modest disk/CPU/RAM, DHCP or static IP, firewall off
#    on bridge if you prefer; static DHCP lease recommended for a web service.
#
# 2) Optional: disable IPv6 in the guest via sysctl (not done here; add if you
#    use the "disable IPv6" recipe from your notes).
#
# 3) apt update && apt upgrade
#
# 4) Packages (host in notes):
#      git libcap-dev libturbojpeg0 libatlas-base-dev libffi-dev gcc sudo curl
#      python3-dev python3-full python3-pip python3-numpy
#    Optional: ffmpeg (webcam / probing); extra libs often required by PrusaLink
#    wheels from git: libmagic1, build deps — this script installs those too.
#
# 5) User "pi": groups adm,sudo,tty,dialout,video (dialout = serial; video =
#    V4L when you pass /dev/video*).
#
# 6) As pi: python3 -m venv ~/venv-prusalink && pip install (no cache):
#      git+https://github.com/prusa3d/gcode-metadata.git
#      git+https://github.com/prusa3d/Prusa-Connect-SDK-Printer.git
#      git+https://github.com/prusa3d/Prusa-Link.git
#
# 7) mkdir /etc/prusalink && chown pi:pi; install default config from upstream:
#      prusa/link/data/prusalink.ini
#
# 8) USB pass-through on Proxmox host (unprivileged CT):
#    - USB device nodes use major 189 on many kernels → allow c 189:* rwm
#    - Bind-mount /dev/bus/usb/<bus>/<dev> into the CT at the same path
#    - For the printer serial device (e.g. /dev/ttyACM0): use the REAL major/
#      minor from the host (commonly 166:* for ttyACM), NOT the USB bus major,
#      then bind-mount the host tty into the CT.  (Some older notes used
#      mknod 189,0 for ttyACM0 — that does not match `ls -l /dev/ttyACM0`.)
#
# 9) Optional webcam: bind USB node + /dev/videoN; chown on host to mapped
#    uid/gid (often 100000:root for usb, 100000:100044 for video); use ffmpeg
#    inside CT to pick the right /dev/video*; optional Prusa Connect snapshot
#    upload script + systemd (see your notes / gist — not fully automated here).
#
# 10) Edit [printer] port = /dev/ttyACM0 (or ttyUSB0); prusalink -f for debug;
#     systemd: prefer `prusalink -f` + Type=simple (avoids fork/type mismatch
#     with `prusalink start`).
#
# 11) Browser: http://<ct-ip>:8080 — complete wizard / Prusa Connect pairing.
#
# Proxmox device cgroup docs context: pct.conf / LXC device allow lists.
#
# Runtime USB discovery:
#   DISCOVER_USB_AT_RUNTIME=1 (default) — prompt with `lsusb`, pick the printer
#   (and optionally a webcam); the script derives BUS/DEV and finds the serial
#   TTY via sysfs when possible.
#   DISCOVER_USB_AT_RUNTIME=0 — use the PRINTER_USB_* / PRINTER_TTY_* /
#   WEBCAM_* / VIDEO_DEVS values you set above (non-interactive).
#
# =============================================================================

# -----------------------------------------------------------------------------
# User config (edit on the Proxmox host before running)
# -----------------------------------------------------------------------------

# VMID: unset, empty, or 0 = next free ID (≥100). Pin: CTID=101 or CTID=101 ./script.sh
CTID="${CTID:-}"
HOSTNAME="prusalink"

# LXC template volid: storage:vztmpl/<file>. Must exist on host (`pveam list <storage>`).
# If missing, the script lists templates interactively. Download: pveam update && pveam download ...
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"
# Template storage id (usually "local" with dir-type content, not "local-lvm").
VZTMPL_STORAGE="${VZTMPL_STORAGE:-local}"

BRIDGE="vmbr0"

# "dhcp" or "static"
IP_MODE="static"
IP_CIDR="192.168.1.50/24"
GW="192.168.1.1"

# Storage ID from `pvesm status` (e.g. local-lvm, local-zfs). Size = GiB, integer only (no "G" suffix).
ROOTFS_STORAGE="local-lvm"
ROOTFS_SIZE_GB="8"
MEMORY_MB="1024" # notes used 512; 1G is safer with ffmpeg / extra services
CORES="2"
SWAP_MB="100"
STARTUP_ORDER="200"

# Unprivileged LXC (matches common guide). Requires correct host uid/gid map.
UNPRIVILEGED="1"

# 1 = show menus during this script (see header). 0 = use variables only.
DISCOVER_USB_AT_RUNTIME="${DISCOVER_USB_AT_RUNTIME:-1}"

# Printer: character device on Proxmox host (filled by discovery or set by hand)
PRINTER_TTY_HOST="${PRINTER_TTY_HOST:-/dev/ttyACM0}"
# Same path inside CT after bind-mount (usually keep name identical)
PRINTER_TTY_IN_CT="${PRINTER_TTY_IN_CT:-/dev/ttyACM0}"

ENABLE_PRINTER_USB_BUS="1"
# From lsusb "Bus 001 Device 008" → bus 001, device 008 (3-digit paths)
PRINTER_USB_BUS="${PRINTER_USB_BUS:-}"
PRINTER_USB_DEV="${PRINTER_USB_DEV:-}"

# Optional webcam: set ENABLE_WEBCAM=1 and BUS/DEV from lsusb; add VIDEO_DEVS
# space-separated (e.g. "0 1"). Script appends cgroup allow for major 81 and
# bind-mounts /dev/videoN. You may still need host chown (see end of script).
ENABLE_WEBCAM="0"
WEBCAM_USB_BUS=""
WEBCAM_USB_DEV=""
VIDEO_DEVS="" # e.g. "0 1" — set when ENABLE_WEBCAM=1

INSTALL_FFMPEG="0" # set 1 if you use cameras / format probing inside CT

# Official default config from Prusa-Link tree
PRUSALINK_INI_URL="https://raw.githubusercontent.com/prusa3d/Prusa-Link/master/prusa/link/data/prusalink.ini"

# -----------------------------------------------------------------------------
# USB discovery helpers (Proxmox host)
# -----------------------------------------------------------------------------

ensure_lsusb() {
  if command -v lsusb >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing usbutils (provides lsusb)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y usbutils
}

# Args: decimal bus, decimal dev (no leading zeros)
find_tty_for_usb_bus_dev() {
  local want_bus="$1" want_dev="$2"
  local tty sys dir b d
  shopt -s nullglob
  for tty in /dev/ttyACM[0-9]* /dev/ttyUSB[0-9]*; do
    [[ -e "$tty" ]] || continue
    sys="/sys/class/tty/$(basename "$tty")/device"
    [[ -L "$sys" ]] || continue
    dir=$(readlink -f "$sys" 2>/dev/null) || continue
    while [[ -n "$dir" && "$dir" != "/" ]]; do
      if [[ -f "$dir/busnum" && -f "$dir/devnum" ]]; then
        b=$(tr -d ' \n' <"$dir/busnum")
        d=$(tr -d ' \n' <"$dir/devnum")
        if [[ "$b" == "$want_bus" && "$d" == "$want_dev" ]]; then
          echo "$tty"
          return 0
        fi
        break
      fi
      dir=$(dirname "$dir")
    done
  done
  return 1
}

pick_lsusb_entry() {
  local title="$1"
  local -a lines
  mapfile -t lines < <(lsusb)
  if [[ ${#lines[@]} -eq 0 ]]; then
    echo "lsusb produced no output." >&2
    return 1
  fi
  echo "" >&2
  echo "$title" >&2
  local i sel
  for i in "${!lines[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "${lines[$i]}" >&2
  done
  while true; do
    read -r -p "Enter number (1-${#lines[@]}): " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 && "$sel" -le ${#lines[@]} ]]; then
      echo "${lines[$((sel - 1))]}"
      return 0
    fi
    echo "Invalid choice." >&2
  done
}

# Sets PRINTER_USB_BUS PRINTER_USB_DEV (3-digit), PRINTER_TTY_HOST, PRINTER_TTY_IN_CT
discover_printer_interactive() {
  ensure_lsusb
  local line bus_dec dev_dec tty
  line="$(pick_lsusb_entry "Select the USB device for your Prusa printer (composite listing is OK):")"
  line="${line//$'\r'/}"
  # Use 10# for decimal: stripping leading zeros with ##0* breaks / turns some values into 0.
  if [[ ! "$line" =~ Bus[[:space:]]+([0-9]+)[[:space:]]+Device[[:space:]]+([0-9]+): ]]; then
    echo "Could not parse lsusb line: $line"
    exit 1
  fi
  bus_dec=$((10#${BASH_REMATCH[1]}))
  dev_dec=$((10#${BASH_REMATCH[2]}))
  PRINTER_USB_BUS="$(printf '%03d' "$bus_dec")"
  PRINTER_USB_DEV="$(printf '%03d' "$dev_dec")"
  echo ""
  echo "Using USB bus ${PRINTER_USB_BUS} device ${PRINTER_USB_DEV} (${line#*: })"

  if tty="$(find_tty_for_usb_bus_dev "$bus_dec" "$dev_dec")"; then
    PRINTER_TTY_HOST="$tty"
    PRINTER_TTY_IN_CT="$tty"
    echo "Matched serial device: ${PRINTER_TTY_HOST}"
  else
    echo "Could not auto-match a /dev/ttyACM* or /dev/ttyUSB* for this USB device."
    echo "Known serial ports right now:"
    shopt -s nullglob
    ls -l /dev/ttyACM[0-9]* /dev/ttyUSB[0-9]* 2>/dev/null || echo "  (none)"
    shopt -u nullglob
    local manual
    read -r -p "Enter printer serial path (e.g. /dev/ttyACM0): " manual
    if [[ ! -e "$manual" ]]; then
      echo "Not found: $manual"
      exit 1
    fi
    PRINTER_TTY_HOST="$manual"
    PRINTER_TTY_IN_CT="$manual"
  fi
}

discover_webcam_interactive() {
  read -r -p "Add a USB webcam for pass-through too? [y/N]: " yn
  [[ "${yn,,}" == y* || "${yn,,}" == e* ]] || return 0
  ENABLE_WEBCAM="1"
  INSTALL_FFMPEG="1"
  ensure_lsusb
  local line bus_dec dev_dec
  line="$(pick_lsusb_entry "Select the USB webcam (or its parent hub device if needed):")"
  line="${line//$'\r'/}"
  if [[ ! "$line" =~ Bus[[:space:]]+([0-9]+)[[:space:]]+Device[[:space:]]+([0-9]+): ]]; then
    echo "Could not parse lsusb line: $line"
    exit 1
  fi
  bus_dec=$((10#${BASH_REMATCH[1]}))
  dev_dec=$((10#${BASH_REMATCH[2]}))
  WEBCAM_USB_BUS="$(printf '%03d' "$bus_dec")"
  WEBCAM_USB_DEV="$(printf '%03d' "$dev_dec")"
  echo "Webcam USB bus ${WEBCAM_USB_BUS} device ${WEBCAM_USB_DEV}"

  echo "" >&2
  echo "Video devices on host:" >&2
  local -a vids
  mapfile -t vids < <(shopt -s nullglob; printf '%s\n' /dev/video* | sort -V)
  shopt -u nullglob
  if [[ ${#vids[@]} -eq 0 ]]; then
    echo "No /dev/video* — plug the camera, load uvcvideo, then re-run." >&2
    exit 1
  fi
  local i
  for i in "${!vids[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "${vids[$i]}" >&2
  done
  read -r -p "Enter video device numbers to pass through (e.g. 1 or 1 2): " -a pickv
  VIDEO_DEVS=""
  local p idx
  for p in "${pickv[@]}"; do
    if [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 && "$p" -le ${#vids[@]} ]]; then
      idx=$(basename "${vids[$((p - 1))]}")
      idx="${idx#video}"
      VIDEO_DEVS+="$idx "
    else
      echo "Invalid video choice: $p"
      exit 1
    fi
  done
  VIDEO_DEVS="${VIDEO_DEVS%% }"
}

# Proxmox uses one VMID space for VMs and LXCs; IDs <100 are reserved (pct.conf).
next_free_vmid() {
  local id="${1:-100}"
  while [[ -e "/etc/pve/lxc/${id}.conf" ]] || [[ -e "/etc/pve/qemu-server/${id}.conf" ]]; do
    id=$((id + 1))
  done
  echo "$id"
}

# List volids from pveam (column 1 after header).
pveam_template_volids() {
  local st="$1"
  pveam list "$st" 2>/dev/null | awk 'NR > 1 && $1 != "" && $1 !~ /^-+$/ { print $1 }'
}

template_volid_on_storage() {
  local st="$1" want="$2" v
  while IFS= read -r v; do
    [[ "$v" == "$want" ]] && return 0
  done < <(pveam_template_volids "$st")
  return 1
}

pick_lxc_template_interactive() {
  local st="${1:-local}"
  local -a rows
  mapfile -t rows < <(pveam_template_volids "$st")
  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No LXC templates on storage \"${st}\"." >&2
    echo "Run: pveam update && pveam available | grep -i debian" >&2
    echo "Then: pveam download ${st} debian-12-standard_<version>_amd64.tar.zst" >&2
    exit 1
  fi
  echo "" >&2
  echo "Select LXC template (storage \"${st}\"):" >&2
  local i
  for i in "${!rows[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "${rows[$i]}" >&2
  done
  local sel
  while true; do
    read -r -p "Enter number (1-${#rows[@]}): " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 && "$sel" -le ${#rows[@]} ]]; then
      echo "${rows[$((sel - 1))]}"
      return 0
    fi
    echo "Invalid choice." >&2
  done
}

# Sets TEMPLATE to a volid that exists on VZTMPL_STORAGE (or exits).
resolve_lxc_template() {
  local st="${VZTMPL_STORAGE:-local}"
  if ! command -v pveam >/dev/null 2>&1; then
    echo "pveam not found (expected on Proxmox VE)."
    exit 1
  fi
  if template_volid_on_storage "$st" "$TEMPLATE"; then
    echo "Using LXC template: ${TEMPLATE}"
    return 0
  fi
  echo "Template not found on storage \"${st}\": ${TEMPLATE}"
  echo "Listing what's installed on \"${st}\":"
  pveam list "$st" 2>/dev/null || true
  echo ""
  echo "Download a Debian 12 standard image (adjust filename to pveam available):"
  echo "  pveam update && pveam download ${st} debian-12-standard_12.7-1_amd64.tar.zst"
  echo "Or set TEMPLATE and VZTMPL_STORAGE in this script / environment."
  echo ""
  echo "Pick an installed template:"
  TEMPLATE="$(pick_lxc_template_interactive "$st")"
  echo "Using LXC template: ${TEMPLATE}"
}

# -----------------------------------------------------------------------------
# Host prerequisites
# -----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root on the Proxmox host."
  exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
  echo "pct not found. Run this on a Proxmox node."
  exit 1
fi

if [[ -z "${CTID}" ]] || [[ "${CTID}" == "0" ]]; then
  CTID="$(next_free_vmid 100)"
  echo "Using next free VMID for this LXC: ${CTID}"
elif ! [[ "${CTID}" =~ ^[0-9]+$ ]] || [[ "${CTID}" -lt 100 ]]; then
  echo "CTID must be empty/0 (auto) or an integer >= 100 (got: ${CTID})"
  exit 1
fi

if pct status "$CTID" >/dev/null 2>&1; then
  echo "CT $CTID already exists. Remove it or change CTID."
  exit 1
fi

resolve_lxc_template

if [[ "$DISCOVER_USB_AT_RUNTIME" == "1" ]]; then
  discover_printer_interactive
  discover_webcam_interactive
else
  if [[ "$ENABLE_PRINTER_USB_BUS" == "1" ]]; then
    if [[ -z "${PRINTER_USB_BUS:-}" || -z "${PRINTER_USB_DEV:-}" ]]; then
      echo "Set PRINTER_USB_BUS and PRINTER_USB_DEV, or DISCOVER_USB_AT_RUNTIME=1."
      exit 1
    fi
  fi
fi

if [[ ! -e "$PRINTER_TTY_HOST" ]]; then
  echo "Printer TTY not found: $PRINTER_TTY_HOST"
  echo "Plug in the printer and confirm the path (ttyACM0 vs ttyUSB0)."
  exit 1
fi

TTY_BASENAME="$(basename "$PRINTER_TTY_HOST")"
if [[ "$TTY_BASENAME" != "$(basename "$PRINTER_TTY_IN_CT")" ]]; then
  echo "PRINTER_TTY_HOST basename must match PRINTER_TTY_IN_CT basename for bind mount."
  exit 1
fi

read -r TTY_MAJ_HEX TTY_MIN_HEX < <(stat -c '%t %T' "$PRINTER_TTY_HOST")
TTY_MAJ_DEC=$((16#$TTY_MAJ_HEX))
TTY_MIN_DEC=$((16#$TTY_MIN_HEX))

CONF_FILE="/etc/pve/lxc/${CTID}.conf"

# -----------------------------------------------------------------------------
# Build net0 string
# -----------------------------------------------------------------------------

if [[ "$IP_MODE" == "dhcp" ]]; then
  NET0="name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=auto,type=veth"
elif [[ "$IP_MODE" == "static" ]]; then
  NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GW},ip6=auto,type=veth"
else
  echo "IP_MODE must be dhcp or static"
  exit 1
fi

# -----------------------------------------------------------------------------
# Create CT
# -----------------------------------------------------------------------------

echo "Creating CT ${CTID} (${HOSTNAME})..."

pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --ostype debian \
  --net0 "$NET0" \
  --memory "$MEMORY_MB" \
  --cores "$CORES" \
  --swap "$SWAP_MB" \
  --rootfs "${ROOTFS_STORAGE}:${ROOTFS_SIZE_GB}" \
  --unprivileged "$UNPRIVILEGED" \
  --features nesting=1 \
  --onboot 1 \
  --startup "order=${STARTUP_ORDER}"

# -----------------------------------------------------------------------------
# Append LXC device / mount config (guide pattern, tty major corrected)
# -----------------------------------------------------------------------------

if [[ ! -f "$CONF_FILE" ]]; then
  echo "Missing $CONF_FILE after pct create"
  exit 1
fi

{
  echo ""
  echo "## Added by prusalink_proxmox_lxc_install.sh (see header guide)"
} >> "$CONF_FILE"

append_usb_bus_mount() {
  local bus="$1" dev="$2"
  local host_path="/dev/bus/usb/${bus}/${dev}"
  if [[ ! -e "$host_path" ]]; then
    echo "WARNING: USB node not found (plug device first?): $host_path"
    return 0
  fi
  if grep -F "lxc.mount.entry: ${host_path} dev/bus/usb/${bus}/${dev}" "$CONF_FILE" >/dev/null 2>&1; then
    return 0
  fi
  # Major 189 is typical for usbfs device nodes — matches many Proxmox/LXC guides
  if ! grep -Fxq 'lxc.cgroup2.devices.allow: c 189:* rwm' "$CONF_FILE" 2>/dev/null; then
    echo "lxc.cgroup2.devices.allow: c 189:* rwm" >> "$CONF_FILE"
  fi
  echo "lxc.mount.entry: ${host_path} dev/bus/usb/${bus}/${dev} none bind,optional,create=file" >> "$CONF_FILE"
}

if [[ "$ENABLE_PRINTER_USB_BUS" == "1" ]]; then
  append_usb_bus_mount "$PRINTER_USB_BUS" "$PRINTER_USB_DEV"
fi

# Real TTY major:minor (e.g. ttyACM → often 166:0), from host stat — not USB 189
echo "lxc.cgroup2.devices.allow: c ${TTY_MAJ_DEC}:${TTY_MIN_DEC} rwm" >> "$CONF_FILE"
echo "lxc.mount.entry: ${PRINTER_TTY_HOST} dev/${TTY_BASENAME} none bind,optional,create=file" >> "$CONF_FILE"

if [[ "$ENABLE_WEBCAM" == "1" ]] && [[ -n "$WEBCAM_USB_BUS" ]] && [[ -n "$WEBCAM_USB_DEV" ]]; then
  append_usb_bus_mount "$WEBCAM_USB_BUS" "$WEBCAM_USB_DEV"
  # V4L character devices often use major 81 (verify with ls -l /dev/video0 on host)
  if ! grep -Fxq 'lxc.cgroup2.devices.allow: c 81:* rwm' "$CONF_FILE" 2>/dev/null; then
    echo "lxc.cgroup2.devices.allow: c 81:* rwm" >> "$CONF_FILE"
  fi
  # shellcheck disable=SC2206
  vid_array=(${VIDEO_DEVS})
  if [[ ${#vid_array[@]} -eq 0 ]]; then
    echo "ENABLE_WEBCAM=1 but VIDEO_DEVS empty — set e.g. VIDEO_DEVS=\"0 1\""
    exit 1
  fi
  for n in "${vid_array[@]}"; do
    if [[ -e "/dev/video${n}" ]]; then
      echo "lxc.mount.entry: /dev/video${n} dev/video${n} none bind,optional,create=file" >> "$CONF_FILE"
    else
      echo "WARNING: /dev/video${n} not on host; skipped"
    fi
  done
fi

# -----------------------------------------------------------------------------
# Start CT and provision Debian + PrusaLink (guide steps 3–7, 10)
# -----------------------------------------------------------------------------

echo "Starting CT ${CTID}..."
pct start "$CTID"

echo "Waiting for boot..."
sleep 12

echo "apt update/upgrade and install packages..."
pct exec "$CTID" -- bash -lc "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
PKGS=(
  git libcap-dev libturbojpeg0 libffi-dev
  gcc sudo curl
  python3-dev python3-full python3-pip python3-numpy
  libmagic1 libopenblas0 libopenblas-dev iptables
  build-essential cmake
)
# libatlas-base-dev was dropped after Debian bookworm; OpenBLAS replaces it for numpy/PrusaLink.
if [[ '${INSTALL_FFMPEG}' == '1' ]]; then PKGS+=(ffmpeg); fi
apt-get install -y \"\${PKGS[@]}\"
"

echo "Create user pi and /etc/prusalink..."
pct exec "$CTID" -- bash -lc "
set -euo pipefail
if ! id pi >/dev/null 2>&1; then
  adduser --disabled-password --gecos \"\" pi
  echo 'pi ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/pi
  chmod 440 /etc/sudoers.d/pi
fi
usermod -a -G adm,sudo,tty,dialout,video pi || true
install -d -m 0755 -o pi -g pi /etc/prusalink
"

echo "Install upstream prusalink.ini..."
pct exec "$CTID" -- bash -lc "
set -euo pipefail
curl -fsSL -o /tmp/prusalink.ini '${PRUSALINK_INI_URL}'
install -m 0644 -o pi -g pi /tmp/prusalink.ini /etc/prusalink/prusalink.ini
"

echo "venv + pip install Prusa-Link stack (from git, as pi)..."
pct exec "$CTID" -- bash -lc "
set -euo pipefail
su - pi -c 'python3 -m venv /home/pi/venv-prusalink'
su - pi -c \"
  source /home/pi/venv-prusalink/bin/activate
  pip install --no-cache-dir -U pip setuptools wheel
  pip install --no-cache-dir \\
    git+https://github.com/prusa3d/gcode-metadata.git \\
    git+https://github.com/prusa3d/Prusa-Connect-SDK-Printer.git \\
    git+https://github.com/prusa3d/Prusa-Link.git
\"
"

echo "Set [printer] port in /etc/prusalink/prusalink.ini..."
pct exec "$CTID" -- bash -lc "
set -euo pipefail
INI=/etc/prusalink/prusalink.ini
# Upstream ships '; port = /dev/ttyAMA0' — replace that or any active port line
sed -i \\
  -e '/^[[:space:]]*;[[:space:]]*port[[:space:]]*=/s|.*|port = ${PRINTER_TTY_IN_CT}|' \\
  -e '/^[[:space:]]*port[[:space:]]*=/s|^[[:space:]]*port[[:space:]]*=.*|port = ${PRINTER_TTY_IN_CT}|' \\
  \"\$INI\"
chown pi:pi \"\$INI\"
"

echo "Install systemd unit (prusalink -f + Type=simple)..."
pct exec "$CTID" -- bash -lc "
set -euo pipefail
if command -v systemctl >/dev/null 2>&1; then
cat > /etc/systemd/system/prusalink.service << 'UNIT'
[Unit]
Description=PrusaLink Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
Group=pi
WorkingDirectory=/home/pi
Environment=LC_ALL=C.UTF-8
Environment=LANG=C.UTF-8
ExecStart=/home/pi/venv-prusalink/bin/prusalink -f
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable prusalink.service
  systemctl restart prusalink.service || systemctl start prusalink.service
else
  echo 'No systemd in CT; run as pi: source ~/venv-prusalink/bin/activate && prusalink -f'
fi
"

# -----------------------------------------------------------------------------
# Unprivileged host ownership hints (webcam / USB — from guide)
# -----------------------------------------------------------------------------

if [[ "$UNPRIVILEGED" == "1" ]]; then
  echo ""
  echo "=== Unprivileged CT notes ==="
  echo "If printer or webcam access fails, on the Proxmox host you may need to"
  echo "chown passed-through nodes to the CT root mapping (often uid 100000) and"
  echo "video group mapping (often gid 100044 for container group video:44), e.g.:"
  echo "  chown 100000:100000 /dev/bus/usb/${PRINTER_USB_BUS}/${PRINTER_USB_DEV}"
  echo "For V4L after enabling webcam mounts:"
  echo "  chown 100000:100044 /dev/video0"
  echo "Adjust numbers if your CT idmap differs (see /etc/pve/lxc/${CTID}.conf)."
fi

echo ""
echo "=== Done ==="
echo "Open: http://<container-ip>:8080"
echo "Debug: pct exec ${CTID} -- su - pi -c 'source ~/venv-prusalink/bin/activate && prusalink -f'"
echo "Logs:  pct exec ${CTID} -- journalctl -u prusalink.service -e --no-pager"
