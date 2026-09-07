#!/usr/bin/env bash
set -uo pipefail

# default variables
REBOOT_AFTER=true
DRY_RUN=false
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
LOG_FILE="$SCRIPT_DIR/update-arch.log"
FAILED_STEPS=0

# set up cleanup for systemd-inhibit
INHIBITOR_PID=""
cleanup_inhibitor() {
  if [[ -n "$INHIBITOR_PID" ]] && kill -0 "$INHIBITOR_PID" 2>/dev/null; then
    printf 'Terminating system inhibitor (PID %s)...\n' "$INHIBITOR_PID"
    kill "$INHIBITOR_PID" 2>/dev/null || true
    wait "$INHIBITOR_PID" 2>/dev/null || true
    printf 'System inhibitor (PID %s) terminated.\n' "$INHIBITOR_PID"
  else
    printf 'Inhibitor not running or already terminated.\n'
  fi
}
# handle interrupts
trap 'echo; echo "Interrupted. Exiting cleanly..."; exit 1' INT TERM HUP
# make cleanup happen on exit
trap cleanup_inhibitor EXIT
# find a terminal emulator to run in if not running in one
if [[ ! -t 0 || ! -t 1 ]]; then
  for terminal in gnome-terminal x-terminal-emulator xfce4-terminal konsole kitty alacritty; do
    if command -v "$terminal" >/dev/null 2>&1; then
      case "$terminal" in
        # your favorite terminal here, add more if you want
        gnome-terminal)
          exec gnome-terminal -- bash -lc 'bash "$1" "${@:2}"; exit $?' _ "$0" "$@"
          ;;
        x-terminal-emulator|xfce4-terminal)
          exec "$terminal" -- bash -lc 'bash "$1" "${@:2}"; exit $?' _ "$0" "$@"
          ;;
        konsole)
          exec konsole -e bash -lc 'bash "$1" "${@:2}"; exit $?' _ "$0" "$@"
          ;;
        kitty)
          exec kitty bash -lc 'bash "$1" "${@:2}"; exit $?' _ "$0" "$@"
          ;;
        alacritty)
          exec alacritty -e bash -lc 'bash "$1" "${@:2}"; exit $?' _ "$0" "$@"
          ;;
      esac
    fi
  done

  echo "This script must be run from a terminal." >&2
  exit 1
fi
# command line arguments
case "${1:-}" in
  --no-reboot)
    REBOOT_AFTER=false
    ;;
  --dry-run)
    DRY_RUN=true
    REBOOT_AFTER=false
    ;;
  --help)
    echo "Usage: $0 [--no-reboot|--dry-run]"
    exit 0
    ;;
esac
# make log file
mkdir -p "$(dirname "$LOG_FILE")"
printf 'Update log started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1 ## send everything to the log file
echo "Log file: $LOG_FILE"

# try to prevent system sleep and screen locking
if command -v systemd-inhibit >/dev/null 2>&1; then
  systemd-inhibit --what=idle:sleep:handle-lid-switch \
    --why="Updates are in progress" --mode=block sleep infinity &
  INHIBITOR_PID=$!
  printf "systemd-inhibit started (PID $INHIBITOR_PID) to prevent sleep and screen locking."
else
  printf "systemd-inhibit is unavailable; screen locking and sleep may occur." >&2
fi

if [[ "$DRY_RUN" == false ]]; then
  # Cache the sudo credential once so all privileged commands can run without
  # prompting again for a password during the same session.
  sudo -v
fi

