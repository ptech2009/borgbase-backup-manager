# BorgBase Backup Manager

A secure, production-ready backup management tool for uploading and downloading Panzerbackup artifacts to/from BorgBase repositories using BorgBackup.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![BorgBackup](https://img.shields.io/badge/BorgBackup-1.2%2B-blue.svg)](https://www.borgbackup.org/)

## 🌟 Features

### Core Features
- **🧙 Interactive Configuration Wizard**: First-run wizard with connection validation and secure credential storage
- **📊 Dual Status Display**: Separate job and repository connection status in menu
- **⏱️ Live Runtime Tracking**: Real-time job duration display while operations are running
- **🌐 Forced Language Selection**: Language prompt on every interactive launch for consistent UX
- **🔒 Security First**: Per-user config, secure passphrase storage via `BORG_PASSCOMMAND`, SSH key authentication
- **🔑 Smart SSH Key Auto-Detection**: Multi-level discovery from SSH config, standard locations, and custom hints
- **🛡️ Hard Preflight Gating**: Upload/Download blocked until repository connection is verified
- **⚠️ Intelligent Lock Handling**: Repository locks treated as warnings (OK if own job running)

### Space Optimization & Smart Cleanup
- **💾 Space-First Strategy**: Runs Prune/Compact **BEFORE** Create to free up space first
- **🎯 Smart Prune Policies**: Different retention rules for Panzerbackup (keep 1) vs. Data backups (keep 14)
- **🔍 Interactive Prune Preview**: Shows what will be deleted before upload
- **🗑️ Manual Cleanup Option**: Select and delete specific archives immediately
- **⚙️ Unattended Prune**: Automatic cleanup in non-interactive mode
- **🧹 Compact Operation**: Automatic repository compaction after pruning

### Backup Features
- **📺 Live Progress Viewer**: Real-time log following with readable output formatting
- **🎯 Smart Auto-Detection**: Automatically finds Panzerbackup volumes across multiple mount points
- **🖥️ Interactive TUI**: User-friendly menu-driven interface with color-coded status display
- **⚙️ CLI Support**: Direct command-line operations for automation
- **📝 Comprehensive Logging**: Detailed operation logs with worker boundaries
- **🔄 Automated Workflows**: systemd-friendly for scheduled backups
- **💤 Sleep Inhibit**: Prevents system sleep/idle during backup operations (systemd-inhibit)
- **🔄 Checkpoint Support**: Borg checkpointing for interruption resilience

## 📋 Prerequisites

- **BorgBackup** 1.2 or higher
- **Bash** 4.0 or higher
- **SSH** access to BorgBase repository
- **Panzerbackup** artifacts (.img.zst.gpg files)
- **Optional**: findmnt, ssh-keygen, ssh-keyscan, stdbuf, systemd-inhibit for enhanced features

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
2. **BorgBase Repository URL** (format: ssh://user@host[:port]/./repo)
3. **Source Directory** (auto-detection or manual path)
4. **Preferred SSH Key Hint** (optional, e.g., "newvorta" or "borgbase")
5. **SSH Key Path** (auto-detection or manual path)
6. **Known Hosts Path** (default: ~/.ssh/known_hosts)
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
├── borgbase-job-status         # Current job status
├── borgbase-conn-status        # Repository connection status
├── borgbase-worker.pid         # Running job PID
├── borgbase-worker.start       # Job start timestamp
└── borgbase-prune-needed       # Prune flag for background jobs
```

### 4. Run

```bash
# Interactive mode (language selector appears first)
./borgbase_manager.sh

# CLI mode (non-interactive, uses saved language)
./borgbase_manager.sh upload
./borgbase_manager.sh download <archive-name>
./borgbase_manager.sh status
./borgbase_manager.sh break-lock
./borgbase_manager.sh install-service
```

## 📖 Usage

### Interactive Menu

Run the script without arguments to access the interactive menu:

```bash
./borgbase_manager.sh
```

**Menu Options:**
1. **Upload** - Upload Panzerbackup with smart prune preview
2. **Download** - Select and download an archive
3. **List Archives** - Show all backups in repository
4. **Test Connection** - Verify repository access
5. **View Log** - Browse operation logs
6. **Show Settings** - Display current configuration
7. **Clear Status** - Reset status displays
8. **Re-run Wizard** - Reconfigure settings
9. **Live Progress** - Watch current operation in real-time
10. **Install systemd Units** - Set up automatic backups
11. **Break Repository Lock** - Force unlock if needed
Q. **Quit**

### Upload Workflow

When you select **Upload** from the menu:

1. **Source Detection**: Auto-detects newest Panzerbackup mount
2. **Prune Preview** (if enabled):
   - Shows what will be deleted based on retention policies
   - Options:
     - **Manual Selection**: Pick specific archives to delete immediately
     - **Automatic Prune**: Accept suggested deletions (runs before upload)
     - **Skip**: Continue without pruning
3. **Upload Confirmation**: Final prompt before starting
4. **Background Execution**: Upload runs in background with live progress

### Retention Policies

Configure in `borgbase-manager.env`:

```bash
# Keep last N data backups (non-Panzerbackup archives)
KEEP_LAST=14

# Keep last N Panzerbackup archives  
KEEP_LAST_PANZERBACKUP=1

# Archive name template for Panzerbackups
PANZERBACKUP_ARCHIVE_NAME="panzerbackup-{hostname}-{date}"
```

**How it works:**
- Archives matching the Panzerbackup name pattern use `KEEP_LAST_PANZERBACKUP`
- All other archives use `KEEP_LAST`
- Prune runs **before** creating new archives to free up space
- Compact operation follows to reclaim disk space

### Advanced Configuration

Key environment variables in `borgbase-manager.env`:

```bash
# Space optimization
PRUNE_BEFORE_CREATE=yes          # Prune before upload (default: yes)
BORG_CHECKPOINT_INTERVAL=300     # Checkpoint interval in seconds

# Connection settings
SSH_CONNECT_TIMEOUT=10           # SSH connection timeout
BORG_LOCK_WAIT=60               # Wait time for repo locks
AUTO_ACCEPT_HOSTKEY=no          # Auto-add SSH host key
AUTO_TEST_SSH=yes               # Test SSH on startup
AUTO_TEST_REPO=yes              # Test repo access on startup

# Sleep prevention
INHIBIT_SLEEP=yes               # Prevent sleep during operations
INHIBIT_WHAT=sleep:idle         # What to inhibit
INHIBIT_MODE=block              # Inhibit mode
```

## 🔄 Systemd Integration

Install user-level systemd units for automatic scheduled backups:

```bash
# Install units
./borgbase_manager.sh install-service

# Enable and start timer
systemctl --user enable --now borgbase-upload.timer

# Check status
systemctl --user status borgbase-upload.timer
systemctl --user list-timers
```

**Installed Units:**
- `borgbase-upload.service` - One-shot upload service
- `borgbase-upload.timer` - Daily upload timer

## 🛡️ Security Features

- **BORG_PASSCOMMAND**: Uses secure command substitution instead of environment variables
- **File Permissions**: All credential files set to mode 600 (owner-only)
- **Per-User Config**: Isolated configuration directories per user
- **SSH Key Authentication**: Supports encrypted SSH keys with passphrase storage
- **Connection Validation**: Pre-flight checks before operations
- **Lock Handling**: Smart detection of own vs. external locks

## 📝 Logging

Logs are stored in `~/.local/state/borgbase-backup-manager/borgbase-manager.log`

**View logs:**
- Interactive: Select option **5** from menu
- Command line: `less +G ~/.local/state/borgbase-backup-manager/borgbase-manager.log`
- Live view: Select option **9** from menu while operation is running

**Log format:**
```
════════════════════════════════════════════════════════════
WORKER START: upload (PID: 12345) @ 2024-01-15 10:30:00
════════════════════════════════════════════════════════════
[Operations...]
════════════════════════════════════════════════════════════
WORKER END: upload @ 2024-01-15 10:45:30
════════════════════════════════════════════════════════════
```

## 🔧 Troubleshooting

### Repository Locked
If you see "Repository locked" warnings:
1. Check if another process is using the repository
2. If your own job is running, this is normal (yellow warning)
3. Use menu option **11** to break the lock if needed

### Connection Failures
1. Test connection: Menu option **4** or `./borgbase_manager.sh status`
2. Verify SSH key is added to BorgBase
3. Check `~/.ssh/known_hosts` contains the BorgBase host
4. Re-run wizard to reconfigure: Menu option **8**

### Space Issues
- Enable `PRUNE_BEFORE_CREATE=yes` to free space before uploads
- Reduce `KEEP_LAST` and `KEEP_LAST_PANZERBACKUP` retention values
- Use manual cleanup: Select specific archives in prune preview

### Debug Mode
Enable detailed logging:
```bash
DEBUG=1 ./borgbase_manager.sh
```

## 🙏 Acknowledgments

- [BorgBackup](https://www.borgbackup.org/) - Deduplicating archiver with compression and encryption
- [BorgBase](https://www.borgbase.com/) - Hosting service for Borg repositories
- Panzerbackup community for backup workflows
- XDG Base Directory Specification for proper config management

---

**Made with ❤️ for secure, reliable backups**
