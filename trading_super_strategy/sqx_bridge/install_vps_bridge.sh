#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${1:-$(pwd)}"
TARGET_DIR="/opt/cygnus-sqx-vps-bridge"
CONFIG_DIR="/etc/cygnus-sqx-vps-bridge"
SERVICE_FILE="/etc/systemd/system/cygnus-sqx-vps-bridge.service"

if [ "${EUID}" -ne 0 ]; then
  echo "Run this installer as root." >&2
  exit 1
fi

id -u cygnus >/dev/null 2>&1 || useradd --system --home-dir "${TARGET_DIR}" --shell /usr/sbin/nologin cygnus
mkdir -p "${TARGET_DIR}" "${CONFIG_DIR}"
cp "${SOURCE_DIR}/vps_agent.py" "${TARGET_DIR}/vps_agent.py"
cp "${SOURCE_DIR}/vps_requirements.txt" "${TARGET_DIR}/requirements.txt"
python3 -m venv "${TARGET_DIR}/.venv"
"${TARGET_DIR}/.venv/bin/python" -m pip install --upgrade pip
"${TARGET_DIR}/.venv/bin/pip" install -r "${TARGET_DIR}/requirements.txt"
chown -R cygnus:cygnus "${TARGET_DIR}" "${CONFIG_DIR}"
chmod 750 "${TARGET_DIR}" "${CONFIG_DIR}"
cp "${SOURCE_DIR}/cygnus-sqx-vps-bridge.service" "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable cygnus-sqx-vps-bridge.service

echo "Installed. Pair first; the service should be started only after pairing."
