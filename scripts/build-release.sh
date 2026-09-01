#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_root=$(cd -- "${script_dir}/.." && pwd)
version=$(<"${source_root}/VERSION")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || {
  echo "VERSION is not a supported release version: $version" >&2
  exit 1
}

dist_dir=${source_root}/dist
artifact_name="handrail-network-relay-${version}"
staging_dir=$(mktemp -d)
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "${staging_dir}/${artifact_name}/src"
mkdir -p "${staging_dir}/${artifact_name}/config"
mkdir -p "${staging_dir}/${artifact_name}/packaging/systemd"
mkdir -p "${staging_dir}/${artifact_name}/scripts"

install -m 0644 "${source_root}/VERSION" "${staging_dir}/${artifact_name}/VERSION"
install -m 0644 "${source_root}/README.md" "${staging_dir}/${artifact_name}/README.md"
install -m 0755 "${source_root}/src/handrail_network_relay.py" "${staging_dir}/${artifact_name}/src/handrail_network_relay.py"
install -m 0644 "${source_root}/config/config.example.ini" "${staging_dir}/${artifact_name}/config/config.example.ini"
install -m 0644 "${source_root}/packaging/systemd/handrail-network-relay.service" "${staging_dir}/${artifact_name}/packaging/systemd/handrail-network-relay.service"
install -m 0755 "${source_root}/scripts/install.sh" "${staging_dir}/${artifact_name}/scripts/install.sh"
install -m 0755 "${source_root}/scripts/uninstall.sh" "${staging_dir}/${artifact_name}/scripts/uninstall.sh"
install -m 0755 "${source_root}/scripts/enable-forwarding.sh" "${staging_dir}/${artifact_name}/scripts/enable-forwarding.sh"
install -m 0755 "${source_root}/scripts/remote-apply.sh" "${staging_dir}/${artifact_name}/scripts/remote-apply.sh"
install -m 0755 "${source_root}/scripts/update-from-url.sh" "${staging_dir}/${artifact_name}/scripts/update-from-url.sh"

mkdir -p "$dist_dir"
artifact_path="${dist_dir}/${artifact_name}.tar.gz"
tar \
  --sort=name \
  --mtime='UTC 1970-01-01' \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  -czf "$artifact_path" \
  -C "$staging_dir" \
  "$artifact_name"
(cd "$dist_dir" && sha256sum "${artifact_name}.tar.gz" >"${artifact_name}.tar.gz.sha256")
echo "Built ${artifact_path}"
