# Handrail Network Relay

Handrail Network Relay is a small Linux service installed on a Tailscale subnet
router. It reports whether Tailscale and kernel forwarding are ready for the
subnets assigned to that relay.

It intentionally does not contain backup, SSH orchestration, or application job
logic. Handrail owns those workflows; this service only describes the health of
the network path they use.

## Requirements

- Linux with systemd
- Python 3.9 or newer (standard library only)
- Tailscale installed and already joined to the intended tailnet
- Git

## Repository layout

```text
src/                 Relay process and command-line interface
config/              Example relay configuration
packaging/systemd/   Hardened systemd service
scripts/             Install, Git update, forwarding, and uninstall tooling
tests/               Standard-library unit tests
```

## Configure a relay

Create a configuration from the example:

```bash
cp config/config.example.ini relay.ini
```

Set a stable Handrail relay ID and the exact subnets this machine is expected to
route. Then configure Tailscale itself and approve the advertised routes in the
tailnet administration console:

```bash
sudo ./scripts/enable-forwarding.sh --ipv4
sudo tailscale set --advertise-routes=10.20.0.0/24,10.30.0.0/24
```

The relay observes Tailscale; it does not change Tailscale authentication or ACL
configuration.

## Install initially

Clone the public repository, create the relay configuration, and install the
currently committed version:

```bash
git clone https://github.com/c0x65o/handrail-network-relay.git
cd handrail-network-relay
cp config/config.example.ini relay.ini
sudo ./scripts/install.sh --config ./relay.ini
```

The installer only accepts a clean Git checkout. It creates the locked-down
`handrail-relay` system account, installs each immutable version and source
commit under `/usr/local/lib/handrail-network-relay/releases`, atomically
switches the `current` symlink, preserves an existing config unless `--config`
is supplied, and starts the service. If the new service cannot start, the
installer restores the previous installation and configuration.

Check it with:

```bash
sudo systemctl status handrail-network-relay
sudo /usr/local/bin/handrail-network-relay status
sudo /usr/local/bin/handrail-network-relay health
```

## Update from Git

The installed updater fetches the current commit from the public `main` branch:

```bash
sudo handrail-network-relay-update
```

Handrail pins lifecycle operations to a full commit before deploying. The same
behavior is available directly by passing a commit or another public Git ref:

```bash
sudo handrail-network-relay-update --ref c796f2529d010969c9f05d86fb13faf280234eb8
```

No release registration, package archive, repository credential, or application
secret is used. `VERSION` describes the software version and `SOURCE_COMMIT`
identifies the exact installed source in relay status.

## Development

```bash
make test
make check
```

The service writes an atomically replaced JSON status document to
`/run/handrail-network-relay/status.json`. No listener or inbound port is opened
by the agent.
