#!/usr/bin/env bash
set -euo pipefail

purge=0
if [[ ${1:-} == --purge ]]; then
  purge=1
  shift
fi
if (($#)); then
  echo "Usage: sudo $0 [--purge]" >&2
  exit 2
fi
[[ ${EUID} -eq 0 ]] || { echo "uninstall.sh must run as root" >&2; exit 1; }

systemctl disable --now handrail-network-relay.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/handrail-network-relay.service
rm -f /usr/local/bin/handrail-network-relay
rm -f /usr/local/bin/handrail-network-relay-update
rm -rf /usr/local/lib/handrail-network-relay
systemctl daemon-reload

if ((purge)); then
  rm -rf /etc/handrail-network-relay /var/lib/handrail-network-relay
  userdel handrail-relay >/dev/null 2>&1 || true
  groupdel handrail-relay >/dev/null 2>&1 || true
  echo "Handrail Network Relay removed, including configuration and state"
else
  echo "Handrail Network Relay removed; configuration and state were preserved"
fi
