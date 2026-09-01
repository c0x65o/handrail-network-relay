#!/usr/bin/env bash
set -euo pipefail

unit_file=packaging/systemd/handrail-network-relay.service
expected_missing='handrail-network-relay.service: Command /usr/local/lib/handrail-network-relay/current/handrail-network-relay is not executable: No such file or directory'
set +e
output=$(systemd-analyze verify "$unit_file" 2>&1)
verify_status=$?
set -e

if ((verify_status == 0)); then
  exit 0
fi

unexpected=$(printf '%s\n' "$output" | grep -Fvx "$expected_missing" || true)
if [[ -n $unexpected ]]; then
  printf '%s\n' "$output" >&2
  exit "$verify_status"
fi

# The service executable exists only after installation. All other verifier
# diagnostics remain fatal.
grep -Fqx 'ExecStart=/usr/local/lib/handrail-network-relay/current/handrail-network-relay --config /etc/handrail-network-relay/config.ini run' "$unit_file"
