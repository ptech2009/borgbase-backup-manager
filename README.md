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
- **📊 Live Progress Monitoring**: Real-time status updates with intelligent log filtering
- **📝 Integrated Log Viewer**: View last 200 log lines directly from the menu with instant access
- **🎯 Smart Auto-Detection**: Automatically finds Panzerbackup volumes across multiple mount points
- **🖥️ Interactive TUI**: User-friendly menu-driven interface with color-coded status display
- **⚙️ CLI Support**: Direct command-line operations for automation
- **🧹 Automatic Pruning**: Configurable retention policies with compact operation
- **🛡️ Robust Error Handling**: Comprehensive error trapping and status reporting with formatted duration display

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
SSH_KEY=""  # Leave EMPTY for auto-detection or set explicit path
PASSPHRASE_FILE="/secure/path/to/passphrase"  # Optional - can use BORG_PASSPHRASE or SSH agent

# Backup Source (auto-detected if mounted)
SRC_DIR="/mnt/backup-source"

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
7. **Progress** - Live progress monitoring with intelligent log filtering
8. **Log** - View log file (last 200 lines) - **NEW!**
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

# View log file (last 200 lines)
./borgbase_manager.sh log
```

## 🔑 SSH Key Auto-Detection

The script features **comprehensive SSH key auto-detection** that searches multiple locations in the following priority order:

### Detection Priority (5-Step Process)

**0. Explicit Configuration (Highest Priority)**
- If `SSH_KEY` is set in `/etc/borgbase-manager.env` **AND** the file is readable
- **Usage**: Set to specific path or leave **empty** (`SSH_KEY=""`) for auto-detection
- **Example**: `SSH_KEY="/home/user/.ssh/id_ed25519_borgbase"`

**1. SSH Config Files - IdentityFile Entries**
- Searches for `IdentityFile` directives matching the repository hostname
- Locations checked:
  - `~/.ssh/config` (current user)
  - `/etc/ssh/ssh_config` (system-wide)
  - `/home/$SUDO_USER/.ssh/config` (when running as root via sudo)

**2. Standard Key Locations**
- Common SSH key filenames in standard directories:
  - `~/.ssh/` (current user)
  - `/root/.ssh/` (when running as root)
  - `/home/$SUDO_USER/.ssh/` (when running as root via sudo)

**3. All System Users (Root Only)**
- When running as root, searches **all regular users** (UID ≥ 1000):
  - Every user's `~/.ssh/` directory
  - User-specific SSH config files

**4. Fallback Mechanisms**
- **SSH Agent**: If `SSH_AUTH_SOCK` is set, uses agent authentication
- **Default SSH Behavior**: Falls back to OpenSSH default identity resolution

### Key Selection Logic

**Preference Order:**
1. **Ed25519 keys** (`id_ed25519*`) - preferred for security
2. **RSA keys** (`id_rsa`)
3. **ECDSA keys** (`id_ecdsa`)
4. **DSA keys** (`id_dsa`)
5. **Custom named keys** (any `id_*` file)

**Filtering:**
- Keys must be **readable** by the current user
- Public keys (`.pub` files) are automatically excluded
- Duplicate paths are filtered out
- First matching key in preference order is selected

### Supported Key Types

```
id_ed25519          ← Preferred (highest security)
id_ed25519_custom   ← Also recognized
id_rsa
id_ecdsa
id_dsa
id_anycustomname    ← Any id_* pattern
```

### Configuration Examples

**Recommended: Auto-Detection (Leave Empty)**
```bash
# /etc/borgbase-manager.env
SSH_KEY=""  # Script will auto-detect the best key
```

**Explicit Key (Bypass Auto-Detection)**
```bash
# /etc/borgbase-manager.env
SSH_KEY="/home/user/.ssh/id_ed25519_borgbase"
```

**SSH Config Integration**
```ssh-config
# ~/.ssh/config
Host *.repo.borgbase.com
    IdentityFile ~/.ssh/id_ed25519_borgbase
    IdentitiesOnly yes
