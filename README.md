# BorgBase Backup Manager

A secure, production-ready backup management tool for uploading and downloading Panzerbackup artifacts to/from BorgBase repositories using BorgBackup.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-5.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![BorgBackup](https://img.shields.io/badge/BorgBackup-1.2%2B-blue.svg)](https://www.borgbackup.org/)

## 🌟 Features

- **🧙 Interactive Configuration Wizard**: First-run wizard with connection validation and secure credential storage
- **🌐 Bilingual Interface**: Full support for English and German
- **🔒 Security First**: Per-user config, secure passphrase storage, SSH key authentication
- **🔑 Advanced SSH Key Auto-Detection**: Multi-level discovery from SSH config, standard locations, and custom hints
- **🛡️ Hard Preflight Gating**: Upload/Download blocked until repository connection is verified
- **📊 Startup Status Check**: Automatic repo connection test on every launch
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
- **Optional**: `findmnt`, `ssh-keygen`, `ssh-keyscan` for enhanced features

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

The wizard will prompt for:
- **Language** (English/German)
- **BorgBase Repository URL** (format validation)
- **Source Directory** (auto-detection or manual path)
- **SSH Key** (auto-detection with optional hint)
- **Known Hosts Path**
- **Repository Passphrase** (securely stored in file)
- **Connection Test** (validates all settings)

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
# Interactive mode
./borgbase_manager.sh

# CLI mode
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

**Menu Options:**

1. **Upload** - Upload latest local backup to BorgBase (requires valid connection)
2. **Download** - Download and restore a backup from BorgBase (requires valid connection)
3. **List** - Show all available archives (requires valid connection)
4. **Test Connection** - Verify repository connection (SSH + Borg)
5. **View Log** - Display log file in pager
6. **Show Settings** - Display current configuration (passwords hidden)
7. **Clear Status** - Reset status file
8. **Reconfigure (Wizard)** - Re-run configuration wizard
9. **Quit** - Exit the manager

### Command-Line Interface

```bash
# Interactive menu
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

### Connection Gating

**Hard Preflight Requirements:**
- Upload/Download/List operations **blocked** until repo connection succeeds
- Connection test validates:
  1. SSH authentication (key + known_hosts)
  2. Repository access (`borg info`)
  3. Passphrase correctness
- Wizard loops until all validation passes
- Status updated on every script launch

## 🔑 SSH Key Auto-Detection

### Detection Strategy

**Multi-Level Search (in priority order):**

1. **Explicit Configuration**
   - If `SSH_KEY` is set and readable → use immediately
   
2. **SSH Config Files** (`~/.ssh/config`)
   - Parse `IdentityFile` directives
   - Match repository hostname
   
3. **Preferred Key Hint**
   - If `PREFERRED_KEY_HINT` is set (e.g., "newvorta")
   - Search for keys containing hint string
   
4. **Standard Key Locations** (`~/.ssh/`)
   - `id_ed25519*` (preferred)
   - `id_rsa`
   - `id_ecdsa`
   - `id_dsa`

### Key Preferences

1. Keys matching `PREFERRED_KEY_HINT`
2. Ed25519 keys (highest security)
3. First readable key found

### Configuration Examples

**Auto-Detection (Recommended):**
```bash
# Leave SSH_KEY empty in wizard
SSH_KEY=""

# Optional: Set hint to prefer specific key
PREFERRED_KEY_HINT="borgbase"  # Matches id_ed25519_borgbase
```

**Explicit Key:**
```bash
SSH_KEY="/home/user/.ssh/id_ed25519_borgbase"
```

**SSH Config Integration:**
```ssh-config
# ~/.ssh/config
Host *.repo.borgbase.com
    IdentityFile ~/.ssh/id_ed25519_borgbase
    IdentitiesOnly yes
    StrictHostKeyChecking yes
```

## 🎯 Auto-Detection Features

### Backup Directory Detection

Automatic search for Panzerbackup volumes:

**Search Locations:**
- `/mnt/*panzerbackup*` (case-insensitive)
- `/media/*/*panzerbackup*`
- `/run/media/*/*panzerbackup*`
- Any mounted filesystem via `findmnt`

**Selection Logic:**
- Only directories with valid `panzer_*.img.zst.gpg` files
- If multiple found → newest backup wins
- Depth: up to 4 levels

**Manual Override:**
- Wizard prompts for manual path if auto-detection fails
- Can specify custom path at any time

### Upload Candidate Display

Before upload, script shows **exact details**:

```
Planned upload set (LATEST backup):
  SRC_DIR : /mnt/panzerbackup-pm
  IMG     : panzer_2025-01-28_14-30-00.img.zst.gpg
  Datum   : 2025-01-28 14:30:00
  Größe   : 245.67 GiB (263742619648 Bytes)
  SHA     : panzer_2025-01-28_14-30-00.img.zst.gpg.sha256
  SFDISK  : panzer_2025-01-28_14-30-00.sfdisk
```

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

## 🔧 Configuration Reference

### Environment Variables

| Variable | Description | Default | Set by Wizard |
|----------|-------------|---------|---------------|
| `UI_LANG` | Interface language (de/en) | `de` | ✅ Yes |
| `REPO` | BorgBase repository URL | - | ✅ Yes (validated) |
| `SRC_DIR` | Backup source directory | Auto-detect | ✅ Yes (optional) |
| `SSH_KEY` | Path to SSH private key | Auto-detect | ✅ Yes (optional) |
| `PREFERRED_KEY_HINT` | SSH key search hint | - | ✅ Yes (optional) |
| `SSH_KNOWN_HOSTS` | Known hosts file path | `~/.ssh/known_hosts` | ✅ Yes |
| `PASSPHRASE_FILE` | Repo passphrase file | `~/.config/.../borg_passphrase` | ✅ Yes (validated) |
| `SSH_KEY_PASSPHRASE_FILE` | SSH key passphrase file | `~/.config/.../sshkey_passphrase` | ✅ Yes (optional) |
| `LOG_FILE` | Log file location | `~/.local/state/.../borgbase-manager.log` | ❌ No |
| `PRUNE` | Enable auto-pruning | `yes` | ❌ No |
| `KEEP_LAST` | Backups to retain | `1` | ❌ No |
| `SSH_CONNECT_TIMEOUT` | SSH timeout (seconds) | `5` | ❌ No |
| `BORG_LOCK_WAIT` | Borg lock wait (seconds) | `5` | ❌ No |
| `AUTO_ACCEPT_HOSTKEY` | Auto-add SSH host keys | `no` | ❌ No |
| `AUTO_TEST_SSH` | Test SSH on setup | `yes` | ❌ No |
| `AUTO_TEST_REPO` | Test repo on setup | `yes` | ❌ No |

### Manual Configuration

Edit `~/.config/borgbase-backup-manager/borgbase-manager.env`:

```bash
# Language
UI_LANG="en"

# Repository (REQUIRED - must be ssh://user@host/./repo format)
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

# Retention
PRUNE="yes"
KEEP_LAST="7"

# Timeouts
SSH_CONNECT_TIMEOUT="5"
BORG_LOCK_WAIT="5"
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
- 🔴 **Red**: Errors/failures
- 🟢 **Green**: Success/ready
- 🟡 **Yellow**: Running operations

**Status Messages:**
- `OK: Verbindung erfolgreich hergestellt` - Connection validated
- `FEHLER: Repo-Passphrase fehlt` - Missing passphrase
- `FEHLER: SSH Auth fehlgeschlagen` - SSH authentication failed
- `UPLOAD: Finished - Backup-host-2025-01-28_14-30 (Duration: 05m:23s)` - Completed

### Startup Status Check

**On every script launch:**
1. Loads configuration (if exists)
2. Tests repository connection (silent)
3. Sets status to `OK` or `FEHLER: <specific issue>`
4. Displays in menu header

**Benefits:**
- Immediate feedback on config validity
- Early detection of connectivity issues
- No surprise failures when starting uploads

### Log Files

```bash
# View log in pager
./borgbase_manager.sh
# Then select option 5) View log

# Or directly with less
less ~/.local/state/borgbase-backup-manager/borgbase-manager.log

# Tail log
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
UPLOAD: Finished - Backup-myhost-2025-01-28_14-30 (Duration: 05m:23s)
==========================================
```

## 🛡️ Security Features

- ✅ **No hardcoded secrets** - all credentials in user-specific files
- ✅ **Per-user configuration** - isolated settings per system user
- ✅ **Secure credential storage** - chmod 600 on all sensitive files
- ✅ **Path validation** - wizard enforces absolute paths for passphrase files
- ✅ **Connection gating** - operations blocked until repo connection succeeds
- ✅ **SSH key-based authentication** with multi-level auto-detection
- ✅ **Passphrase validation** - wizard tests passphrase before saving
- ✅ **Repository format validation** - ensures valid ssh:// URL format
- ✅ **GPG-encrypted backup images** - Panzerbackup artifacts
- ✅ **Isolated worker processes** - run with minimal environment (`env -i`)
- ✅ **Lock file protection** - prevents concurrent operations
- ✅ **Comprehensive error trapping** - detailed error messages
- ✅ **Process isolation** - background workers run in new sessions (`setsid`)

## 🐛 Troubleshooting

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

# Or set AUTO_ACCEPT_HOSTKEY=yes in wizard
```

**SSH Auth Failed:**
```bash
# Test SSH manually
ssh -T user@user.repo.borgbase.com borg --version

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

**Message**: "Upload ist gesperrt, solange die Repo-Verbindung nicht OK ist"

**Solution:**
```bash
# Test connection
./borgbase_manager.sh test

# If fails, check:
# 1. Network connectivity
ping user.repo.borgbase.com

# 2. SSH key access
ssh -T user@user.repo.borgbase.com

# 3. Repository exists
borg info ssh://user@user.repo.borgbase.com/./repo

# 4. Passphrase correct
# Re-run wizard to update
./borgbase_manager.sh config
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

# Set hint in wizard
PREFERRED_KEY_HINT="borgbase"  # Will find id_ed25519_borgbase

# Or explicit path
SSH_KEY="/home/user/.ssh/id_ed25519_borgbase"
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

### Repo Locked

```bash
# If job was interrupted, manually break lock
borg break-lock ssh://user@user.repo.borgbase.com/./repo

# Check for stale worker
ps aux | grep borg
kill <PID>  # if needed

# Clear PID file
rm -f ~/.cache/borgbase-backup-manager/borgbase-worker.pid
```

### Language Issues

```bash
# Change language
./borgbase_manager.sh config
# Select language when prompted

# Or edit config
nano ~/.config/borgbase-backup-manager/borgbase-manager.env
# Set: UI_LANG="en"
```

### Settings Not Showing Correctly

```bash
# View current settings
./borgbase_manager.sh
# Select option 6) Show settings

# Check config file exists
cat ~/.config/borgbase-backup-manager/borgbase-manager.env

# Re-run wizard if corrupted
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

### Preflight Gating

**Before Upload/Download:**
1. Configuration exists and loaded
2. Source directory detected/valid
3. **Repository connection test passes** ✅
4. No job currently running
5. User confirms operation

**Hard Gate**: Operations **blocked** if connection test fails.

### Status Lifecycle

```
Script Start → Load Config → Startup Repo Check → Set Status
                                      ↓
                           ┌──────────┴──────────┐
                           ↓                     ↓
                      Status: OK          Status: FEHLER
                           ↓                     ↓
                    Operations          Operations
                      Allowed              Blocked
```

## 📝 License

MIT License - see [LICENSE](LICENSE) file for details

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit changes (`git commit -m 'Add AmazingFeature'`)
4. Push to branch (`git push origin feature/AmazingFeature`)
5. Open Pull Request

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

### Custom Retention Policy

Edit config file:

```bash
nano ~/.config/borgbase-backup-manager/borgbase-manager.env

# Change retention
PRUNE="yes"
KEEP_LAST="30"        # Keep last 30 backups
```

Or disable pruning:
```bash
PRUNE="no"  # Never delete old backups
```

### Custom Compression

Edit worker script section (advanced):

```bash
# Default: lz4 (fast)
--compression lz4

# Alternatives:
--compression zstd,1   # Fast zstd
--compression zstd,10  # Better zstd
--compression zlib,6   # Standard
--compression lzma,6   # Best (slowest)
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

# Script loads .env if present
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

# CLI commands are non-interactive
./borgbase_manager.sh upload   # No prompts
./borgbase_manager.sh list     # Direct output
./borgbase_manager.sh status   # Check status
```

**Note**: First-time setup **requires** interactive wizard.

## 🙏 Acknowledgments

- [BorgBackup](https://www.borgbackup.org/) - Deduplicating archiver with compression and encryption
- [BorgBase](https://www.borgbase.com/) - Hosting service for Borg repositories
- Panzerbackup community for backup workflows
- XDG Base Directory Specification for proper config management

---

**Made with ❤️ for secure, reliable backups**
