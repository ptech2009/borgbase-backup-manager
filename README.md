# BorgBase Backup Manager

A secure, production-ready backup management tool for uploading and downloading Panzerbackup artifacts to/from BorgBase repositories using BorgBackup.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![BorgBackup](https://img.shields.io/badge/BorgBackup-1.2%2B-blue.svg)](https://www.borgbackup.org/)

## 🌟 Features

- **🧙 Interactive Configuration Wizard**: First-run wizard with connection validation and secure credential storage
- **🌐 Forced Language Selection**: Language prompt on every interactive launch for consistent UX
- **🔒 Security First**: Per-user config, secure passphrase storage, SSH key authentication
- **🔑 Smart SSH Key Auto-Detection**: Multi-level discovery from SSH config, standard locations, and custom hints
- **🛡️ Hard Preflight Gating**: Upload/Download blocked until repository connection is verified
- **⚠️ Intelligent Lock Handling**: Repository locks treated as warnings (OK if own job running)
- **📊 Startup Status Check**: Automatic repo connection test on every launch
- **📺 Live Progress Viewer**: Real-time log following with readable output formatting
- **🎯 Smart Auto-Detection**: Automatically finds Panzerbackup volumes across multiple mount points
- **🖥️ Interactive TUI**: User-friendly menu-driven interface with color-coded status display
- **⚙️ CLI Support**: Direct command-line operations for automation
- **🧹 Automatic Pruning**: Configurable retention policies with compact operation
- **📝 Comprehensive Logging**: Detailed operation logs with worker boundaries
- **🔄 Automated Workflows**: systemd-friendly for scheduled backups

## 📋 Prerequisites

- **BorgBackup** 1.2 or higher
- **Bash** 4.0 or higher
- **SSH** access to BorgBase repository
- **Panzerbackup** artifacts (`.img.zst.gpg` files)
- **Optional**: `findmnt`, `ssh-keygen`, `ssh-keyscan`, `stdbuf` for enhanced features

## 🚀 Quick Start

### 1. Clone and Setup

```bash
# Clone the repository
git clone https://github.com/yourusername/borgbase-backup-manager.git
cd borgbase-backup-manager

# Make the script executable
chmod +x borgbase_manager.sh

# Optional: Install to system path
sudo cp borgbase_manager.sh /usr/local/bin/borgbase-manager
sudo chmod +x /usr/local/bin/borgbase-manager
```

### 2. First Run - Configuration Wizard

Simply run the script - the wizard will guide you through setup:

```bash
./borgbase_manager.sh
```

**You will be prompted for:**

1. **Language Selection** (Deutsch/English) - shown on **every** interactive start
2. **BorgBase Repository URL** (format: `ssh://user@host[:port]/./repo`)
3. **Source Directory** (auto-detection or manual path)
4. **Preferred SSH Key Hint** (optional, e.g., "newvorta" or "borgbase")
5. **SSH Key Path** (auto-detection or manual path)
6. **Known Hosts Path** (default: `~/.ssh/known_hosts`)
7. **Repository Passphrase File Path** (will be created securely)
8. **SSH Key Passphrase File Path** (optional for encrypted SSH keys)
9. **Repository Passphrase** (entered twice for confirmation, stored securely)
10. **Connection Test** (validates all settings before saving)

**All credentials are stored securely in per-user config files with proper permissions (chmod 600).**

### 3. Configuration Files

After wizard completion, config is stored in:

```
~/.config/borgbase-backup-manager/
├── borgbase-manager.env        # Main configuration (chmod 600)
├── borg_passphrase             # Repository passphrase (chmod 600)
└── sshkey_passphrase           # Optional SSH key passphrase (chmod 600)

~/.local/state/borgbase-backup-manager/
└── borgbase-manager.log        # Operation log

~/.cache/borgbase-backup-manager/  (or /run/user/<uid>/)
├── borgbase-status             # Current status
└── borgbase-worker.pid         # Running job PID
```

### 4. Run

```bash
# Interactive mode (language selector appears first)
./borgbase_manager.sh

# CLI mode (non-interactive, uses saved language)
./borgbase_manager.sh upload
./borgbase_manager.sh download
./borgbase_manager.sh list
./borgbase_manager.sh test        # Test connection
./borgbase_manager.sh config      # Re-run wizard
```

## 📖 Usage

### Interactive Menu

Run the script without arguments to access the interactive menu:

```bash
./borgbase_manager.sh
```

**On every interactive launch:**
1. Language selector appears (default: last saved language)
2. Configuration loaded (if exists)
3. Repository connection tested (silent)
4. Main menu displayed with current status

**Menu Options:**

1. **Upload** - Upload latest local backup to BorgBase (requires valid connection)
2. **Download** - Download and restore a backup from BorgBase (requires valid connection)
3. **List** - Show all available archives (requires valid connection)
4. **Test Connection** - Verify repository connection (SSH + Borg)
5. **View Log** - Display log file in pager (`less`)
6. **Show Settings** - Display current configuration (shows if passphrase/key files exist)
7. **Clear Status** - Reset status file
8. **Reconfigure (Wizard)** - Re-run configuration wizard
9. **Live Progress** - Follow log in real-time with readable formatting (NEW!)
10. **Quit** - Exit the manager

### Command-Line Interface

```bash
# Interactive menu (with language selector)
./borgbase_manager.sh menu

# Run configuration wizard
./borgbase_manager.sh config

# Test repository connection
./borgbase_manager.sh test

# Upload latest backup
./borgbase_manager.sh upload

# Download specific archive (interactive selection)
./borgbase_manager.sh download

# List all archives
./borgbase_manager.sh list

# View current status
./borgbase_manager.sh status
```

## 🔐 Security Architecture

### Per-User Configuration

All configuration is stored in **user-specific directories** following XDG Base Directory Specification:

- **Config**: `~/.config/borgbase-backup-manager/`
- **State/Logs**: `~/.local/state/borgbase-backup-manager/`
- **Runtime**: `${XDG_RUNTIME_DIR}` or `~/.cache/borgbase-backup-manager/`

**No system-wide config required - each user has isolated settings.**

### Credential Storage

**Repository Passphrase:**
- Stored in `borg_passphrase` file (chmod 600)
- **Never** stored directly in env file
- Loaded at runtime via `BORG_PASSPHRASE` environment variable
- Wizard validates passphrase by testing connection

**SSH Key Passphrase (Optional):**
- Stored in `sshkey_passphrase` file (chmod 600)
- Only needed for encrypted SSH keys in non-interactive mode
- Can use SSH agent as alternative

**Path Validation:**
- Wizard enforces absolute paths for passphrase files
- Prevents accidental storage of secrets as config values
- Invalid relative paths automatically corrected to defaults

### Connection Gating

**Hard Preflight Requirements:**
- Upload/Download/List operations **blocked** until repo connection succeeds
- Connection test validates:
  1. SSH authentication (key + known_hosts)
  2. Repository access (`borg info`)
  3. Passphrase correctness
- Wizard loops until all validation passes
- Status updated on every script launch

**Intelligent Lock Handling:**
- **Repository locked** → Treated as **WARNING** (not ERROR)
- If own job is running → Status: `OK: Repo erreichbar (BUSY/Lock durch laufenden Job)`
- If no job running → Status: `WARNUNG: Repo gesperrt (Lock-Timeout) – später erneut versuchen`
- Operations still allowed (Borg will wait for lock based on `BORG_LOCK_WAIT`)

## 🔑 SSH Key Auto-Detection

### Detection Strategy

**Multi-Level Search (in priority order):**

1. **Explicit Configuration**
   - If `SSH_KEY` is set in env file and readable → use immediately
   
2. **SSH Config Files** (`~/.ssh/config`)
   - Parse `IdentityFile` directives
   - Match keys containing `PREFERRED_KEY_HINT` (if set)
   - Prefer Ed25519 keys
   
3. **Standard Key Locations** (`~/.ssh/`)
   - Search for keys matching `PREFERRED_KEY_HINT` (if set)
   - Standard key names: `id_ed25519*`, `id_rsa`, `id_ecdsa`, `id_dsa`
   - Prefer Ed25519 keys
   - First readable key is selected

**Simplified Detection:**
- Only searches **current user's** directories
- No system-wide scanning (no `/root/`, no `/home/*` when running as root)
- Faster and more predictable

### Key Preferences

**Selection Priority:**
1. Keys matching `PREFERRED_KEY_HINT` (if set)
2. Ed25519 keys (`id_ed25519*`)
3. RSA keys (`id_rsa`)
4. ECDSA keys (`id_ecdsa`)
5. DSA keys (`id_dsa`)

### Configuration Examples

**Auto-Detection with Hint (Recommended):**
```bash
# Leave SSH_KEY empty in wizard
SSH_KEY=""

# Set hint to prefer specific key
PREFERRED_KEY_HINT="borgbase"  # Matches id_ed25519_borgbase or id_rsa_borgbase
```

**Auto-Detection without Hint:**
```bash
SSH_KEY=""
PREFERRED_KEY_HINT=""  # Will use first Ed25519 key found
```

**Explicit Key:**
```bash
SSH_KEY="/home/user/.ssh/id_ed25519_borgbase"
PREFERRED_KEY_HINT=""  # Hint ignored when SSH_KEY is set
```

**SSH Config Integration:**
```ssh-config
# ~/.ssh/config
Host *.repo.borgbase.com
    IdentityFile ~/.ssh/id_ed25519_borgbase
    IdentitiesOnly yes
    StrictHostKeyChecking yes
```

The script will parse this config and auto-detect `id_ed25519_borgbase`.

## 🎯 Auto-Detection Features

### Backup Directory Detection

Automatic search for Panzerbackup volumes:

**Search Locations:**
- `/mnt/*panzerbackup*` (case-insensitive)
- `/media/*/*panzerbackup*`
- `/run/media/*/*panzerbackup*`
- Any mounted filesystem via `findmnt` (case-insensitive grep)

**Selection Logic:**
- Only directories with valid `panzer_*.img.zst.gpg` files
- If multiple found → newest backup wins (based on file mtime)
- Search depth: up to 4 levels

**Manual Override:**
- If auto-detection fails, wizard prompts for manual path
- Validates path contains valid `panzer_*.img.zst.gpg` files
- Can specify custom path at any time

### Upload Candidate Display

Before upload, script shows **exact details**:

```
Geplantes Upload-Set (NEUESTES Backup):
  SRC_DIR : /mnt/panzerbackup-pm
  IMG     : panzer_2025-01-28_14-30-00.img.zst.gpg
  Datum   : 2025-01-28 14:30:00
  Größe   : 245.67 GiB (263742619648 Bytes)
  SHA     : panzer_2025-01-28_14-30-00.img.zst.gpg.sha256
  SFDISK  : panzer_2025-01-28_14-30-00.sfdisk
```

**Includes:**
- Source directory path
- Image filename
- Modification timestamp
- Human-readable size + exact bytes
- Companion files (SHA256, sfdisk)

## 🌐 Repository URL Format

### Supported Formats

**Standard (Port 22):**
```bash
REPO="ssh://user@user.repo.borgbase.com/./repo"
```

**Custom Port:**
```bash
REPO="ssh://user@user.repo.borgbase.com:2222/./repo"
```

**Port Handling:**
- Script automatically detects port in URL
- SSH options include `-p <port>` when needed
- Known hosts format: `[host]:port` for non-standard ports

### Repository Validation

Wizard validates:
- Starts with `ssh://`
- Contains `user@host` format
- Optional `:port` supported
- Connection test verifies repository exists

## ⚙️ systemd Integration

### Create Service Unit

`/etc/systemd/system/borgbase-upload.service`:

```ini
[Unit]
Description=BorgBase Backup Upload
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Run as specific user (replace 'username')
User=username
Group=username

# Wizard-created config is per-user, no EnvironmentFile needed
ExecStart=/usr/local/bin/borgbase-manager upload

StandardOutput=journal
StandardError=journal

# Prevent interactive prompts in systemd
Environment="DEBIAN_FRONTEND=noninteractive"

[Install]
WantedBy=multi-user.target
```

### Create Timer Unit

`/etc/systemd/system/borgbase-upload.timer`:

```ini
[Unit]
Description=Daily BorgBase Backup Upload
Requires=borgbase-upload.service

[Timer]
OnCalendar=daily
OnCalendar=02:00
Persistent=true

[Install]
WantedBy=timers.target
```

### Enable and Start

```bash
# Reload systemd
sudo systemctl daemon-reload

# Enable and start timer
sudo systemctl enable borgbase-upload.timer
sudo systemctl start borgbase-upload.timer

# Check status
sudo systemctl status borgbase-upload.timer
sudo systemctl list-timers borgbase-upload.timer

# View logs
sudo journalctl -u borgbase-upload.service -f
```

**Note:** First-time setup requires interactive wizard. Run manually as the target user before enabling timer.

## 🔧 Configuration Reference

### Environment Variables

| Variable | Description | Default | Set by Wizard |
|----------|-------------|---------|---------------|
| `UI_LANG` | Interface language (de/en) | `de` | ✅ Yes |
| `REPO` | BorgBase repository URL (with optional :port) | - | ✅ Yes (validated) |
| `SRC_DIR` | Backup source directory | Auto-detect | ✅ Yes (optional) |
| `SSH_KEY` | Path to SSH private key | Auto-detect | ✅ Yes (optional) |
| `PREFERRED_KEY_HINT` | SSH key search hint (e.g., "borgbase") | - | ✅ Yes (optional) |
| `SSH_KNOWN_HOSTS` | Known hosts file path | `~/.ssh/known_hosts` | ✅ Yes |
| `PASSPHRASE_FILE` | Repo passphrase file | `~/.config/.../borg_passphrase` | ✅ Yes (validated) |
| `SSH_KEY_PASSPHRASE_FILE` | SSH key passphrase file | `~/.config/.../sshkey_passphrase` | ✅ Yes (optional) |
| `LOG_FILE` | Log file location | `~/.local/state/.../borgbase-manager.log` | ❌ No |
| `PRUNE` | Enable auto-pruning | `yes` | ❌ No |
| `KEEP_LAST` | Backups to retain | `1` | ❌ No |
| `SSH_CONNECT_TIMEOUT` | SSH timeout (seconds) | `10` | ❌ No |
| `BORG_LOCK_WAIT` | Borg lock wait (seconds) | `5` | ❌ No |
| `BORG_TEST_LOCK_WAIT` | Connection test lock wait | `1` | ❌ No |
| `AUTO_ACCEPT_HOSTKEY` | Auto-add SSH host keys | `no` | ❌ No |
| `AUTO_TEST_SSH` | Test SSH on setup | `yes` | ❌ No |
| `AUTO_TEST_REPO` | Test repo on setup | `yes` | ❌ No |

### Manual Configuration

Edit `~/.config/borgbase-backup-manager/borgbase-manager.env`:

```bash
# Language (prompted on every interactive start)
UI_LANG="en"

# Repository (REQUIRED - ssh://user@host[:port]/./repo)
REPO="ssh://myuser@myuser.repo.borgbase.com/./repo"

# Source (empty = auto-detect)
SRC_DIR=""

# SSH Key (empty = auto-detect)
SSH_KEY=""
PREFERRED_KEY_HINT="borgbase"  # Optional search hint

# Paths
SSH_KNOWN_HOSTS="/home/user/.ssh/known_hosts"
PASSPHRASE_FILE="/home/user/.config/borgbase-backup-manager/borg_passphrase"
SSH_KEY_PASSPHRASE_FILE="/home/user/.config/borgbase-backup-manager/sshkey_passphrase"

# Retention (KEEP_LAST=1 by default!)
PRUNE="yes"
KEEP_LAST="1"  # Only keep latest backup (change as needed)

# Timeouts
SSH_CONNECT_TIMEOUT="10"
BORG_LOCK_WAIT="5"
BORG_TEST_LOCK_WAIT="1"

# Auto-features
AUTO_ACCEPT_HOSTKEY="no"
AUTO_TEST_SSH="yes"
AUTO_TEST_REPO="yes"
```

**After manual edits, test connection:**
```bash
./borgbase_manager.sh test
```

## 🗂️ Backup Structure

The manager handles complete Panzerbackup sets:

```
/mnt/panzerbackup-pm/
├── panzer_YYYY-MM-DD_HH-MM-SS.img.zst.gpg      # Encrypted backup image
├── panzer_YYYY-MM-DD_HH-MM-SS.img.zst.gpg.sha256 # Checksum
├── panzer_YYYY-MM-DD_HH-MM-SS.sfdisk           # Partition table
├── LATEST_OK                                    # Latest successful backup link
├── LATEST_OK.sha256                            # Latest checksum link
├── LATEST_OK.sfdisk                            # Latest partition table link
└── panzerbackup.log                            # Backup log
```

### Archive Naming Convention

Archives are named: `Backup-<HOSTNAME>-<TIMESTAMP>`

Example: `Backup-myserver-2025-01-28_14-30`

## 📊 Monitoring

### Status Display

**Color-Coded Status:**
- 🔴 **Red**: Errors/failures (`FEHLER`, `ERROR`, `failed`)
- 🟢 **Green**: Success/ready (`OK`, `Abgeschlossen`, `Finished`)
- 🟡 **Yellow**: Running operations, warnings (`UPLOAD`, `DOWNLOAD`, `WARN`, `locked`, `BUSY`)

**Status Messages:**
- `OK: Verbindung erfolgreich hergestellt` - Connection validated
- `OK: Repo erreichbar (BUSY/Lock durch laufenden Job)` - Repo locked by own job
- `WARNUNG: Repo gesperrt (Lock-Timeout)` - Repo locked by other process
- `FEHLER: Repo-Passphrase fehlt` - Missing passphrase
- `FEHLER: SSH Auth fehlgeschlagen (publickey)` - SSH authentication failed
- `UPLOAD: Finished - Backup-host-2025-01-28_14-30 (Duration: 05m:23s)` - Completed

### Startup Status Check

**On every interactive script launch:**
1. Language selector appears
2. Configuration loaded (if exists)
3. Repository connection tested (silent, non-blocking)
4. Status set to `OK`, `WARNUNG`, or `FEHLER` with details
5. Main menu displayed with status in header

**Benefits:**
- Immediate feedback on config validity
- Early detection of connectivity issues
- Lock status visible before attempting operations
- No surprise failures when starting uploads

### Live Progress Viewer (NEW!)

**Menu Option 9: Live Progress (follow log)**

Real-time log following with enhanced readability:

**Features:**
- Converts carriage returns (`\r`) to newlines for proper display
- De-duplicates consecutive identical lines
- Uses `stdbuf` for line-buffering (if available)
- Non-blocking - exit with Ctrl+C
- Shows last 200 lines initially, then follows new entries

**Usage:**
```bash
# From menu
./borgbase_manager.sh
# Select option 9

# Or start a job and immediately follow
./borgbase_manager.sh upload &
tail -f ~/.local/state/borgbase-backup-manager/borgbase-manager.log
```

**Output Example:**
```
Live progress: following log (cleaned). Exit with Ctrl+C.
LOG_FILE: /home/user/.local/state/borgbase-backup-manager/borgbase-manager.log

==========================================
Worker Start (Upload): 2025-01-28 14:25:22
==========================================
UPLOAD: Finding latest backup...
UPLOAD: Creating archive Backup-myhost-2025-01-28_14-30...
UPLOAD: Upload in progress...
A /mnt/panzerbackup-pm/panzer_2025-01-28_14-30-00.img.zst.gpg
A /mnt/panzerbackup-pm/panzer_2025-01-28_14-30-00.img.zst.gpg.sha256
...
```

### Log Files

```bash
# View log in pager (menu option 5)
./borgbase_manager.sh
# Select option 5) View log

# Or directly with less
less ~/.local/state/borgbase-backup-manager/borgbase-manager.log

# Follow log in real-time (menu option 9)
./borgbase_manager.sh
# Select option 9) Live progress

# Tail log manually
tail -f ~/.local/state/borgbase-backup-manager/borgbase-manager.log

# Check systemd journal (if using systemd)
journalctl -u borgbase-upload.service -f
```

### Log Structure

```
==========================================
Worker Start (Upload): 2025-01-28 14:25:22
==========================================
ENV: HOME=/home/user USER=user LOGNAME=user
ENV: SSH_KEY=/home/user/.ssh/id_ed25519_borgbase
ENV: SSH_KNOWN_HOSTS=/home/user/.ssh/known_hosts
ENV: BORG_RSH=ssh -T -o RequestTTY=no ...
------------------------------------------
UPLOAD: Finding latest backup...
UPLOAD: Creating archive Backup-myhost-2025-01-28_14-30...
UPLOAD: Upload in progress...
[Borg progress output...]
UPLOAD: Pruning old archives...
UPLOAD: Compacting repository...
------------------------------------------
  SUCCESS SUMMARY
  Archive:  Backup-myhost-2025-01-28_14-30
  Duration: 05m:23s
  End:      2025-01-28 14:30:45
------------------------------------------
UPLOAD: Finished - Backup-myhost-2025-01-28_14-30 (Duration: 05m:23s)
==========================================
```

## 🛡️ Security Features

- ✅ **No hardcoded secrets** - all credentials in user-specific files
- ✅ **Per-user configuration** - isolated settings per system user
- ✅ **Secure credential storage** - chmod 600 on all sensitive files
- ✅ **Path validation** - wizard enforces absolute paths for passphrase files
- ✅ **Connection gating** - operations blocked until repo connection succeeds
- ✅ **Intelligent lock handling** - distinguishes between own jobs and external locks
- ✅ **SSH key-based authentication** with multi-level auto-detection
- ✅ **Passphrase validation** - wizard tests passphrase before saving
- ✅ **Repository format validation** - ensures valid ssh:// URL format with optional port
- ✅ **GPG-encrypted backup images** - Panzerbackup artifacts
- ✅ **Isolated worker processes** - run with minimal environment (`env -i`)
- ✅ **Lock file protection** - prevents concurrent operations
- ✅ **Comprehensive error trapping** - detailed error messages
- ✅ **Process isolation** - background workers run in new sessions (`setsid`)

## 🐛 Troubleshooting

### Language Selector Appears Every Time

**This is intentional behavior!**

The script **always** shows the language selector on interactive launches to ensure consistent UX. The default selection is your last saved language.

**To skip quickly:**
- Just press Enter to use the default (shown in brackets)
- Or type `1` for Deutsch, `2` for English

**Non-interactive mode** (CLI commands, systemd) uses saved `UI_LANG` without prompting.

### Wizard Not Starting

```bash
# Check script permissions
ls -la borgbase_manager.sh
chmod +x borgbase_manager.sh

# Ensure Bash 4.0+
bash --version

# Run with debug
DEBUG=1 ./borgbase_manager.sh
```

### Connection Test Fails

**SSH Hostkey Problem:**
```bash
# Manually verify host key
ssh-keyscan -H user.repo.borgbase.com

# For custom port
ssh-keyscan -H -p 2222 user.repo.borgbase.com

# Or set AUTO_ACCEPT_HOSTKEY=yes in wizard
```

**SSH Auth Failed:**
```bash
# Test SSH manually
ssh -T user@user.repo.borgbase.com borg --version

# For custom port
ssh -T -p 2222 user@user.repo.borgbase.com borg --version

# Check key permissions
ls -la ~/.ssh/id_ed25519*
chmod 600 ~/.ssh/id_ed25519

# Verify key is loaded (if using agent)
ssh-add -l
```

**Passphrase Wrong:**
```bash
# Re-run wizard to update passphrase
./borgbase_manager.sh config

# Or manually edit file (and test)
nano ~/.config/borgbase-backup-manager/borg_passphrase
./borgbase_manager.sh test
```

### Upload Blocked

**Message**: "Upload ist gesperrt, solange SSH/Repo nicht erreichbar ist"

**Causes:**
1. **Network down** - Repo host unreachable
2. **SSH auth failed** - Wrong key or known_hosts issue
3. **Wrong passphrase** - Borg passphrase incorrect
4. **Repo doesn't exist** - Invalid REPO path

**Solution:**
```bash
# Test connection with details
./borgbase_manager.sh test

# If fails, check:
# 1. Network connectivity
ping user.repo.borgbase.com

# 2. SSH key access
ssh -T user@user.repo.borgbase.com

# 3. Repository exists
borg info ssh://user@user.repo.borgbase.com/./repo

# 4. Re-run wizard to fix config
./borgbase_manager.sh config
```

### Repository Locked Warning

**Message**: "WARNUNG: Repo gesperrt (Lock-Timeout)"

This is **normal** if:
- Another backup is currently running
- Previous job didn't clean up properly

**Actions:**
- **If own job running**: Status shows `OK: Repo erreichbar (BUSY/Lock durch laufenden Job)`
- **If no job running**: Wait for lock to clear, or break lock manually:

```bash
# Check for running jobs
ps aux | grep borg
./borgbase_manager.sh status

# View live progress if job is running
./borgbase_manager.sh
# Select option 9) Live progress

# If stuck, break lock manually
borg break-lock ssh://user@user.repo.borgbase.com/./repo

# Clear stale PID file
rm -f ~/.cache/borgbase-backup-manager/borgbase-worker.pid
```

### Auto-Detection Fails

**Source Directory:**
```bash
# Check if Panzerbackup volume is mounted
mount | grep -i panzerbackup

# Manually specify in wizard
./borgbase_manager.sh config
# Enter full path when prompted for SRC_DIR

# Or set in config
echo 'SRC_DIR="/mnt/my-backup-volume"' >> ~/.config/borgbase-backup-manager/borgbase-manager.env
```

**SSH Key:**
```bash
# Check available keys
ls -la ~/.ssh/id_*

# Set hint in wizard (finds id_*borgbase* or id_*newvorta*)
PREFERRED_KEY_HINT="borgbase"

# Or explicit path
SSH_KEY="/home/user/.ssh/id_ed25519_borgbase"

# Test detection manually
DEBUG=1 ./borgbase_manager.sh config
```

### Permission Denied

```bash
# Fix config file permissions
chmod 600 ~/.config/borgbase-backup-manager/borgbase-manager.env
chmod 600 ~/.config/borgbase-backup-manager/borg_passphrase

# Fix SSH key permissions
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

# Fix log directory
mkdir -p ~/.local/state/borgbase-backup-manager
chmod 755 ~/.local/state/borgbase-backup-manager
```

### Live Progress Not Working

```bash
# Check if log file exists
ls -la ~/.local/state/borgbase-backup-manager/borgbase-manager.log

# Ensure log is writable
touch ~/.local/state/borgbase-backup-manager/borgbase-manager.log

# If stdbuf not available (optional feature)
# Script falls back to tail without buffering
which stdbuf

# Manually follow log without menu
tail -f ~/.local/state/borgbase-backup-manager/borgbase-manager.log
```

### Settings Menu Shows "no" for Existing Files

**Menu shows:**
```
║  SSH_KEY_EXISTS: no                                       ║
║  PASSFILE_EXISTS: no                                      ║
```

**Check files exist:**
```bash
# Check SSH key
ls -la ~/.ssh/id_ed25519_borgbase
# If missing: ./borgbase_manager.sh config

# Check passphrase file
ls -la ~/.config/borgbase-backup-manager/borg_passphrase
# If missing: ./borgbase_manager.sh config
```

### Custom Port Not Working

```bash
# Verify REPO format includes port
echo $REPO
# Should be: ssh://user@host:2222/./repo

# Test SSH with port manually
ssh -T -p 2222 user@host borg --version

# Update known_hosts for custom port
ssh-keyscan -H -p 2222 host >> ~/.ssh/known_hosts

# Re-run wizard to fix
./borgbase_manager.sh config
```

## 🔄 Background Operation Details

### Worker Process Architecture

1. **Main Script**: Handles UI, validation, preflight checks
2. **Worker Scripts**: Execute Borg operations in isolation
3. **Status Files**: Communication between processes
4. **PID Tracking**: Monitor running operations

**Worker Features:**
- Run in isolated environment (`env -i`)
- Start in new session (`setsid`)
- Comprehensive error handling
- Duration tracking (MM:SS format)
- Self-cleanup on completion
- Detailed environment logging

### Preflight Gating

**Before Upload/Download:**
1. Configuration exists and loaded
2. Source directory detected/valid
3. **Repository connection test passes** ✅
   - Connection failure → Operation blocked
   - Lock timeout → Warning, operation allowed (Borg will wait)
4. No job currently running
5. User confirms operation (upload only)

**Hard Gate**: Operations **blocked** if connection test fails (except lock timeouts).

### Status Lifecycle

```
Script Start → Language Selector → Load Config → Startup Repo Check
                                                         ↓
                                   ┌─────────────────────┴─────────────────────┐
                                   ↓                     ↓                     ↓
                             Status: OK         Status: WARNUNG          Status: FEHLER
                                   ↓                     ↓                     ↓
                          Operations          Operations            Operations
                            Allowed       Allowed (with warning)       Blocked
```

## 📝 License

MIT License - see [LICENSE](LICENSE) file for details

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit changes (`git commit -m 'Add AmazingFeature'`)
4. Push to branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/yourusername/borgbase-backup-manager/issues)
- **Documentation**: [BorgBackup Docs](https://borgbackup.readthedocs.io/)
- **BorgBase**: [BorgBase Support](https://www.borgbase.com/support)

## 🔍 Advanced Features

### Debug Mode

```bash
DEBUG=1 ./borgbase_manager.sh
```

Shows:
- Every command executed
- Variable expansions
- Function calls
- SSH key detection process
- Configuration loading
- Repository URL parsing

### Custom Retention Policy

Edit config file:

```bash
nano ~/.config/borgbase-backup-manager/borgbase-manager.env

# Change retention
PRUNE="yes"
KEEP_LAST="30"        # Keep last 30 backups (default: 1)
```

Or disable pruning:
```bash
PRUNE="no"  # Never delete old backups
```

**Warning**: Default `KEEP_LAST=1` keeps only the latest backup. Increase for redundancy.

### Custom Compression

Default compression is `lz4` (fast). To customize, edit the worker script section:

```bash
# Find in worker creation: --compression lz4
# Change to:
--compression zstd,1   # Fast zstd
--compression zstd,10  # Better zstd
--compression zlib,6   # Standard gzip
--compression lzma,6   # Best compression (slowest)
```

### Multiple Repositories

**Option 1: Multiple Users**
```bash
# Each system user has separate config
sudo adduser backup-user-1
sudo adduser backup-user-2

# Each runs their own config
su - backup-user-1 -c "borgbase-manager upload"
su - backup-user-2 -c "borgbase-manager upload"
```

**Option 2: Local .env Override**
```bash
# Create project-specific override
cd /path/to/project
cat > .env <<EOF
REPO="ssh://project@project.repo.borgbase.com/./repo"
SRC_DIR="/path/to/project/backups"
EOF

# Script loads .env if present (after user config)
./borgbase_manager.sh upload
```

**Option 3: Environment Variables**
```bash
# Override per invocation
REPO="ssh://alt@alt.repo.borgbase.com/./repo" \
SRC_DIR="/mnt/alt-backup" \
./borgbase_manager.sh upload
```

### Non-Interactive Mode

For automation (systemd, cron):

```bash
# Ensure config exists and connection works
./borgbase_manager.sh test

# CLI commands are non-interactive (no language prompt)
./borgbase_manager.sh upload   # No prompts
./borgbase_manager.sh list     # Direct output
./borgbase_manager.sh status   # Check status
```

**Note**: First-time setup **requires** interactive wizard. CLI mode uses saved `UI_LANG`.

### Changing Language

**Interactive:** Language selector appears on every launch

**Non-Interactive:** Edit config or use environment variable

```bash
# Edit config
nano ~/.config/borgbase-backup-manager/borgbase-manager.env
# Set: UI_LANG="en"

# Or per-invocation
UI_LANG="en" ./borgbase_manager.sh upload
```

## 🙏 Acknowledgments

- [BorgBackup](https://www.borgbackup.org/) - Deduplicating archiver with compression and encryption
- [BorgBase](https://www.borgbase.com/) - Hosting service for Borg repositories
- Panzerbackup community for backup workflows
- XDG Base Directory Specification for proper config management

---

**Made with ❤️ for secure, reliable backups**