```

The script will automatically detect and use `id_ed25519_borgbase` when connecting to BorgBase, even if `SSH_KEY` is empty.

### Debugging SSH Key Detection

Enable debug mode to see which keys are being detected:

```bash
DEBUG=1 ./borgbase_manager.sh
```

This shows:
- All candidate key paths found
- Which key was ultimately selected
- Whether SSH agent fallback is active

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
| `SSH_KEY` | Path to SSH private key (leave empty for auto-detect) | `""` (auto-detect) | ❌ No |
| `PASSPHRASE_FILE` | Path to Borg passphrase | - | ❌ No* |
| `SRC_DIR` | Backup source directory | `/mnt/backup-source` | ❌ No** |
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

### Live Progress (Option 7)

The live progress viewer provides **intelligent log filtering** with real-time monitoring:

**Features:**
- **Current operation status** from status file with color-coded display
- **Smart log filtering** that automatically removes:
  - Python tracebacks and error stack traces
  - BorgBackup internal signal handling messages (e.g., `SigTerm`)
  - Broken pipe errors (`BrokenPipeError`)
  - File/line number references from stack traces
- **Intelligent log slicing** - Shows only the current operation by detecting the last "Worker Start" marker
- **Formatted duration display** - Shows job duration in MM:SS format
- **Automatic refresh** every 2 seconds with clean screen updates
- **Non-intrusive monitoring** - CTRL+C exits viewer without stopping the background job

**Visual Status Indicators:**
- 🔴 **Red**: Errors and failures
- 🟢 **Green**: Completed successfully
- 🟡 **Yellow**: Running operations

Access via menu option 7 or wait for completion to see the formatted summary.

### Log Viewer (Option 8) - **NEW!**

The dedicated log viewer provides quick access to recent activity:

**Features:**
- **Last 200 lines** of the log file displayed instantly
- **Full path display** showing exact log file location
- **Clean formatting** with section separators
- **Quick access** - View logs without stopping running jobs
- **CLI support** - Use `./borgbase_manager.sh log` for scripting

**Example Output:**
```
==========================================
                  Log viewer
==========================================

Showing last 200 lines of:
  /var/log/borgbase-manager.log
------------------------------------------
[Log content here]
------------------------------------------
Press Enter to return...
```

Access via:
- Menu option 8) Log
- CLI: `./borgbase_manager.sh log`

### Log Files

```bash
# View full log
sudo tail -f /var/log/borgbase-manager.log

# Check systemd journal
sudo journalctl -u borgbase-upload.service -f

# View last 200 lines (via script)
./borgbase_manager.sh log

# Watch live progress with filtering
./borgbase_manager.sh
# Then select option 7) Progress
```

### Success Summary

Upon completion, jobs display a formatted summary:

```
------------------------------------------
  SUCCESS SUMMARY
  Archive:  Backup-hostname-2025-01-26_14-30
  Duration: 05m:23s
  End:      2025-01-26 14:30:45
------------------------------------------
```

## 🛡️ Security Features

- ✅ **No hardcoded secrets** - all credentials via environment files
- ✅ **SSH key-based authentication** with automatic detection
- ✅ **Intelligent SSH key discovery** across all system users with 5-step priority
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
# Enable debug mode to see detection process
DEBUG=1 ./borgbase_manager.sh

# Check which keys are available
ls -la ~/.ssh/id_*
ls -la /root/.ssh/id_*  # if running as root

# Verify SSH config entries
grep -i "identityfile" ~/.ssh/config
grep -i "identityfile" /etc/ssh/ssh_config

# Test SSH connection manually
ssh -v user@user.repo.borgbase.com

# Explicitly specify SSH key in config
echo 'SSH_KEY="/path/to/your/key"' | sudo tee -a /etc/borgbase-manager.env

# Or set as environment variable temporarily
export SSH_KEY="/path/to/your/key"
./borgbase_manager.sh upload
```

**Common Issues:**
- Key file not readable (fix: `chmod 600 ~/.ssh/id_ed25519`)
- Key not in searched locations (fix: move to `~/.ssh/` or set `SSH_KEY`)
- Multiple keys but wrong one selected (fix: set `SSH_KEY` explicitly)

### Auto-Detection Fails

```bash
# Check what the script detected
DEBUG=1 ./borgbase_manager.sh

# Manually specify source directory
export SRC_DIR="/path/to/your/backup"
./borgbase_manager.sh upload

# Or add to config
echo 'SRC_DIR="/path/to/your/backup"' | sudo tee -a /etc/borgbase-manager.env

# Verify backup files exist
ls -la /path/to/your/backup/panzer_*.img.zst.gpg
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

# Verify SSH key ownership
ls -la ~/.ssh/id_ed25519

# If running as root, ensure key is accessible
sudo ls -la /home/user/.ssh/id_ed25519
```

### Job Appears Stuck

```bash
# View live progress with filtered logs
./borgbase_manager.sh
# Then select option 7) Progress

# Or view the raw log file
./borgbase_manager.sh log

# Check process status
ps aux | grep borg

# Check if repository is locked
borg info ssh://user@repo.borgbase.com/./repo
```

### Log Filtering Issues

If you need to see unfiltered logs (for debugging):

```bash
# View raw log file directly
sudo tail -f /var/log/borgbase-manager.log

# Or use less for scrolling
sudo less +F /var/log/borgbase-manager.log

# View specific number of lines
sudo tail -n 500 /var/log/borgbase-manager.log
```

The built-in viewer (option 7 and 8) automatically filters out technical noise while preserving essential information.

### EOF/Input Issues

If the interactive menu exits unexpectedly:

