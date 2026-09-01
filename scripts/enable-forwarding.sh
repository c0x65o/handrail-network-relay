#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: sudo $0 [--ipv4] [--ipv6]" >&2
}

enable_ipv4=0
enable_ipv6=0
while (($#)); do
  case "$1" in
    --ipv4) enable_ipv4=1 ;;
    --ipv6) enable_ipv6=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done
((enable_ipv4 || enable_ipv6)) || { usage; exit 2; }
[[ ${EUID} -eq 0 ]] || { echo "enable-forwarding.sh must run as root" >&2; exit 1; }
command -v sysctl >/dev/null || { echo "required command not found: sysctl" >&2; exit 1; }

settings_file=/etc/sysctl.d/90-handrail-network-relay.conf
temporary_file=$(mktemp)
trap 'rm -f "$temporary_file"' EXIT HUP INT TERM
{
  echo "# Managed by Handrail Network Relay setup"
  ((enable_ipv4)) && echo "net.ipv4.ip_forward = 1"
  ((enable_ipv6)) && echo "net.ipv6.conf.all.forwarding = 1"
} >"$temporary_file"
install -o root -g root -m 0644 "$temporary_file" "$settings_file"
sysctl -p "$settings_file"
echo "Packet forwarding configured in ${settings_file}"