# main loop
run_and_check() {
  local label="$1"
  shift

  echo
  echo "==> $label"

  if [[ "$DRY_RUN" == true ]]; then
    local command
    printf -v command ' %s' "$@"
    echo "[DRY RUN]$command"
    return 0
  fi

  "$@"
  local status=$?

  if [[ "$status" -ne 0 ]]; then
    echo "!! FAILED: $label (exit code $status)"
    ((FAILED_STEPS += 1))
  fi

  return 0
}
# reboot logic
check_for_reboot() {
  if [[ "$REBOOT_AFTER" == true ]]; then
    if (( FAILED_STEPS > 0 )); then
      echo
      echo "Update completed with $FAILED_STEPS failed step(s). Review $LOG_FILE."
    else
      echo
      echo "System update complete."
    fi

    echo "Log file: $LOG_FILE"
    echo "Would you like to reboot now? [Y/n] (default: yes, timeout in 10s)"
    read -r -s -n 1 -t 10 answer || answer="y"
    case "$answer" in
      "")
        answer="y"
        ;;
    esac
    case "$answer" in
      [Yy]|[Yy][Ee][Ss])
        echo "Rebooting now..."
        sudo reboot
        ;;
      *)
        echo "Reboot skipped by user."
        ;;
    esac
  else
    echo
    if [[ "$DRY_RUN" == true ]]; then
      echo "Dry run complete. No system changes were made and reboot was skipped."
    else
      echo "System update complete. Reboot skipped because --no-reboot was used."
    fi
    if (( FAILED_STEPS > 0 )); then
      echo "There were $FAILED_STEPS failed step(s). Review $LOG_FILE."
    fi
  fi
}
## ----- main script execution ------ ##
run_and_check "Refreshing Arch keyring" sudo pacman -Sy --noconfirm archlinux-keyring

run_and_check "Cleaning package cache" sudo pacman -Scc --noconfirm
# remove packages that pacman misses (hotfix)
run_and_check "Tidying package cache" sudo rm -rf /var/cache/pacman/pkg/download* 2>/dev/null || true

run_and_check "Updating system packages" sudo pacman -Syu --noconfirm

# check for AUR helpers
if command -v yay >/dev/null 2>&1 && command -v paru >/dev/null 2>&1; then
  AUR_HELPER=""
  echo
  echo "==> Multiple AUR helpers are installed; skipping AUR update."
  echo "    Manual intervention may be required because the helpers may conflict."
elif command -v yay >/dev/null 2>&1; then
  AUR_HELPER="yay"
elif command -v paru >/dev/null 2>&1; then
  AUR_HELPER="paru"
else
  AUR_HELPER=""
  echo
  echo "==> No AUR helper is installed; skipping AUR update."
fi

if [[ -n "$AUR_HELPER" ]]; then
  run_and_check "Cleaning $AUR_HELPER cache" "$AUR_HELPER" -Scc --noconfirm
  run_and_check "Updating AUR packages" "$AUR_HELPER" -Syu --noconfirm
fi
# map unused orphans (pacman)
mapfile -t pacman_orphans < <(pacman -Qdtq 2>/dev/null || true)
if ((${#pacman_orphans[@]})); then
  # clean orphans
  run_and_check "Removing orphaned pacman packages" sudo pacman -Rns --noconfirm "${pacman_orphans[@]}"
else
  echo
  echo "==> No orphaned pacman packages found."
fi
# map unused orphans (AUR)
if [[ -n "$AUR_HELPER" ]]; then
  mapfile -t aur_orphans < <("$AUR_HELPER" -Qdtq 2>/dev/null || true)
  if ((${#aur_orphans[@]})); then
   # clean orphans
    run_and_check "Removing orphaned $AUR_HELPER packages" "$AUR_HELPER" -Rns --noconfirm "${aur_orphans[@]}"
  else
    echo
    echo "==> No orphaned $AUR_HELPER packages found."
  fi
fi
# flapak 
if command -v flatpak >/dev/null 2>&1; then
  run_and_check "Updating Flatpak applications" flatpak update --noninteractive
else
  echo
  echo "==> flatpak is not installed; skipping Flatpak update."
fi
# reflector
if systemctl list-unit-files reflector.service >/dev/null 2>&1; then
  run_and_check "Starting reflector service" sudo systemctl start reflector.service
else
  echo
  echo "==> reflector.service not found; skipping service start."
fi
## ----- main script execution end ------ ##

if (( FAILED_STEPS > 0 )); then
  echo
  echo "Script finished with $FAILED_STEPS failed step(s). See $LOG_FILE for details."
fi
# finish up
check_for_reboot
