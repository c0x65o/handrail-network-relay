#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: sudo $0 [--config PATH] [--no-start]" >&2
}

config_source=""
start_service=1
while (($#)); do
  case "$1" in
    --config)
      (($# >= 2)) || { usage; exit 2; }
      config_source=$2
      shift 2
      ;;
    --no-start)
      start_service=0
      shift
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

[[ $(uname -s) == Linux ]] || { echo "Linux is required" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || { echo "install.sh must run as root" >&2; exit 1; }

for command_name in git python3 systemctl install getent groupadd useradd readlink; do
  command -v "$command_name" >/dev/null || {
    echo "required command not found: $command_name" >&2
    exit 1
  }
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_root=$(cd -- "${script_dir}/.." && pwd)
agent_source="${source_root}/src/handrail_network_relay.py"
service_source="${source_root}/packaging/systemd/handrail-network-relay.service"
version_source="${source_root}/VERSION"
updater_source="${source_root}/scripts/update-from-git.sh"
config_dir=/etc/handrail-network-relay
config_path=${config_dir}/config.ini
install_root=/usr/local/lib/handrail-network-relay
releases_dir=${install_root}/releases
current_link=${install_root}/current
service_path=/etc/systemd/system/handrail-network-relay.service

for required_file in "$agent_source" "$service_source" "$version_source" "$updater_source"; do
  [[ -f $required_file ]] || { echo "repository checkout is missing $required_file" >&2; exit 1; }
done

source_commit=$(git -c safe.directory="$source_root" -C "$source_root" rev-parse --verify HEAD 2>/dev/null || true)
[[ $source_commit =~ ^[0-9a-f]{40}$ ]] || {
  echo "install.sh must run from a Git repository checkout" >&2
  exit 1
}
git -c safe.directory="$source_root" -C "$source_root" diff --quiet -- \
  && git -c safe.directory="$source_root" -C "$source_root" diff --cached --quiet -- || {
  echo "repository checkout has uncommitted tracked changes" >&2
  exit 1
}

if [[ -n $config_source ]]; then
  [[ -f $config_source ]] || { echo "config not found: $config_source" >&2; exit 1; }
  python3 "$agent_source" --config "$config_source" validate-config
elif [[ -f $config_path ]]; then
  python3 "$agent_source" --config "$config_path" validate-config
else
  echo "initial installation requires --config PATH" >&2
  exit 2
fi

if ! getent group handrail-relay >/dev/null; then
  groupadd --system handrail-relay
fi
if ! getent passwd handrail-relay >/dev/null; then
  nologin_shell=$(command -v nologin || true)
  [[ -n $nologin_shell ]] || { echo "required command not found: nologin" >&2; exit 1; }
  useradd \
    --system \
    --gid handrail-relay \
    --home-dir /var/lib/handrail-network-relay \
    --shell "$nologin_shell" \
    handrail-relay
fi

version=$(<"$version_source")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || {
  echo "release has an invalid VERSION: $version" >&2
  exit 1
}

install -d -o root -g handrail-relay -m 0750 "$config_dir"
install -d -o root -g root -m 0755 "$install_root" "$releases_dir"

release_key=${version}-${source_commit}
release_dir=${releases_dir}/${release_key}
if [[ ! -d $release_dir ]]; then
  release_staging=$(mktemp -d "${releases_dir}/.${release_key}.XXXXXXXX")
  install -d -o root -g root -m 0755 "${release_staging}/scripts"
  install -o root -g root -m 0755 "$agent_source" "${release_staging}/handrail-network-relay"
  install -o root -g root -m 0644 "$version_source" "${release_staging}/VERSION"
  printf '%s\n' "$source_commit" >"${release_staging}/SOURCE_COMMIT"
  chmod 0644 "${release_staging}/SOURCE_COMMIT"
  install -o root -g root -m 0755 "$updater_source" "${release_staging}/scripts/update-from-git.sh"
  mv "$release_staging" "$release_dir"
fi

previous_target=""
if [[ -L $current_link ]]; then
  previous_target=$(readlink "$current_link")
fi

config_existed=0
config_backup=""
if [[ -f $config_path ]]; then
  config_existed=1
fi
if [[ -n $config_source ]]; then
  if ((config_existed)); then
    config_backup=$(mktemp)
    install -o root -g handrail-relay -m 0640 "$config_path" "$config_backup"
  fi
  config_staging=$(mktemp "${config_dir}/.config.XXXXXXXX")
  install -o root -g handrail-relay -m 0640 "$config_source" "$config_staging"
  mv -f "$config_staging" "$config_path"
fi

next_link=${install_root}/.current.$$
ln -s "$release_dir" "$next_link"
mv -Tf "$next_link" "$current_link"
ln -sfn "${current_link}/handrail-network-relay" /usr/local/bin/handrail-network-relay
ln -sfn "${current_link}/scripts/update-from-git.sh" /usr/local/bin/handrail-network-relay-update
install -o root -g root -m 0644 "$service_source" "$service_path"

systemctl daemon-reload
systemctl enable handrail-network-relay.service >/dev/null
if ((start_service)); then
  if ! systemctl restart handrail-network-relay.service \
    || ! systemctl is-active --quiet handrail-network-relay.service \
    || [[ $("${current_link}/handrail-network-relay" --version) != "$version" ]]; then
    echo "commit ${source_commit} (version ${version}) failed to start; restoring the previous installation" >&2
    if [[ -n $previous_target ]]; then
      rollback_link=${install_root}/.current.rollback.$$
      ln -s "$previous_target" "$rollback_link"
      mv -Tf "$rollback_link" "$current_link"
    else
      rm -f "$current_link"
    fi
    if [[ -n $config_source ]]; then
      if ((config_existed)); then
        install -o root -g handrail-relay -m 0640 "$config_backup" "$config_path"
      else
        rm -f "$config_path"
      fi
    fi
    systemctl daemon-reload
    if [[ -n $previous_target ]]; then
      systemctl restart handrail-network-relay.service || true
    fi
    [[ -z $config_backup ]] || rm -f "$config_backup"
    exit 1
  fi
fi

[[ -z $config_backup ]] || rm -f "$config_backup"

installed_version=$(<"${current_link}/VERSION")
installed_commit=$(<"${current_link}/SOURCE_COMMIT")
echo "Handrail Network Relay ${installed_version} (${installed_commit}) installed"
