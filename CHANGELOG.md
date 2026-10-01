# Changelog

All notable changes to this project are documented here.

## v1.8.18 - 2026-10-01

- Beginner-friendly recovery after a reboot, crash, or failed upload: the menu shows a **What now?** box under the status lines that says in plain words what happened and which option to choose.
- An unfinished upload is remembered in the persistent state directory, so it is still known after a reboot (the status in `$XDG_RUNTIME_DIR` is wiped on reboot). Option 1 then reads **Resume interrupted upload** and uploads the same file again; Borg only transfers what is not in the repository yet.
- If a newer Panzerbackup image appeared in the meantime, option 1 asks whether to resume the old upload (faster) or upload the newer file (starts over). If the file is not reachable, the box asks to connect and mount the backup disk first.
- A reboot during the cleanup after a successful upload says "Your backup is completely stored – nothing to do", also when the worker was stopped by SIGTERM during shutdown.
- Fixed: starting the script with `bash borgbase_manager.sh` without the executable bit started no background job ("Permission denied"). The script now re-runs itself through bash, and the systemd service does the same. The repository now stores the script as executable.
- Option 7 (Clear status) also removes the unfinished-upload hint.
- README: new troubleshooting section "PC Rebooted or Shut Down During an Upload".

## v1.8.17 - 2026-10-01

- A reboot during the cleanup after a successful upload no longer reports "UPLOAD: INTERRUPTED". The archive is already committed at that point, so the status now reads "✓ UPLOAD: Finished (cleanup interrupted – will be redone on next run)", and the next upload runs prune/compact again.
- A really interrupted upload now says that Borg resumes from its last checkpoint when it is started again.

## v1.8.16 - 2026-09-23

- Fault tolerance after reboot, crash, or kill: the worker PID file now stores the boot ID and process start time, so a leftover or reused PID is no longer mistaken for a running job. This matters under `sudo`, where the status lives in `/root/.cache` and survives a reboot.
- A status that still says "running" without a live worker is replaced with "INTERRUPTED (reboot/abort) – please start again". Borg resumes from its last checkpoint on the next upload.
- The worker traps SIGTERM, SIGHUP, and SIGINT and never leaves a "running" status behind. Status files are written atomically.
- Live progress shows the last status and distinguishes "job finished" from "no job running". "Clear status" reports when a job is still running.

## v1.8.15 - 2026-09-05

- Recognizes the single-file `.pzb` container that Panzerbackup 3.x writes in Proxmox disaster recovery mode (`panzer_<name>_<date>.pzb`), so auto-detection, hostname extraction, and upload find it again next to the existing RAW `*.img.zst[.gpg]` images.
- The upload adds the matching `.pzb.sha256` and the `LATEST_OK` links; a `.sfdisk` sidecar is no longer expected for `.pzb`, because the partition table lives inside the container.
- Messages about a missing backup file now name both artifact types.

## v1.8.14 - 2026-08-22

- Auto-detection now accepts any directory whose name contains "panzerbackup" in any spelling, for example `Panzerbackup-OAI` or `PANZERBACKUP_2`.
- Added `/mnt`, `/srv`, and `/data` to the search paths and additionally scans every mounted filesystem whose mountpoint carries the name, so volumes mounted outside `/media` and `/run/media` are found.
- A matching directory without image files is now used as a fallback instead of aborting with "no Panzerbackup directory found".
- Image detection, hostname extraction, and upload file selection now match case-insensitively and also accept unencrypted `*.img.zst` images.
- Checksum and partition-table files are only added to the upload when they exist.

## v1.8.13 - 2026-06-05

- Run Borg create, prune, and compact with optional lower CPU and IO priority to keep Linux desktops responsive during long uploads.
- Lowered the SSH keepalive interval for faster disconnect detection during BorgBase uploads.
- Added automatic retry handling for SSH disconnects so Borg can resume from checkpoints.
- Documented the new upload retry and desktop resource-limiting settings.

## v1.8.12 - 2026-05-26

- Added SSH keepalive defaults for long BorgBase uploads.
- Added broken-pipe diagnostics that identify SSH disconnects as connection issues rather than root/permission failures.
- Extended Linux desktop sleep inhibition to block sleep, idle, and lid-switch suspend during worker operations, with fallback for older systemd versions.
- Documented long-upload and sleep-inhibition settings in the README.

## v1.8.10 - 2026-05-24

- Added a dedicated changelog for release tracking.
- Documented the current project version in the README.
- Kept the script header and runtime version in sync.

## v1.8.9

- Uses `BORG_PASSCOMMAND` to avoid passphrase exposure through environment variables.
- Runs prune and compact before archive creation to free repository space first.
- Adds separate retention for Panzerbackup and data archives.
- Improves SSH key detection, repository preflight checks, and lock handling.
