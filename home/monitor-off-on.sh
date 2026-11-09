#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
USER_NAME="${USER_NAME:-${SUDO_USER:-${USER:-}}}"

if [[ -z "$ACTION" || ! "$ACTION" =~ ^(on|off)$ ]]; then
  echo "Usage: $0 {on|off}"
  echo "Optional env: USER_NAME=<user>"
  exit 2
fi

if [[ -z "${USER_NAME}" ]]; then
  echo "Error: set USER_NAME=youruser"
  exit 1
fi

UID_NUM="$(id -u "$USER_NAME")"
RUNTIME_DIR="/run/user/${UID_NUM}"

SOCK="$(ls -t "$RUNTIME_DIR"/sway-ipc.*.sock 2>/dev/null | head -n 1 || true)"
if [[ -z "$SOCK" ]]; then
  echo "Error: No sway socket found in $RUNTIME_DIR. Is Sway running for $USER_NAME?"
  exit 1
fi

# Decide si usar sudo o no
if [[ "$(id -un)" == "$USER_NAME" ]]; then
  CMD=(env XDG_RUNTIME_DIR="$RUNTIME_DIR" SWAYSOCK="$SOCK" swaymsg)
else
  CMD=(sudo -n -u "$USER_NAME" env XDG_RUNTIME_DIR="$RUNTIME_DIR" SWAYSOCK="$SOCK" swaymsg)
fi

# Apaga/enciende TODOS los outputs activos
"${CMD[@]}" "output * dpms $ACTION" >/dev/null
echo "OK: dpms $ACTION"

