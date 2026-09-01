#!/usr/bin/env bash
set -euo pipefail

if (($# != 2)); then
  echo "Usage: sudo $0 HTTPS_URL SHA256" >&2
  exit 2
fi
[[ ${EUID} -eq 0 ]] || { echo "update-from-url.sh must run as root" >&2; exit 1; }
url=$1
expected_sha256=$2
[[ $url == https://* ]] || { echo "only HTTPS update URLs are accepted" >&2; exit 2; }
[[ $expected_sha256 =~ ^[0-9a-fA-F]{64}$ ]] || { echo "invalid SHA-256 digest" >&2; exit 2; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
download_dir=$(mktemp -d -t handrail-relay-download.XXXXXXXX)
trap 'rm -rf "$download_dir"' EXIT HUP INT TERM
archive_path=${download_dir}/update.tar.gz
curl --fail --location --proto '=https' --tlsv1.2 --output "$archive_path" "$url"
"${script_dir}/remote-apply.sh" "$expected_sha256" "$archive_path"
