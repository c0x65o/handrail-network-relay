#!/usr/bin/env bash
set -euo pipefail

repository_url=https://github.com/c0x65o/handrail-network-relay.git
repository_ref=refs/heads/main
config_source=""

usage() {
  echo "Usage: sudo $0 [--ref GIT_REF] [--config PATH]" >&2
}

while (($#)); do
  case "$1" in
    --ref)
      (($# >= 2)) || { usage; exit 2; }
      repository_ref=$2
      shift 2
      ;;
    --config)
      (($# >= 2)) || { usage; exit 2; }
      config_source=$2
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

[[ ${EUID} -eq 0 ]] || { echo "update-from-git.sh must run as root" >&2; exit 1; }
[[ $repository_ref != -* && $repository_ref != *..* && $repository_ref != *'@{'* ]] || {
  echo "invalid Git ref" >&2
  exit 2
}
[[ $repository_ref =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "invalid Git ref" >&2; exit 2; }
if [[ -n $config_source ]]; then
  [[ -f $config_source ]] || { echo "config not found: $config_source" >&2; exit 1; }
fi

for command_name in git mktemp; do
  command -v "$command_name" >/dev/null || { echo "required command not found: $command_name" >&2; exit 1; }
done

checkout_dir=$(mktemp -d -t handrail-relay-git.XXXXXXXX)
trap 'rm -rf "$checkout_dir"' EXIT HUP INT TERM
git -C "$checkout_dir" init --quiet
git -C "$checkout_dir" remote add origin "$repository_url"
GIT_TERMINAL_PROMPT=0 git -C "$checkout_dir" fetch --quiet --depth 1 origin "$repository_ref"
git -C "$checkout_dir" checkout --quiet --detach FETCH_HEAD

install_args=()
if [[ -n $config_source ]]; then
  install_args=(--config "$config_source")
fi
"${checkout_dir}/scripts/install.sh" "${install_args[@]}"
