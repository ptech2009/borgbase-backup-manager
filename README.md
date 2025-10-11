# BorgBase Backup Manager

A secure, production-ready backup management tool for uploading and downloading Panzerbackup artifacts to/from BorgBase repositories using BorgBackup.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-5.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![BorgBackup](https://img.shields.io/badge/BorgBackup-1.2%2B-blue.svg)](https://www.borgbackup.org/)

## 🌟 Features

- **🌐 Bilingual Interface**: Full support for English and German
- **🔒 Security First**: No hardcoded secrets, SSH key authentication, GPG-encrypted backups
- **🔄 Automated Workflows**: systemd-friendly for scheduled backups
- **📊 Live Progress Monitoring**: Real-time status updates during backup operations
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

# Authentication
SSH_KEY="/path/to/your/id_ed25519"
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
8. **Exit** - Quit the manager

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

| Variable | Description | Default |
|----------|-------------|---------|
| `REPO` | BorgBase repository URL | *Required* |
| `SSH_KEY` | Path to SSH private key | *Required* |
| `PASSPHRASE_FILE` | Path to Borg passphrase | *Required* |
| `SRC_DIR` | Backup source directory | `/mnt/panzerbackup-pm` |
| `LOG_FILE` | Log file location | `/var/log/borgbase-manager.log` |
| `PRUNE` | Enable auto-pruning | `yes` |
| `KEEP_LAST` | Number of backups to retain | `7` |
| `UI_LANG` | Interface language (de/en) | `de` |

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

The script automatically searches for Panzerbackup volumes in:

- `/mnt/*panzerbackup*`
- `/media/*/*panzerbackup*`
- `/run/media/*/*panzerbackup*`
- Any mounted filesystem with "panzerbackup" in the path

Detection prioritizes the directory with the newest backup artifacts.

## 📊 Monitoring

### Live Progress

Option 7 in the interactive menu provides real-time monitoring:

- Current operation status
- Live log streaming
- Automatic refresh every 2 seconds
- Non-intrusive (CTRL+C to exit monitoring without stopping the job)

### Log Files

```bash
# View full log
sudo tail -f /var/log/borgbase-manager.log

# Check systemd journal
sudo journalctl -u borgbase-upload.service -f
```

## 🛡️ Security Features

- ✅ No secrets in script code
- ✅ SSH key-based authentication
- ✅ Encrypted repository passphrases
- ✅ GPG-encrypted backup images
- ✅ Workers run with minimal environment (`env -i`)
- ✅ Secure file permissions enforcement
- ✅ Lock file protection against concurrent operations

## 🐛 Troubleshooting

### Repository Locked

```bash
# If a job was interrupted, manually break lock
borg break-lock ssh://user@repo.borgbase.com/./repo
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
