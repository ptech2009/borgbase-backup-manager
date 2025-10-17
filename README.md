# BorgBase Backup Manager

A secure, production-ready backup management tool for uploading and downloading Panzerbackup artifacts to/from BorgBase repositories using BorgBackup.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-5.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![BorgBackup](https://img.shields.io/badge/BorgBackup-1.2%2B-blue.svg)](https://www.borgbackup.org/)

## 🌟 Features

- **🌐 Bilingual Interface**: Full support for English and German
- **🔒 Security First**: No hardcoded secrets, SSH key authentication, GPG-encrypted backups
- **🔑 Advanced SSH Key Detection**: Automatic discovery from SSH config files, standard locations, and all system users
- **🔄 Automated Workflows**: systemd-friendly for scheduled backups
- **📊 Live Progress Monitoring**: Real-time status updates with filtered, readable log output
- **📝 Integrated Log Viewer**: View log files directly from the menu
- **🎯 Smart Auto-Detection**: Automatically finds Panzerbackup volumes across multiple mount points
- **🖥️ Interactive TUI**: User-friendly menu-driven interface
- **⚙️ CLI Support**: Direct command-line operations for automation
- **🧹 Automatic Pruning**: Configurable retention policies with compact operation
- **🛡️ Robust Error Handling**: Comprehensive error trapping and status reporting

## 📋 Prerequisites

- **BorgBackup** 1.2 or higher
- **Bash** 5.0 or higher
- **SSH** access to BorgBase repository
- **Panzerbackup** artifacts (`.img.zst.gpg` files)

### Installation

```bash
# Install BorgBackup (Debian/Ubuntu)
sudo apt install borgbackup

# Install BorgBackup (Arch Linux)
sudo pacman -S borg

# Install BorgBackup (macOS)
brew install borgbackup
```

## 🚀 Quick Start

### 1. Clone and Setup

```bash
# Clone the repository
git clone https://github.com/yourusername/borgbase-backup-manager.git
cd borgbase-backup-manager

# Make the script executable
chmod +x borgbase_manager.sh
```

### 2. Configure Environment

Create `/etc/borgbase-manager.env` with your settings:

```bash
# BorgBase Repository (REQUIRED)
REPO="ssh://your_user@your_user.repo.borgbase.com/./repo"

# Authentication (SSH key is auto-detected if not specified)
SSH_KEY="/path/to/your/id_ed25519"  # Optional - will be auto-detected
PASSPHRASE_FILE="/secure/path/to/passphrase"  # Optional - can use BORG_PASSPHRASE or SSH agent

# Backup Source (auto-detected if mounted)
SRC_DIR="/mnt/panzerbackup-pm"

# Logging
LOG_FILE="/var/log/borgbase-manager.log"
STATUS_FILE="/tmp/borg-status"
PID_FILE="/tmp/borg-upload.pid"

# Retention Policy
PRUNE="yes"
KEEP_LAST="7"

# Language (optional: de|en)
UI_LANG="de"
```

### 3. Secure Your Credentials

```bash
# Set proper permissions
sudo chmod 600 /etc/borgbase-manager.env
sudo chown root:root /etc/borgbase-manager.env

# Store BorgBackup passphrase securely
echo "your_borg_passphrase" | sudo tee /secure/path/to/passphrase > /dev/null
sudo chmod 400 /secure/path/to/passphrase
```

### 4. Run

```bash
# Interactive mode
./borgbase_manager.sh

# CLI mode
./borgbase_manager.sh upload
./borgbase_manager.sh list
./borgbase_manager.sh log
```

## 📖 Usage

### Interactive Menu

Run the script without arguments to access the interactive menu:

```bash
./borgbase_manager.sh
```

**Menu Options:**

1. **Upload** - Upload latest local backup to BorgBase
2. **Download** - Download and restore a backup from BorgBase
3. **List** - Show all available archives
4. **Info** - Display repository information
5. **Delete** - Remove an archive from repository
6. **Stop** - Cancel running operation
7. **Progress** - Live progress monitoring with filtered output
8. **Log** - View log file (last 200 lines)
9. **Exit** - Quit the manager

### Command-Line Interface

```bash
# Upload latest backup
./borgbase_manager.sh upload

# Download specific archive
./borgbase_manager.sh download Backup-hostname-2025-01-15_14-30

# List all archives
./borgbase_manager.sh list

# Show repository info
./borgbase_manager.sh info

# Delete specific archive
./borgbase_manager.sh delete Backup-hostname-2025-01-15_14-30

# Stop running operation
./borgbase_manager.sh stop

# View log file
./borgbase_manager.sh log
```

## 🔑 SSH Key Auto-Detection

The script features **comprehensive SSH key auto-detection** that searches multiple locations in the following priority order:

### Detection Priority

1. **Environment Variable**: `SSH_KEY` from configuration file
2. **SSH Config Files**: `IdentityFile` entries matching the repository host
   - `~/.ssh/config` (current user)
   - `/etc/ssh/ssh_config` (system-wide)
   - `/home/$SUDO_USER/.ssh/config` (when running as root via sudo)
3. **Standard Key Locations**: Common SSH key filenames in:
   - `~/.ssh/` (current user)
   - `/root/.ssh/` (when running as root)
   - `/home/$SUDO_USER/.ssh/` (when running as root via sudo)
4. **All System Users**: When running as root, searches all regular users (UID ≥ 1000):
   - `~/.ssh/` directories
   - User-specific SSH config files

**Key Preferences:**
- Ed25519 keys are preferred over RSA/ECDSA/DSA keys for enhanced security
- Keys must be readable by the current user
- Duplicate paths are automatically filtered
- If no key file is found, falls back to SSH agent or default SSH behavior

**Supported Key Types:**
- `id_ed25519` (preferred)
- `id_rsa`
- `id_ecdsa`
- `id_dsa`
- Any custom key filename

**Example SSH Config:**

```ssh-config
# ~/.ssh/config
Host *.repo.borgbase.com
    IdentityFile ~/.ssh/id_ed25519_borgbase
    IdentitiesOnly yes
```

The script will automatically detect and use `id_ed25519_borgbase` when connecting to BorgBase.

## 🎯 Auto-Detection Features

### Backup Directory Detection

The script automatically searches for Panzerbackup volumes in:

- `/mnt/*panzerbackup*` (case-insensitive)
- `/media/*/*panzerbackup*` (case-insensitive)
- `/run/media/*/*panzerbackup*` (case-insensitive)
- Any mounted filesystem with "panzerbackup" in the path (via `findmnt`)

**Selection Logic:**
- Only directories containing valid `panzer_*.img.zst.gpg` files are considered
- If multiple valid directories exist, the one with the **newest backup** is selected
- Directories are searched up to 3 levels deep

### Preflight Validation

Before starting an upload, the script performs comprehensive validation:

- Verifies presence of latest backup image (`.img.zst.gpg`)
- Checks for required companion files (`.sha256`, `.sfdisk`)
- Calculates total upload size including:
  - Main backup image
  - SHA256 checksum
  - Partition table (sfdisk)
  - `LATEST_OK` symlinks
  - `panzerbackup.log`

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
EnvironmentFile=/etc/borgbase-manager.env
ExecStart=/usr/local/bin/borgbase_manager.sh upload
User=root
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
```

## 🔧 Configuration Reference

### Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `REPO` | BorgBase repository URL | - | ✅ Yes |
| `SSH_KEY` | Path to SSH private key | Auto-detected | ❌ No |
| `PASSPHRASE_FILE` | Path to Borg passphrase | - | ❌ No* |
| `SRC_DIR` | Backup source directory | `/mnt/panzerbackup-pm` | ❌ No** |
| `LOG_FILE` | Log file location | `/var/log/borgbase-manager.log` | ❌ No |
| `STATUS_FILE` | Status tracking file | `/tmp/borg-status` | ❌ No |
| `PID_FILE` | Process ID file | `/tmp/borg-upload.pid` | ❌ No |
| `PRUNE` | Enable auto-pruning | `yes` | ❌ No |
| `KEEP_LAST` | Number of backups to retain | `7` | ❌ No |
| `UI_LANG` | Interface language (de/en) | `de` | ❌ No |

\* If not specified, passphrase must be provided via `BORG_PASSPHRASE` environment variable or SSH agent  
\** Auto-detected if Panzerbackup volume is mounted

### Configuration Priority

1. `/etc/borgbase-manager.env` (recommended for production)
2. `./.env` (local override for testing)
3. Runtime environment variables

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

Archives are named using the pattern: `Backup-<HOSTNAME>-<TIMESTAMP>`

Example: `Backup-myserver-2025-01-15_14-30`

## 📊 Monitoring

### Live Progress

Option 7 in the interactive menu provides real-time monitoring with:

- **Current operation status** from status file
- **Filtered log streaming** that removes:
  - Python tracebacks and error stack traces
  - BorgBackup internal signal handling messages
  - Broken pipe errors
  - File/line number references
- **Smart log slicing** showing only the current operation (from last "Worker Start")
- **Automatic refresh** every 2 seconds
- **Non-intrusive monitoring** - CTRL+C exits viewer without stopping the job

### Log Viewer

Option 8 in the interactive menu displays:

- Last 200 lines of the log file
- Full path to log file
- Clean, formatted output

Access via CLI:

```bash
./borgbase_manager.sh log
```

### Log Files

```bash
# View full log
sudo tail -f /var/log/borgbase-manager.log

# Check systemd journal
sudo journalctl -u borgbase-upload.service -f

# View last 200 lines (via script)
./borgbase_manager.sh log
```

## 🛡️ Security Features

- ✅ **No hardcoded secrets** - all credentials via environment files
- ✅ **SSH key-based authentication** with automatic detection
- ✅ **Intelligent SSH key discovery** across all system users
- ✅ **Encrypted repository passphrases** stored securely
- ✅ **GPG-encrypted backup images** for data protection
- ✅ **Isolated worker processes** - run with minimal environment (`env -i`)
- ✅ **Secure file permissions** enforcement (600/400)
- ✅ **Lock file protection** against concurrent operations
- ✅ **SSH agent support** as fallback authentication
- ✅ **Comprehensive error trapping** with detailed error messages
- ✅ **Process isolation** - background workers run in new sessions (`setsid`)

## 🐛 Troubleshooting

### Repository Locked

```bash
# If a job was interrupted, manually break lock
borg break-lock ssh://user@repo.borgbase.com/./repo
```

The script automatically attempts to break locks when stopping jobs.

### SSH Key Not Found

The script performs extensive SSH key detection. If automatic detection fails:

```bash
# Check which keys were detected (enable debug mode)
DEBUG=1 ./borgbase_manager.sh

# Explicitly specify SSH key in config
export SSH_KEY="/path/to/your/key"

# Or add to /etc/borgbase-manager.env
echo 'SSH_KEY="/path/to/your/key"' | sudo tee -a /etc/borgbase-manager.env

# Test SSH connection manually
ssh -v user@user.repo.borgbase.com
```

### Auto-Detection Fails

```bash
# Manually specify source directory
export SRC_DIR="/path/to/your/backup"
./borgbase_manager.sh upload

# Check what the script detected
DEBUG=1 ./borgbase_manager.sh
```

### Permission Denied

```bash
# Ensure proper ownership and permissions for config
sudo chown root:root /etc/borgbase-manager.env
sudo chmod 600 /etc/borgbase-manager.env

# Secure passphrase file
sudo chmod 400 /secure/path/to/passphrase

# Check SSH key permissions
chmod 600 ~/.ssh/id_ed25519
```

### Job Appears Stuck

```bash
# View live progress
./borgbase_manager.sh
# Then select option 7) Progress

# Or check the log directly
./borgbase_manager.sh log

# Check process status
ps aux | grep borg
```

### Language Selection

```bash
# Set language in config file
echo 'UI_LANG="en"' | sudo tee -a /etc/borgbase-manager.env

# Or set as environment variable
export UI_LANG="en"
./borgbase_manager.sh

# Language prompt appears on first run if not set
```

## 🔄 Background Operation Details

### Worker Process Architecture

The script uses a sophisticated background worker architecture:

1. **Main Script**: Handles UI, validation, and job initialization
2. **Worker Scripts**: Execute actual Borg operations in isolation
3. **Status Files**: Enable communication between processes
4. **PID Tracking**: Monitors running operations

**Worker Features:**
- Run in isolated environment (`env -i`)
- Start in new session (`setsid`) for independence
- Redirect output to log file
- Self-cleanup on completion or failure
- Comprehensive error handling

### Status Tracking

The script maintains three types of status:

1. **Status File** (`/tmp/borg-status`): Current operation status
2. **PID File** (`/tmp/borg-upload.pid`): Running process ID
3. **Log File** (`/var/log/borgbase-manager.log`): Detailed operation log

## 📝 License

MIT License - see [LICENSE](LICENSE) file for details

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/yourusername/borgbase-backup-manager/issues)
- **Documentation**: [BorgBackup Docs](https://borgbackup.readthedocs.io/)
- **BorgBase**: [BorgBase Support](https://www.borgbase.com/support)

## 🔍 Advanced Features

### Debug Mode

Enable detailed debugging output:

```bash
DEBUG=1 ./borgbase_manager.sh
```

This enables Bash's `set -x` mode, showing every command executed.

### Custom Compression

The script uses `lz4` compression by default for speed. To customize:

```bash
# Edit the worker script section
# Change: --compression lz4
# To:     --compression zstd,10  # or other Borg compression options
```

### Multiple Repositories

You can manage multiple repositories by:

1. Creating separate environment files:
   - `/etc/borgbase-manager-repo1.env`
   - `/etc/borgbase-manager-repo2.env`

2. Using different configuration files:
   ```bash
   # Copy and customize the script
   cp borgbase_manager.sh borgbase_manager_repo1.sh
   # Edit to source different env file
   ```

## 🙏 Acknowledgments

- [BorgBackup](https://www.borgbackup.org/) - Deduplicating archiver with compression and encryption
- [BorgBase](https://www.borgbase.com/) - Hosting service for Borg repositories
- Panzerbackup community for backup workflows

---

**Made with ❤️ for secure, reliable backups**
