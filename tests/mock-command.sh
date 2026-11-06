#!/usr/bin/env bash
set -uo pipefail

command_name=${0##*/}
printf '%s' "$command_name" >> "$TEST_CALL_LOG"
printf '\t%s' "$@" >> "$TEST_CALL_LOG"
printf '\n' >> "$TEST_CALL_LOG"

has_ignore=false
for argument in "$@"; do
  if [[ "$argument" == --ignore ]]; then
    has_ignore=true
  fi
done

case "$command_name" in
  sudo)
    case "${1:-}" in
      -v)
        exit 0
        ;;
      pacman)
        shift
        exec "$MOCK_BIN/pacman" "$@"
        ;;
      rm)
        shift
        exec "$MOCK_BIN/rm" "$@"
        ;;
      systemctl)
        shift
        exec "$MOCK_BIN/systemctl" "$@"
        ;;
      reboot)
        exit 0
        ;;
    esac
    exit 0
    ;;
  pacman)
    case "${1:-}" in
      -Qu)
        printf 'official-one 1 -> 2\nofficial-two 1 -> 2\n'
        ;;
      -Qdtq)
        printf '%s\n' "$TEST_PACMAN_ORPHANS"
        ;;
      -Syu)
        if [[ "$TEST_PACMAN_MODE" == dependency && "$has_ignore" == false ]]; then
          printf "error: installing blocked-one (2.0) breaks dependency 'blocked-one=1.0' required by app-one\n"
          printf "error: installing blocked-two (3.0) breaks dependency 'blocked-two<3.0' required by app-two\n"
          printf "error: upgrading blocked-one (2.1) breaks dependency 'blocked-one=2.0' required by app-three\n"
          exit 1
        elif [[ "$TEST_PACMAN_MODE" == failure ]]; then
          printf 'error: failed to commit transaction (conflicting files)\n'
          exit 1
        fi
        ;;
    esac
    ;;
  yay|paru)
    case "${1:-}" in
      -Qu)
        printf 'aur-one 1 -> 2\n'
        ;;
      -Qdtq)
        printf '%s\n' "$TEST_AUR_ORPHANS"
        ;;
      -Syu)
        if [[ "$TEST_AUR_MODE" == dependency && "$has_ignore" == false ]]; then
          printf "error: installing aur-blocked-one (2.0) breaks dependency 'aur-blocked-one=1.0' required by app-one\n"
          printf "error: upgrading aur-blocked-two (3.0) breaks dependency 'aur-blocked-two<3.0' required by app-two\n"
          exit 1
        elif [[ "$TEST_AUR_MODE" == failure ]]; then
          printf 'error: failed to build package\n'
          exit 1
        fi
        ;;
    esac
    ;;
  flatpak)
    if [[ "${1:-}" == remote-ls ]]; then
      printf 'org.example.App\n'
    fi
    ;;
  systemctl)
    if [[ "${1:-}" == list-unit-files ]]; then
      if [[ "$TEST_REFLECTOR" == true ]]; then
        exit 0
      else
        exit 1
      fi
    fi
    ;;
  rm)
    if [[ "${1:-}" == -f ]]; then
      exec "$TEST_REAL_RM" "$@"
    fi
    ;;
  systemd-inhibit|sleep)
    exit 0
    ;;
esac

exit 0