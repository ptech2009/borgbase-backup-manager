# Changelog

All notable changes to this project are documented here.

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
