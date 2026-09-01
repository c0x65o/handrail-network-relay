#!/bin/sh
set -eu

expected_sha256=${1:?expected SHA-256 is required}
archive_path=${2:?archive path is required}
config_path=${3:-}
case "$expected_sha256" in
  *[!0-9a-fA-F]*|'') echo "invalid SHA-256 digest" >&2; exit 2 ;;
esac
[ ${#expected_sha256} -eq 64 ] || { echo "invalid SHA-256 digest" >&2; exit 2; }
[ -f "$archive_path" ] || { echo "update archive not found" >&2; exit 1; }
if [ -n "$config_path" ] && [ ! -f "$config_path" ]; then
  echo "relay config not found" >&2
  exit 1
fi

actual_sha256=$(sha256sum "$archive_path" | awk '{print $1}')
[ "$actual_sha256" = "$expected_sha256" ] || {
  echo "update archive checksum mismatch" >&2
  exit 1
}

extract_dir=$(mktemp -d -t handrail-relay-extract.XXXXXXXX)
cleanup() {
  rm -rf "$extract_dir"
  rm -f "$archive_path"
}
trap cleanup EXIT HUP INT TERM
tar --no-same-owner -xzf "$archive_path" -C "$extract_dir"
install_script=$(find "$extract_dir" -mindepth 3 -maxdepth 3 -type f -path '*/scripts/install.sh' -print)
[ -n "$install_script" ] && [ "$(printf '%s\n' "$install_script" | wc -l)" -eq 1 ] || {
  echo "update archive does not contain exactly one installer" >&2
  exit 1
}
exec_root=$(dirname "$(dirname "$install_script")")
version_file=${exec_root}/VERSION
[ -f "$version_file" ] || { echo "update archive is missing VERSION" >&2; exit 1; }
if [ -n "$config_path" ]; then
  "$install_script" --config "$config_path"
else
  "$install_script"
fi
