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
| `sudo sn46-miner update auto --now` | install a newer release now instead of on schedule |
| run the install command again | installs a newer release; the previous one stays for `rollback` |
| `sudo sn46-miner rollback` | go back to the previous release |
| `sudo sn46-miner configure` | change the uid or hotkey and restart the worker |
| `sudo sn46-miner diagnostics > bundle.json` | a redacted bundle for a support request |
| `sudo sn46-miner report --dry-run` | print the fault report this miner would send |
| `sudo sn46-miner uninstall --confirm` | remove the release and the service; the checkpoint stays |

`--json` gives machine output for `status`, `doctor`, `host-check`, `stats` and
`update check`.

## Updates

The miner updates itself. Every 15 minutes a timer (`sn46-miner-update.timer`; in a
container, a small loop the installer starts) checks the signed release index. When a
newer release is published and its time has come, the updater:

1. downloads and verifies it while the worker keeps serving (an unchanged runtime is
   reused, so most updates download megabytes, not gigabytes);
2. drains the worker: the platform stops sending it requests, and it finishes the ones it
   has. Nothing in flight is cut off; if a request does not finish within 30 minutes the
   worker takes work again and the update is retried later;
3. switches to the new release, starts it, and waits until the platform accepts it. If it
   does not, the previous release comes back, that release is not tried again on this
   host, and a fault report says why.

Only a release signed with this installation's key and newer than the running one is
installed. When the disk is too full, the update does not happen and `sudo sn46-miner
status` says so. Releases other than the current and the previous one are removed.

Settings in `/etc/sn46-miner/worker.env` (restart not needed; the next check reads them):

| Setting | Default | Meaning |
|---|---|---|
| `SN46_AUTO_UPDATE` | `true` | `false` turns automatic updates off |
| `SN46_UPDATE_WINDOW` | none | only update inside this daily UTC window, e.g. `02:00-05:00` |
| `SN46_UPDATE_SPREAD_S` | `7200` | this host installs at a fixed offset of up to this many seconds after a release's time |
| `SN46_UPDATE_DRAIN_S` | `1800` | how long to wait for open requests before retrying later |

`journalctl -u sn46-miner-update` (or `/var/log/sn46-miner/update.log` in a container)
shows every decision.

## Fault reports

When the miner hits a fault (a session ends, the backend is restarted, a request or a
proof fails, the installation is broken, an update rolls back), it sends a short report to the platform,
signed by its hotkey, so the subnet sees what failed without asking you for logs. It
never waits on the report and never retries it; at most one report of a kind goes out
every 10 minutes, and 24 a day.

A report holds: the release, uid and hotkey; the fault's kind, tier and error text; the
request id it concerns; `status.json`; the service's state and restart count; the GPUs
as `nvidia-smi` lists them; the last 20 request records (token counts, timings and
outcomes); the names of the configuration keys; and the last 400 log lines of the worker
(at `info` and above) and of the backend.

It never holds configuration values, wallet files or keys, prompts, answers, token ids,
the verification nonce or proof bytes. The websocket and HTTP libraries stay at `info`
whatever `SN46_LOG_LEVEL` says, because their `trace` output is the raw frames.

`sudo sn46-miner report --dry-run` prints exactly what a report would hold right now.
To turn reports off, add `SN46_FAULT_REPORTS=false` to
`/etc/sn46-miner/worker.env` and restart the worker.

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
| `Request failed; the session goes on` | Nothing. The model's answer broke the output contract (it sampled a control or multimodal token, or the stream did not match its decoding). That one request fails and the miner keeps serving. Tool calls and boxed answers are ordinary text and never cause this. |