```bash
# Check if running in a proper terminal
tty

# Ensure input redirection isn't active
./borgbase_manager.sh < /dev/tty

# Use CLI mode if interactive mode fails
./borgbase_manager.sh upload  # Direct command
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
3. **Status Files**: Enable communication between processes with formatted updates
4. **PID Tracking**: Monitors running operations

**Worker Features:**
- Run in isolated environment (`env -i`)
- Start in new session (`setsid`) for independence
- Redirect output to log file with structured formatting
- Self-cleanup on completion or failure
- Comprehensive error handling with line number reporting
- Formatted duration tracking (MM:SS format)
- Success summaries with key metrics

### Status Tracking

The script maintains three types of status with enhanced formatting:

1. **Status File** (`/tmp/borg-status`): Current operation status with color-coded display
2. **PID File** (`/tmp/borg-upload.pid`): Running process ID
3. **Log File** (`/var/log/borgbase-manager.log`): Detailed operation log with worker boundaries

**Status Format Examples:**
- `UPLOAD: Abgeschlossen - Backup-host-2025-01-26_14-30 (Dauer: 05m:23s)`
- `DOWNLOAD: Abgeschlossen - Backup-host-2025-01-25_10-15 (Dauer: 03m:47s)`
- `FEHLER: Upload fehlgeschlagen (rc=1). Siehe Log.`

### Log Structure

Each worker run is clearly demarcated in the log:

```
==========================================
Worker Start (Upload): 2025-01-26 14:25:22
==========================================
[Operation logs...]
------------------------------------------
  SUCCESS SUMMARY
  Archive:  Backup-hostname-2025-01-26_14-30
  Duration: 05m:23s
  End:      2025-01-26 14:30:45
------------------------------------------
Worker Ende (Upload): 2025-01-26 14:30:45
==========================================
```

This structure enables the progress viewer (option 7) to intelligently display only the current operation.

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

This enables Bash's `set -x` mode, showing:
- Every command executed
- SSH key detection process
- Variable expansions
- Function calls

**Use debug mode to troubleshoot:**
- SSH key detection issues
- Auto-detection of backup directories
- Configuration loading problems
- Unexpected behavior

### Custom Compression

The script uses `lz4` compression by default for speed. To customize:

```bash
# Edit the worker script section in borgbase_manager.sh
# Find line: --compression lz4
# Change to: --compression zstd,10  # or other Borg compression options

# Available compression algorithms:
# lz4     - Fast compression (default)
# zstd,1  - Fast zstd (level 1)
# zstd,10 - Better zstd (level 10)
# zlib,6  - Standard zlib
# lzma,6  - Best compression (slowest)
```

### Multiple Repositories

You can manage multiple repositories by:

**1. Separate Environment Files:**
```bash
# Create multiple configs
sudo cp /etc/borgbase-manager.env /etc/borgbase-manager-repo1.env
sudo cp /etc/borgbase-manager.env /etc/borgbase-manager-repo2.env

# Edit each config with different REPO values
sudo nano /etc/borgbase-manager-repo1.env
sudo nano /etc/borgbase-manager-repo2.env
```

**2. Wrapper Scripts:**
```bash
# Copy and customize the script
sudo cp borgbase_manager.sh /usr/local/bin/borgbase_repo1.sh
sudo cp borgbase_manager.sh /usr/local/bin/borgbase_repo2.sh

# Edit each script to source different env file:
# Change line: if [[ -r /etc/borgbase-manager.env ]]; then . /etc/borgbase-manager.env; fi
# To:          if [[ -r /etc/borgbase-manager-repo1.env ]]; then . /etc/borgbase-manager-repo1.env; fi
```

**3. Environment Variable Override:**
```bash
# Use different repo per invocation
REPO="ssh://user1@repo1.borgbase.com/./repo" ./borgbase_manager.sh upload
REPO="ssh://user2@repo2.borgbase.com/./repo" ./borgbase_manager.sh upload
```

### Enhanced Monitoring

The script provides multiple monitoring levels:

1. **Quick Status**: Main menu shows current status with color coding
2. **Live Progress**: Option 7 for real-time filtered logs (refreshes every 2s)
3. **Full Log**: Option 8 for last 200 lines (static snapshot)
4. **Raw Logs**: Direct file access for complete history

**Monitoring Best Practices:**
- Use **Option 7** during active operations for real-time feedback
- Use **Option 8** to quickly check recent activity without interrupting jobs
- Use `tail -f` on log file for unfiltered debugging
- Enable `DEBUG=1` when troubleshooting configuration issues

## 🙏 Acknowledgments

- [BorgBackup](https://www.borgbackup.org/) - Deduplicating archiver with compression and encryption
- [BorgBase](https://www.borgbase.com/) - Hosting service for Borg repositories
- Panzerbackup community for backup workflows

---

**Made with ❤️ for secure, reliable backups**
