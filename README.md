# SN46 miner

Serves GLM-5.3-Flash on Subnet 46 and produces the proof evidence the network verifies.
One machine, one class of GPU, one command to install.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Subnet46/sn46-miner-releases/main/install.sh | sudo bash
```

The installer checks the machine, downloads the current release and verifies it against
the signing key built into the installer, asks for your **miner uid** and **hotkey**,
downloads the 306 GiB checkpoint, starts the worker and waits until the platform accepts
it. It finds the wallet that holds the hotkey and copies only the hotkey file; the
coldkey is never needed. Re-running it resumes where it stopped. As root, drop the `sudo`.

Unattended (cloud-init, a pod start command), answer the prompts in the environment:

```bash
curl -fsSL https://raw.githubusercontent.com/Subnet46/sn46-miner-releases/main/install.sh | sudo env SN46_SETUP_UID=12 SN46_SETUP_HOTKEY=5F… bash
```

It works in two places:

| Where | What it sets up |
|---|---|
| A plain Ubuntu 24.04 host with systemd (a DigitalOcean GPU droplet, bare metal) | a hardened `sn46-miner.service` that restarts after a reboot |
| A GPU container without systemd (RunPod) | a supervised worker with everything on the volume (`/workspace/sn46`) |

On RunPod only the volume survives a pod restart. After a restart, run the install
command again: it finds the configuration, the release and the checkpoint on the volume,
asks nothing, downloads nothing and starts the worker.

## Requirements

- Ubuntu 24.04 on x86-64, NVIDIA driver 580 or newer, `python3`, the clock in sync.
- GPUs of one supported class, on one host (see below).
- 360 GiB free on the install volume for a fresh install: the checkpoint, the release and
  working space. About 330 GiB stay in use afterwards.
- A hotkey registered on the subnet, as an unencrypted btcli hotkey file on the machine.
- Outbound HTTPS. No inbound ports.

### GPUs

| GPU class | Cards used | Context served | Status |
|---|---|---|---|
| RTX PRO 6000 Blackwell, 96 GB | 4 | 131,072 tokens | Qualified |
| B300, 288 GB | 2 | 131,072 tokens | Qualified |
| H200, 141 GB | 4 | 32,768 tokens | Qualified |

### Minimal setup

- The cards of one class from the table above, Ubuntu 24.04 with CUDA 13.
- 450 GB of disk that keeps file permissions. On RunPod, a 450 GB container disk and
  `SN46_ROOT=/sn46`; the installer refuses a volume that ignores permissions.
- The hotkey on the machine before installing, under `~/.bittensor/wallets`.

## Day to day

| Command | What it does |
|---|---|
| `sudo sn46-miner status` | phase, readiness, requests served and failed |
| `sudo sn46-miner logs -f` | follow the worker log |
| `sudo sn46-miner doctor` | every check the worker needs, with a fix for each failure |
| `sudo sn46-miner stats --period 24h` | local counters over a period |
| `sudo sn46-miner stop` / `start` / `restart` | control the worker |
| `sudo sn46-miner update check` | is a newer release published? Never installs anything |
| run the install command again | installs a newer release; the previous one stays for `rollback` |
| `sudo sn46-miner rollback` | go back to the previous release |
| `sudo sn46-miner configure` | change the uid or hotkey and restart the worker |
| `sudo sn46-miner diagnostics > bundle.json` | a redacted bundle for a support request |
| `sudo sn46-miner uninstall --confirm` | remove the release and the service; the checkpoint stays |

`--json` gives machine output for `status`, `doctor`, `host-check`, `stats` and
`update check`.

## When something fails

Every failure names what to do. The cases we have met:

| Symptom | Fix |
|---|---|
| `gpu` fails though `nvidia-smi` works (`cuInit` error 999) | The host is faulty. Replace it. |
| The installer refuses the GPUs | Use a supported class from the GPU table, with the number of cards it lists. |
| `disk` fails | Free space, or attach a larger volume and set `SN46_ROOT` to a directory on it. |
| A download stopped | Run the installer again. What is verified is kept and the rest resumes. |
| The installer cannot find the hotkey | Set `SN46_SETUP_HOTKEY_PATH` to the hotkey file and run it again. |
| `wallet_hotkey` fails | Copy an unencrypted hotkey file to the machine and run `sudo sn46-miner configure`. |
| `clock` fails | Run `sudo timedatectl set-ntp true`. |
