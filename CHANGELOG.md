# Changelog

All notable changes to this project are documented here.

## v1.8.10 - 2026-05-24

- Added a dedicated changelog for release tracking.
- Documented the current project version in the README.
- Kept the script header and runtime version in sync.

## v1.8.9

- Uses `BORG_PASSCOMMAND` to avoid passphrase exposure through environment variables.
- Runs prune and compact before archive creation to free repository space first.
- Adds separate retention for Panzerbackup and data archives.
- Improves SSH key detection, repository preflight checks, and lock handling.
