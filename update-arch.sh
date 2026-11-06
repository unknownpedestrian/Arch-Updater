#!/usr/bin/env bash
set -uo pipefail

# default variables
REBOOT_AFTER=true
DRY_RUN=false
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
LOG_FILE="$SCRIPT_DIR/update-arch.log"
WARNING_LOCK_FILE="$SCRIPT_DIR/.acknowledged-lock"
FAILED_STEPS=0
OFFICIAL_UPDATES=0
AUR_UPDATES=0
FLATPAK_UPDATES=0
IGNORED_PACKAGES=()
AUR_IGNORED_PACKAGES=()

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
  echo "systemd-inhibit started (PID $INHIBITOR_PID) to prevent sleep and screen locking." 
else
  echo "systemd-inhibit is unavailable; screen locking and sleep may occur." >&2
fi
## BIG SCARY WARNING
if [[ "$DRY_RUN" == false && ! -e "$WARNING_LOCK_FILE" ]]; then
  echo
  echo "By running this script, you are granting it permission to execute" 
  echo "commands with elevated privileges (sudo) as needed for system updates"
  echo 
  echo "The script will prompt for your password."
  echo
  echo "If you do not wish to grant this permission, please exit the script now (Ctrl+C)."
  echo
  echo "By proceeding, you acknowledge that you understand the implications of" 
  echo "granting elevated privileges and accept responsibility for any" 
  echo "changes made to your system."
  echo
  echo "This warning will only be shown once."
  echo
  sleep 20
  touch "$WARNING_LOCK_FILE" # only show this once per user
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

# counter logic
count_updates() {
  local package_manager="$1"

  "$package_manager" -Qu 2>/dev/null | awk '/ -> / { count++ } END { print count + 0 }'
}

# Retry pacman once while ignoring packages it reports as breaking dependencies.
update_pacman_packages() {
  local output_file status
  local ignored_list

  echo
  echo "==> Updating system packages"

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY RUN] sudo pacman -Syu --noconfirm"
    return 0
  fi

  output_file=$(mktemp) || {
    echo "!! FAILED: Updating system packages (could not create temporary output file)"
    ((FAILED_STEPS += 1))
    return 0
  }

  sudo pacman -Syu --noconfirm 2>&1 | tee "$output_file"
  status=${PIPESTATUS[0]}

  if [[ "$status" -ne 0 ]]; then
    mapfile -t IGNORED_PACKAGES < <(
      awk '
        / breaks dependency / {
          for (i = 1; i < NF; i++) {
            if ($i == "installing" || $i == "upgrading" || $i == "downgrading") {
              print $(i + 1)
              break
            }
          }
        }
      ' "$output_file" | sort -u
    )

    if ((${#IGNORED_PACKAGES[@]})); then
      echo
      printf 'Pacman reported dependency-breaking packages: %s\n' "${IGNORED_PACKAGES[*]}"
      echo "Retrying the system update with these packages ignored."
      local IFS=,
      ignored_list="${IGNORED_PACKAGES[*]}"

      sudo pacman -Syu --noconfirm --ignore "$ignored_list" 2>&1 | tee "$output_file"
      status=${PIPESTATUS[0]}
    fi
  fi

  rm -f "$output_file"

  if [[ "$status" -ne 0 ]]; then
    echo "!! FAILED: Updating system packages (exit code $status)"
    ((FAILED_STEPS += 1))
  fi

  return 0
}

# Retry the selected AUR helper once while ignoring reported dependency breakers.
update_aur_packages() {
  local output_file status ignored_list

  echo
  echo "==> Updating AUR packages"

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY RUN] $AUR_HELPER -Syu --noconfirm"
    return 0
  fi

  output_file=$(mktemp) || {
    echo "!! FAILED: Updating AUR packages (could not create temporary output file)"
    ((FAILED_STEPS += 1))
    return 0
  }

  "$AUR_HELPER" -Syu --noconfirm 2>&1 | tee "$output_file"
  status=${PIPESTATUS[0]}

  if [[ "$status" -ne 0 ]]; then
    mapfile -t AUR_IGNORED_PACKAGES < <(
      awk '
        / breaks dependency / {
          for (i = 1; i < NF; i++) {
            if ($i == "installing" || $i == "upgrading" || $i == "downgrading") {
              print $(i + 1)
              break
            }
          }
        }
      ' "$output_file" | sort -u
    )

    if ((${#AUR_IGNORED_PACKAGES[@]})); then
      echo
      printf '%s reported dependency-breaking packages: %s\n' "$AUR_HELPER" "${AUR_IGNORED_PACKAGES[*]}"
      echo "Retrying the AUR update with these packages ignored."
      local IFS=,
      ignored_list="${AUR_IGNORED_PACKAGES[*]}"

      "$AUR_HELPER" -Syu --noconfirm --ignore "$ignored_list" 2>&1 | tee "$output_file"
      status=${PIPESTATUS[0]}
    fi
  fi

  rm -f "$output_file"

  if [[ "$status" -ne 0 ]]; then
    echo "!! FAILED: Updating AUR packages (exit code $status)"
    ((FAILED_STEPS += 1))
  fi

  return 0
}

# count flatpaks differently
count_flatpak_updates() {
  flatpak remote-ls --updates --app --columns=ref 2>/dev/null \
    | awk 'NF { count++ } END { print count + 0 }'
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

OFFICIAL_UPDATES=$(count_updates pacman) # update counter
update_pacman_packages

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
  AUR_UPDATES=$(count_updates "$AUR_HELPER") # update counter
  run_and_check "Cleaning $AUR_HELPER cache" "$AUR_HELPER" -Scc --noconfirm
  update_aur_packages
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
  FLATPAK_UPDATES=$(count_flatpak_updates) # update counter
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
# print summary of updates
echo
echo "Packages selected for upgrade: $((OFFICIAL_UPDATES + AUR_UPDATES + FLATPAK_UPDATES))"
echo "  Official repository packages: $OFFICIAL_UPDATES"
echo "  AUR packages: $AUR_UPDATES"
echo "  Flatpak applications: $FLATPAK_UPDATES"
if ((${#IGNORED_PACKAGES[@]})); then
  echo "Packages ignored by pacman due to dependency breaks: ${IGNORED_PACKAGES[*]}"
else
  echo "Packages ignored by pacman due to dependency breaks: none"
fi
if ((${#AUR_IGNORED_PACKAGES[@]})); then
  echo "Packages ignored by $AUR_HELPER due to dependency breaks: ${AUR_IGNORED_PACKAGES[*]}"
else
  echo "Packages ignored by AUR helper due to dependency breaks: none"
fi
# finish up
check_for_reboot
