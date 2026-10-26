# SN46 miner

Serves GLM-5.3-Flash-Uncensored (the EXL3 checkpoint, served as `orcarouter/GLM-5.3-Flash-Uncensored-FP8`) on Subnet 46 with TensorFold, and produces the token evidence the network verifies.
One machine, one class of GPU, one command to install.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Subnet46/sn46-miner-releases/main/install.sh | sudo bash
```

The installer checks the machine, downloads the current release and verifies it against
the signing key built into the installer, asks for your **miner uid** and **hotkey**,
downloads the 164 GiB checkpoint, starts the worker and waits until the platform accepts
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
- Four RTX PRO 6000 Blackwell cards on one host, with CUDA peer access between every pair
  (see below).
- 220 GiB free on the install volume for a fresh install: the checkpoint, the release and
  working space. About 200 GiB stay in use afterwards.
- A hotkey registered on the subnet, as an unencrypted btcli hotkey file on the machine.
- Outbound HTTPS. No inbound ports.

### GPUs

| GPU class | Cards used | Context served | Status |
|---|---|---|---|
| RTX PRO 6000 Blackwell (Workstation, Server or Max-Q), 96 GB | 4 | 131,072 tokens | Qualified |

Other cards are refused: the token check compares the miner's numbers with a verifier's bit
for bit, and only this class reproduces them.

### Card-to-card exchange and the speed floor

The engine exchanges each layer's partial results between the four cards directly over
PCIe, so it needs CUDA peer access between every pair: `sudo sn46-miner doctor` reports it
as `gpu_p2p`, and `nvidia-smi topo -m` shows the links. A host whose cards cannot reach each
other (PCIe ACS, a virtualised layout) is refused at install, with the pair named. At every
start the engine times each way of exchanging (direct stores, copy engines, NCCL) at the
sizes decoding uses and keeps the fastest per size; the start log and the doctor show the
choice. The worker then measures the host (decode speed on a short and a 10k-token prompt,
time to the first token) and the platform admits it only at 240 tokens per second or more
with the first token within 1.5 s; `sudo sn46-miner qualify` repeats the measurement.

### Minimal setup

- Four RTX PRO 6000 cards with peer access, Ubuntu 24.04 with CUDA 13.
- 300 GB of disk that keeps file permissions. On RunPod, a 300 GB container disk and
  `SN46_ROOT=/sn46`; the installer refuses a volume that ignores permissions.
- The hotkey on the machine before installing, under `~/.bittensor/wallets`.

## Day to day

| Command | What it does |
|---|---|
| `sudo sn46-miner status` | phase, readiness, requests served and failed |
| `sudo sn46-miner logs -f` | follow the worker log |
| `sudo sn46-miner doctor` | every check the worker needs, with a fix for each failure |
| `sudo sn46-miner qualify` | measure the host again: decode speed, time to the first token, the exchange chosen |
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
   reused, so most updates download megabytes, not gigabytes; a release with a new
   runtime, like the one that moved to TensorFold, downloads about 5 GB once and needs
   60 GiB free, and its first start builds the engine's kernels for a few minutes);
2. drains the worker: the platform stops sending it requests, and it finishes the ones it
   has. Nothing in flight is cut off; if a request does not finish within 30 minutes the
   worker takes work again and the update is retried later;
3. switches to the new release, starts it, and waits until the platform accepts it. If it
   does not, the previous release comes back, that release is not tried again on this
   host, and a fault report says why.

Only a release signed with this installation's key and newer than the running one is
installed. When the disk is too full, the update does not happen and `sudo sn46-miner
status` says so. Releases other than the current and the previous one are removed.

### A release that changes the model

A release built for another checkpoint (the EXL3 checkpoint after the FP8 one) is applied by the updater like any other, with the checkpoint
taken care of. Ahead of the release's time (`SN46_UPDATE_PREPARE_AHEAD_S`, 12 h by default, at
most 24 h) the updater downloads the new checkpoint while the worker keeps serving the old
one; `sn46-miner status` shows `prepared`. At the time, the worker drains, the configuration
switches to the new profile and model path, and the worker restarts on the new release.
The old checkpoint is kept beside the new one when the volume has room for both (the new
checkpoint plus 20 GiB free), so a rollback can still serve it; otherwise it is removed before the download.
A host that cannot hold even one more checkpoint is reported `blocked` and left alone.

This needs the updater of 0.6.1 or later; a 0.6.0 host rolls such a release back and
`status` says so. Run the install command once instead: it does the same change at once.
The retired checkpoint is removed when the host cannot hold both, the configuration moves
to the new profile (the file before is kept as `worker.env.retired`, every other setting
stays), the checkpoint downloads while the worker keeps serving, and the worker restarts
on the new release at the end.

Settings in `/etc/sn46-miner/worker.env` (restart not needed; the next check reads them):

| Setting | Default | Meaning |
|---|---|---|
| `SN46_AUTO_UPDATE` | `true` | `false` turns automatic updates off |
| `SN46_UPDATE_PREPARE_AHEAD_S` | `43200` | how long before a release's time a model change's checkpoint is downloaded (at most 86400) |
| `SN46_UPDATE_WINDOW` | none | only update inside this daily UTC window, e.g. `02:00-05:00` |
| `SN46_UPDATE_SPREAD_S` | `7200` | this host installs at a fixed offset of up to this many seconds after a release's time |
| `SN46_UPDATE_DRAIN_S` | `1800` | how long to wait for open requests before retrying later |

`journalctl --namespace=sn46-miner -u sn46-miner-update` (or `/var/log/sn46-miner/update.log` in a container)
shows every decision.

## Fault reports

When the miner hits a fault (a session ends, the backend is restarted, a request or a
proof fails, the installation is broken, an update rolls back), it sends a short report to the platform,
signed by its hotkey, so the subnet sees what failed without asking you for logs. It
never waits on the report and never retries it; at most one report of a kind goes out
every 10 minutes, and 24 a day.

A report holds the release, uid and hotkey; the fault's kind and tier with a static error
code; the request id; numeric worker status; the service's state and restart count; GPU
metadata; the last 20 unexpired request records; and configuration key names. Raw worker
and backend log lines are never attached.

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
| `host fault swap_charge` in the log (the miner exits 75 and is retried every minute) | Processes that are gone left swapped memory charged to the container's cgroup, so the miner cannot show it will not swap. It starts once the charge drains; restarting the container clears it at once. |
| The miner refuses to start: `cannot resolve own cgroup-v2 mount` or `active host swap is not blocked` | The host has swap and no cgroup v2 limit on it (a cgroup v1 container host, or swap not disabled for the container). Use a host without swap, or one whose container runtime sets the swap limit to 0 on cgroup v2. |
| `Request failed; the session goes on` | Nothing. The model's answer broke the output contract (it sampled a control or multimodal token, or the stream did not match its decoding). That one request fails and the miner keeps serving. Tool calls and boxed answers are ordinary text and never cause this. |

## Retention

After generation finishes, a fixed 600-second monotonic deadline bounds both waiting for
`proof_start` and proof production. Progress does not renew it. Expiry cancels the task
and releases its GPU capture; it does not send a fabricated failed proof. A disconnect
also drains outstanding tasks and captures.

Statistics and the last per-request status fields expire within 30 days, including on
idle hosts and before startup. The managed unit uses a separate journal namespace kept
for three days (`journalctl --namespace=sn46-miner -u sn46-miner`). Container log rotations
expire after three days and the active file is truncated daily. Serving refuses unsafe
swap or dump protection; managed engines enforce the same protection after exec.

These safeguards cover the supported software. A miner operator can still inspect
plaintext while it is processed; this release does not attest an independent host or
promise forensic RAM/VRAM erasure.
