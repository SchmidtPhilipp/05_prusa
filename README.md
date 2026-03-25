# PrusaLink on Proxmox (LXC)

This repo contains a bash script that creates a **Debian LXC** on **Proxmox VE**, installs **PrusaLink** (venv + git installs), and configures **USB printer** pass-through (optional **webcam**). It matches the common “PrusaLink in LXC” workflow, with interactive USB discovery and safer serial handling than bind-mounting the wrong device major/minor.

- Script: [`prusalink_proxmox_lxc_install.sh`](./prusalink_proxmox_lxc_install.sh)
- This repository: [github.com/SchmidtPhilipp/05_prusa](https://github.com/SchmidtPhilipp/05_prusa)
- Upstream project: [Prusa-Link](https://github.com/prusa3d/Prusa-Link)

## Prerequisites

- A **Proxmox VE** node where you can run as **root**
- A **Debian 12** LXC template available on that node (adjust `TEMPLATE` in the script if yours differs), e.g. from `pveam available`
- The **3D printer** connected by **USB** to the Proxmox host (for interactive discovery)
- Stable networking: **DHCP** or edit **static** `IP_CIDR` / `GW` in the script before running

## Run from a URL

Raw install script (branch `main`):

`https://raw.githubusercontent.com/SchmidtPhilipp/05_prusa/main/prusalink_proxmox_lxc_install.sh`

On the **Proxmox host** as **root**:

```bash
SCRIPT_URL='https://raw.githubusercontent.com/SchmidtPhilipp/05_prusa/main/prusalink_proxmox_lxc_install.sh'

curl -fsSL "$SCRIPT_URL" -o /root/prusalink_proxmox_lxc_install.sh
chmod +x /root/prusalink_proxmox_lxc_install.sh
/root/prusalink_proxmox_lxc_install.sh
```

Using `wget` instead of `curl`:

```bash
SCRIPT_URL='https://raw.githubusercontent.com/SchmidtPhilipp/05_prusa/main/prusalink_proxmox_lxc_install.sh'

wget -O /root/prusalink_proxmox_lxc_install.sh "$SCRIPT_URL"
chmod +x /root/prusalink_proxmox_lxc_install.sh
/root/prusalink_proxmox_lxc_install.sh
```

**Pipe one-liner** (only use if you trust the URL and TLS endpoint):

```bash
curl -fsSL 'https://raw.githubusercontent.com/SchmidtPhilipp/05_prusa/main/prusalink_proxmox_lxc_install.sh' | bash
```

Prefer saving to a file first so you can **edit variables** (CT ID, template, network) before executing.

### Clone the repo instead

```bash
git clone https://github.com/SchmidtPhilipp/05_prusa.git
cd 05_prusa
chmod +x prusalink_proxmox_lxc_install.sh
# edit variables, then (on the Proxmox host):
sudo ./prusalink_proxmox_lxc_install.sh
```

## Before you run

Open the script and check at least:

| Variable | Typical value |
|----------|----------------|
| `CTID` | Unique container ID (e.g. `101`) |
| `TEMPLATE` | Your template string, e.g. `local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst` |
| `BRIDGE` | Host bridge, often `vmbr0` |
| `IP_MODE` | `dhcp` or `static` |
| `IP_CIDR` / `GW` | If `IP_MODE=static` |

With **default** `DISCOVER_USB_AT_RUNTIME=1`, the script will prompt for:

1. The printer line from `lsusb`
2. Optionally a webcam and which `/dev/video*` nodes to pass through

For **no prompts**, set variables and run non-interactively:

```bash
export DISCOVER_USB_AT_RUNTIME=0
export PRINTER_USB_BUS='001'
export PRINTER_USB_DEV='008'
export PRINTER_TTY_HOST='/dev/ttyACM0'
export PRINTER_TTY_IN_CT='/dev/ttyACM0'
# … then edit the rest in the file or export what the script supports
./prusalink_proxmox_lxc_install.sh
```

(Non-interactive mode still requires `PRINTER_USB_BUS` / `PRINTER_USB_DEV` when `ENABLE_PRINTER_USB_BUS=1`.)

## After installation

1. **Web UI**: open `http://<container-ip>:8080` in a browser (default from upstream `prusalink.ini`; adjust inside the guest if you change the `[http]` section).
2. **Complete the PrusaLink wizard** and Prusa Connect pairing as usual.
3. **Inside the container** (optional checks), as root or with `pct exec`:

   ```bash
   pct exec <CTID> -- systemctl status prusalink.service --no-pager
   pct exec <CTID> -- journalctl -u prusalink.service -e --no-pager
   ```

4. **Manual foreground run** (debug), as user `pi`:

   ```bash
   pct exec <CTID> -- su - pi -c 'source ~/venv-prusalink/bin/activate && prusalink -f'
   ```

## Unprivileged CT and USB/video permissions

If the printer or webcam do not work inside the CT, on the **Proxmox host** you may need to adjust ownership of passed-through nodes to match the container’s **id map** (often UID **100000**, video GID mapping **100044** — see the hints printed at the end of the script and your `/etc/pve/lxc/<CTID>.conf`).

## Security notes

- The script gives user **`pi`** passwordless **`sudo`** for convenience (same idea as many Pi-style guides). Tighten `/etc/sudoers.d/pi` in the guest if you want least privilege.
- **USB passthrough** gives the guest direct access to host USB devices; treat the CT as trusted.

## References

- [prusa3d/Prusa-Link](https://github.com/prusa3d/Prusa-Link)
- [Proxmox `pct` / LXC](https://pve.proxmox.com/pve-docs/chapter-pct.html)
