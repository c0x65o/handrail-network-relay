#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --host HOST --user USER --artifact FILE [--port PORT] [--identity FILE] [--config FILE]" >&2
}

host=""
user=""
artifact=""
port=22
identity=""
config=""
while (($#)); do
  case "$1" in
    --host) host=${2:-}; shift 2 ;;
    --user) user=${2:-}; shift 2 ;;
    --artifact) artifact=${2:-}; shift 2 ;;
    --port) port=${2:-}; shift 2 ;;
    --identity) identity=${2:-}; shift 2 ;;
    --config) config=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n $host && -n $user && -n $artifact ]] || { usage; exit 2; }
[[ $host =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "invalid host" >&2; exit 2; }
[[ $user =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { echo "invalid user" >&2; exit 2; }
[[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || { echo "invalid port" >&2; exit 2; }
[[ -f $artifact ]] || { echo "artifact not found: $artifact" >&2; exit 1; }
if [[ -n $config ]]; then
  [[ -f $config ]] || { echo "config not found: $config" >&2; exit 1; }
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ssh_options=(-o BatchMode=yes -o ConnectTimeout=15 -p "$port")
scp_options=(-o BatchMode=yes -o ConnectTimeout=15 -P "$port")
if [[ -n $identity ]]; then
  [[ -f $identity ]] || { echo "identity not found: $identity" >&2; exit 1; }
  ssh_options+=(-i "$identity" -o IdentitiesOnly=yes)
  scp_options+=(-i "$identity" -o IdentitiesOnly=yes)
fi

checksum=$(sha256sum "$artifact" | awk '{print $1}')
destination=${user}@${host}
remote_dir=$(ssh "${ssh_options[@]}" "$destination" 'mktemp -d -t handrail-relay-update.XXXXXXXX')
[[ $remote_dir == /tmp/handrail-relay-update.* ]] || {
  echo "remote host returned an unexpected temporary path" >&2
  exit 1
}
remote_archive=${remote_dir}/update.tar.gz
remote_config=""
cleanup() {
  ssh "${ssh_options[@]}" "$destination" "rm -rf -- '$remote_dir'" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
scp "${scp_options[@]}" -- "$artifact" "${destination}:${remote_archive}"
if [[ -n $config ]]; then
  remote_config=${remote_dir}/config.ini
  scp "${scp_options[@]}" -- "$config" "${destination}:${remote_config}"
fi
ssh "${ssh_options[@]}" "$destination" \
  "sudo sh -s -- '$checksum' '$remote_archive' '$remote_config'" <"${script_dir}/remote-apply.sh"
cleanup
trap - EXIT HUP INT TERM
echo "Update installed on ${destination}"
