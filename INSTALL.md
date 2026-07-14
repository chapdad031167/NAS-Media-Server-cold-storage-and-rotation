# Installing on a Synology NAS

A step-by-step walkthrough for DSM. The commands are copy-paste friendly —
do the parts in order. Nothing here touches your media until you explicitly
pass `--run` to a script, and every destructive step defaults to a dry run.

Other NASes (QNAP, TrueNAS, unRAID) and generic Linux work the same way; only
the paths differ. See the [compatibility notes](README.md#compatibility).

---

## Part 1 — One-time prep

**1. Enable SSH.** DSM → **Control Panel** → **Terminal & SNMP** → check
**Enable SSH service** → **Apply**.

**2. Connect from your computer:**

```bash
ssh YOUR_DSM_ADMIN@YOUR_NAS_IP
```

(Add `-p PORT` if you moved SSH off port 22.)

**3. Download the tooling** (no Git required):

```bash
mkdir -p /volume1/docker/scripts
cd /volume1/docker/scripts
wget https://github.com/chapdad031167/NAS-Media-Server-cold-storage-and-rotation/archive/refs/heads/main.tar.gz
tar xzf main.tar.gz
mv NAS-Media-Server-cold-storage-and-rotation-main nas-media-automation
cd nas-media-automation
rm ../main.tar.gz
```

You are now in `/volume1/docker/scripts/nas-media-automation`.

---

## Part 2 — Run the installer

```bash
bash install.sh
```

It checks prerequisites, creates a mode-`600` `config.env` (it holds your API
keys), and walks you through the core settings. Have these ready:

| Prompt | What to enter |
|---|---|
| `MOVIES_DIR` | Movie library path, e.g. `/volume1/Movies` |
| `TV_DIR` | TV path, e.g. `/volume1/TV Shows` |
| `COLD_ROOT` | **⚠️ the #1 gotcha — see below.** Your USB mount + `/Cold` |
| `RADARR_URL` | `http://localhost:7878` (or your NAS IP:port) |
| `RADARR_API_KEY` | Radarr → Settings → General → **API Key** |
| `SONARR_URL` | `http://localhost:8989` |
| `SONARR_API_KEY` | Sonarr → Settings → General → **API Key** |

### ⚠️ Getting COLD_ROOT right (the common mistake)

`COLD_ROOT` is where aged media is archived — your USB drive. Synology does
**not** mount USB drives at a tidy `/mnt/usb`; the real path looks like
`/mnt/@usb/sde1` or `/volumeUSB1/usbshare`. Find yours **with the drive
plugged in**:

```bash
df -h | grep -i usb
```

Take the mount path from that output and append `/Cold`, for example:

```
/mnt/@usb/sde1/Cold
```

If you leave `COLD_ROOT` blank at the prompt, that's fine — the doctor will
flag it and you can set it later by editing `config.env`. What you should
**not** do is invent a path like `/mnt/usb/Cold`: the scripts will refuse to
run (clearly) until the path actually exists.

---

## Part 3 — Verify before touching anything

```bash
bash install.sh --doctor
```

This live-tests your config: library paths exist, the USB drive is mounted,
and Radarr/Sonarr actually answer with your keys. Aim for all `[ OK ]`.
`[WARN]` on Tautulli/qBittorrent is fine — those are optional. If `COLD_ROOT`
or an *arr* service warns, fix it in `config.env` (`nano config.env`) and
re-run the doctor.

Then the read-only scan — it only reads the APIs and writes a candidate list,
moving nothing:

```bash
python3 scripts/cold_storage_scan.py
```

Review the summary: does the candidate count and the protected/kids/skipped
breakdown match your instincts?

---

## Part 4 — Supervised first live run

Do these one at a time, reading each **dry run** before its `--run`.

```bash
# Cold storage: dry run, then live (USB plugged in)
bash scripts/cold_storage_cycle.sh
bash scripts/cold_storage_cycle.sh --run

# Prove the round trip
bash scripts/cold_storage_restore.sh                    # list what's archived
bash scripts/cold_storage_restore.sh "some title" --run # bring one back

# Library cleanup (same dry-run-first rule)
bash scripts/duplicate_cleanup.sh          # then --run
bash scripts/torrent_cleanup.sh            # then --run
```

For your first live cycle, pick a scan with only a few expendable candidates
and watch it. Every move is rsync-copied, checksum-verified, and only then
deleted from the source; a failed verify keeps the source untouched.

---

## Part 5 — Schedule the scan (DSM-safe)

Use **Task Scheduler**, not `crontab` — DSM can overwrite `/etc/crontab` on
updates.

DSM → **Control Panel** → **Task Scheduler** → **Create** → **Scheduled
Task** → **User-defined script**:

- **General:** run as the user that owns your media
- **Schedule:** weekly, e.g. Sunday 03:00
- **Task Settings → Run command:**

```bash
python3 /volume1/docker/scripts/nas-media-automation/scripts/cold_storage_scan.py
```

Leave the destructive `--run` steps manual — reading the dry-run report first
is the whole safety model.

---

## Troubleshooting

Run `bash install.sh --doctor` first — it catches most problems.

| Symptom | Fix |
|---|---|
| `cold drive has 0.00 GB free` / `mkdir … Permission denied` | `COLD_ROOT` points at a path that doesn't exist. Run `df -h \| grep -i usb`, set `COLD_ROOT` to the real mount + `/Cold`. |
| `Cold storage mount not found` | Same cause — the archive drive isn't mounted, or `COLD_ROOT` is wrong. Plug the drive in / fix the path. |
| Radarr/Sonarr `NOT reachable` | Check the URL, port, and API key in `config.env`; confirm the service is up from the NAS itself. |
| `flock` missing | Ships with util-linux; on a bare DSM install it via [Entware](https://github.com/Entware/Entware) (`opkg install util-linux`). Only the concurrent-run lock is affected. |
| Can't write to `COLD_ROOT` | The USB share is owned by root. Create a shared folder on it via **Control Panel → Shared Folder** with read/write for your user, or run the scripts as a user that owns the mount. |

For anything else, open an issue with your `--doctor` output (redact API
keys — see the issue template).
