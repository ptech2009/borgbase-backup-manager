# BorgBase Backup Manager

A secure, production-ready backup management tool for uploading and downloading Panzerbackup artifacts to/from BorgBase repositories using BorgBackup.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-5.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![BorgBackup](https://img.shields.io/badge/BorgBackup-1.2%2B-blue.svg)](https://www.borgbackup.org/)

## 🌟 Features

- **🌐 Bilingual Interface**: Full support for English and German
- **🔒 Security First**: No hardcoded secrets, SSH key authentication, GPG-encrypted backups
- **🔑 Smart SSH Key Detection**: Automatic discovery of SSH keys from multiple sources
- **🔄 Automated Workflows**: systemd-friendly for scheduled backups
- **📊 Live Progress Monitoring**: Real-time status updates during backup operations
- **📝 Integrated Log Viewer**: View log files directly from the menu
- **🎯 Smart Auto-Detection**: Automatically finds Panzerbackup volumes
- **🖥️ Interactive TUI**: User-friendly menu-driven interface
- **⚙️ CLI Support**: Direct command-line operations for automation
- **🧹 Automatic Pruning**: Configurable retention policies with compact operation

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
# BorgBase Repository
REPO="ssh://your_user@your_user.repo.borgbase.com/./repo"

# Authentication (SSH key is auto-detected if not specified)
SSH_KEY="/path/to/your/id_ed25519"  # Optional - will be auto-detected
PASSPHRASE_FILE="/secure/path/to/passphrase"

# Backup Source (auto-detected if mounted)
SRC_DIR="/mnt/panzerbackup-pm"

# Logging
LOG_FILE="/var/log/borgbase-manager.log"

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
7. **Progress** - Live progress monitoring
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

The script automatically detects SSH keys in the following order:

1. **Environment Variable**: `SSH_KEY` from configuration file
2. **SSH Config File**: `IdentityFile` entries matching the repository host
   - `~/.ssh/config` (current user)
   - `/home/$SUDO_USER/.ssh/config` (when running as root via sudo)
3. **Standard Key Locations**: Common SSH key filenames in:
   - `~/.ssh/` (current user)
   - `/root/.ssh/` (when running as root)
   - `/home/$SUDO_USER/.ssh/` (when running as root via sudo)

**Priority:**
- Ed25519 keys are preferred over RSA keys
- If no key file is found, the script falls back to SSH agent or default SSH behavior

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

The script will automatically use `id_ed25519_borgbase` when connecting to BorgBase.

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
| `PRUNE` | Enable auto-pruning | `yes` | ❌ No |
| `KEEP_LAST` | Number of backups to retain | `7` | ❌ No |
| `UI_LANG` | Interface language (de/en) | `de` | ❌ No |

\* If not specified, passphrase must be provided via `BORG_PASSPHRASE` environment variable or SSH agent  
\** Auto-detected if Panzerbackup volume is mounted

### Configuration Priority

1. `/etc/borgbase-manager.env` (recommended)
2. `./.env` (local override)
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

## 🔍 Auto-Detection

### Backup Directory Detection

The script automatically searches for Panzerbackup volumes in:

- `/mnt/*panzerbackup*`
- `/media/*/*panzerbackup*`
- `/run/media/*/*panzerbackup*`
- Any mounted filesystem with "panzerbackup" in the path (via `findmnt`)

Detection prioritizes the directory with the newest backup artifacts.

### SSH Key Detection

SSH keys are automatically detected from:

1. Configuration files (`SSH_KEY` variable)
2. SSH config files (`~/.ssh/config`)
3. Standard SSH key directories (`~/.ssh/`, `/root/.ssh/`)

Ed25519 keys are preferred for enhanced security.

## 📊 Monitoring

### Live Progress

Option 7 in the interactive menu provides real-time monitoring:

- Current operation status
- Live log streaming
- Automatic refresh every 2 seconds
- Non-intrusive (CTRL+C to exit monitoring without stopping the job)

### Log Viewer

Option 8 in the interactive menu displays:

- Last 200 lines of the log file
- Full path to log file
- Formatted output for easy reading

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

- ✅ No secrets in script code
- ✅ SSH key-based authentication
- ✅ Intelligent SSH key auto-detection
- ✅ Encrypted repository passphrases
- ✅ GPG-encrypted backup images
- ✅ Workers run with minimal environment (`env -i`)
- ✅ Secure file permissions enforcement
- ✅ Lock file protection against concurrent operations
- ✅ SSH agent support as fallback

## 🐛 Troubleshooting

### Repository Locked

```bash
# If a job was interrupted, manually break lock
borg break-lock ssh://user@repo.borgbase.com/./repo
```

### SSH Key Not Found

The script will automatically detect SSH keys. If detection fails:

```bash
# Explicitly specify SSH key in config
export SSH_KEY="/path/to/your/key"

# Or add to /etc/borgbase-manager.env
echo 'SSH_KEY="/path/to/your/key"' | sudo tee -a /etc/borgbase-manager.env

# Check which key would be used
ssh -v user@user.repo.borgbase.com
```

### Auto-Detection Fails

```bash
# Manually specify source directory
export SRC_DIR="/path/to/your/backup"
./borgbase_manager.sh upload
```

### Permission Denied

```bash
# Ensure proper ownership and permissions
sudo chown -R root:root /etc/borgbase-manager.env
sudo chmod 600 /etc/borgbase-manager.env
sudo chmod 400 /secure/path/to/passphrase

# Check SSH key permissions
chmod 600 ~/.ssh/id_ed25519
```

### View Logs

```bash
# Use built-in log viewer
./borgbase_manager.sh log

# Or view directly
sudo tail -f /var/log/borgbase-manager.log
```

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

## 🙏 Acknowledgments

- [BorgBackup](https://www.borgbackup.org/) - Deduplicating archiver with compression and encryption
- [BorgBase](https://www.borgbase.com/) - Hosting service for Borg repositories
- Panzerbackup community for backup workflows

---

**Made with ❤️ for secure, reliable backups**
