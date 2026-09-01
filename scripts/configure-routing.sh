#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: sudo $0 --config PATH" >&2
}

config_path=""
while (($#)); do
  case "$1" in
    --config)
      (($# >= 2)) || { usage; exit 2; }
      config_path=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -n $config_path && -f $config_path ]] || { echo "relay config not found: $config_path" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || { echo "configure-routing.sh must run as root" >&2; exit 1; }
for command_name in python3 tailscale; do
  command -v "$command_name" >/dev/null || { echo "required command not found: $command_name" >&2; exit 1; }
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
forwarding_script=${script_dir}/enable-forwarding.sh
[[ -x $forwarding_script ]] || { echo "forwarding helper not executable: $forwarding_script" >&2; exit 1; }

metadata_file=$(mktemp)
trap 'rm -f "$metadata_file"' EXIT HUP INT TERM
python3 - "$config_path" >"$metadata_file" <<'PY'
import configparser
import ipaddress
import sys

parser = configparser.ConfigParser(interpolation=None)
if not parser.read(sys.argv[1]) or "relay" not in parser:
    raise SystemExit("relay config is missing its [relay] section")

routes = []
for raw_route in parser["relay"].get("expected_subnets", "").split(","):
    value = raw_route.strip()
    if not value:
        continue
    route = ipaddress.ip_network(value, strict=True)
    if route.prefixlen == 0:
        raise SystemExit("default routes cannot be advertised by the relay lifecycle")
    normalized = str(route)
    if normalized not in routes:
        routes.append(normalized)
if not routes:
    raise SystemExit("relay.expected_subnets must contain at least one CIDR")

print(",".join(routes))
print("1" if any(ipaddress.ip_network(route).version == 4 for route in routes) else "0")
print("1" if any(ipaddress.ip_network(route).version == 6 for route in routes) else "0")
PY

mapfile -t routing_metadata <"$metadata_file"
[[ ${#routing_metadata[@]} -eq 3 && -n ${routing_metadata[0]} ]] || {
  echo "could not derive relay routing settings from config" >&2
  exit 1
}

forwarding_args=()
[[ ${routing_metadata[1]} == 1 ]] && forwarding_args+=(--ipv4)
[[ ${routing_metadata[2]} == 1 ]] && forwarding_args+=(--ipv6)
"$forwarding_script" "${forwarding_args[@]}"
tailscale set --advertise-routes="${routing_metadata[0]}"
echo "Tailscale routes advertised: ${routing_metadata[0]}"
