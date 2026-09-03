# Arch Updater

This repository contains a Bash script that performs a routine Arch Linux update workflow with a few convenience safeguards.

## What the script does

The script will:

- refresh the Arch keyring
- clear the package cache
- remove stale package downloads
- update core system packages via `pacman`
- update AUR packages if `yay` or `paru` is installed
- remove orphaned packages from both pacman and the AUR helper
- update Flatpak packages when `flatpak` is installed
- start the `reflector.service` if it exists (currently only SYSTEMD)
- optionally reboot after a successful update
- write actions and output to a log file

## Files

- `update-arch.sh` — the main update script
- `update-arch.log` — created at runtime and stores the update output

## Usage

Run the script directly:

```bash
./update-arch.sh
```

Available options:

```bash
./update-arch.sh --dry-run
./update-arch.sh --no-reboot
./update-arch.sh --help
```

### Options

- `--dry-run` prints the commands that would run without changing the system
- `--no-reboot` skips the reboot prompt after the update completes
- `--help` shows the usage message

## Requirements

This script is intended for Arch Linux systems and assumes:

- `sudo` is available and configured
- `pacman` is installed
- `yay` or `paru` may be installed for AUR updates
- `flatpak` may be installed for Flatpak updates

## Notes

- The script creates a log file in the same directory as the script named `update-arch.log`.
- It prompts for a reboot by default when the update completes without failures.

## Safety note

This script performs package management and can remove orphaned packages and clear caches. Review the script before running it on a system that you want to keep in a very specific state.
