#!/usr/bin/env bash
set -uo pipefail

trap 'echo; echo "Interrupted. Exiting cleanly..."; exit 1' INT TERM HUP

if [[ ! -t 0 || ! -t 1 ]]; then
  for terminal in gnome-terminal x-terminal-emulator xfce4-terminal konsole kitty alacritty; do
    if command -v "$terminal" >/dev/null 2>&1; then
      case "$terminal" in
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

REBOOT_AFTER=true
DRY_RUN=false
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
LOG_FILE="$SCRIPT_DIR/update-arch.log"
FAILED_STEPS=0

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

mkdir -p "$(dirname "$LOG_FILE")"
printf 'Update log started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" > "$LOG_FILE"

if [[ -t 0 && -t 1 ]]; then
  echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
else
  echo "Log file: $LOG_FILE" >> "$LOG_FILE"
fi

if [[ "$DRY_RUN" == false ]]; then
  # Cache the sudo credential once so all privileged commands can run without
  # prompting again for a password during the same session.
  sudo -v
fi

run_and_check() {
  local label="$1"
  shift

  echo
  echo "==> $label"

  if [[ "$DRY_RUN" == true ]]; then
    local command
    printf -v command ' %s' "$@"
    echo "[DRY RUN]$command" | tee -a "$LOG_FILE"
    return 0
  fi

  "$@" 2>&1 | tee -a "$LOG_FILE"
  local status=${PIPESTATUS[0]}

  if [[ "$status" -ne 0 ]]; then
    echo "!! FAILED: $label (exit code $status)" | tee -a "$LOG_FILE"
    ((FAILED_STEPS += 1))
  fi

  return 0
}

check_for_reboot() {
  if [[ "$REBOOT_AFTER" == true ]]; then
    if (( FAILED_STEPS > 0 )); then
      echo
      echo "Update completed with $FAILED_STEPS failed step(s). Review $LOG_FILE." | tee -a "$LOG_FILE"
    else
      echo
      echo "System update complete." | tee -a "$LOG_FILE"
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
        echo "Rebooting now..." | tee -a "$LOG_FILE"
        sudo reboot
        ;;
      *)
        echo "Reboot skipped by user." | tee -a "$LOG_FILE"
        ;;
    esac
  else
    echo
    if [[ "$DRY_RUN" == true ]]; then
      echo "Dry run complete. No system changes were made and reboot was skipped." | tee -a "$LOG_FILE"
    else
      echo "System update complete. Reboot skipped because --no-reboot was used." | tee -a "$LOG_FILE"
    fi
    if (( FAILED_STEPS > 0 )); then
      echo "There were $FAILED_STEPS failed step(s). Review $LOG_FILE." | tee -a "$LOG_FILE"
    fi
  fi
}

run_and_check "Refreshing Arch keyring" sudo pacman -Sy --noconfirm archlinux-keyring

run_and_check "Cleaning package cache" sudo pacman -Scc --noconfirm
run_and_check "Removing stale package downloads" sudo rm -rf /var/cache/pacman/pkg/download* 2>/dev/null || true

run_and_check "Updating system packages" sudo pacman -Syu --noconfirm

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

mapfile -t pacman_orphans < <(pacman -Qdtq 2>/dev/null || true)
if ((${#pacman_orphans[@]})); then
  run_and_check "Removing orphaned pacman packages" sudo pacman -Rns "${pacman_orphans[@]}"
else
  echo
  echo "==> No orphaned pacman packages found."
fi

if [[ -n "$AUR_HELPER" ]]; then
  mapfile -t aur_orphans < <("$AUR_HELPER" -Qdtq 2>/dev/null || true)
  if ((${#aur_orphans[@]})); then
    run_and_check "Removing orphaned $AUR_HELPER packages" "$AUR_HELPER" -Rns "${aur_orphans[@]}"
  else
    echo
    echo "==> No orphaned $AUR_HELPER packages found."
  fi
fi

if command -v flatpak >/dev/null 2>&1; then
  run_and_check "Updating Flatpak applications" flatpak update --noninteractive
else
  echo
  echo "==> flatpak is not installed; skipping Flatpak update."
fi

if systemctl list-unit-files reflector.service >/dev/null 2>&1; then
  run_and_check "Starting reflector service" sudo systemctl start reflector.service
else
  echo
  echo "==> reflector.service not found; skipping service start."
fi

if (( FAILED_STEPS > 0 )); then
  echo
  echo "Script finished with $FAILED_STEPS failed step(s). See $LOG_FILE for details."
fi

check_for_reboot
