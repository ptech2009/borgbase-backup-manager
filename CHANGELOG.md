# Changelog

All notable changes to this project are documented here.

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
