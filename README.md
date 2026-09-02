# Handrail Network Relay

Handrail Network Relay is a small Linux service installed on a Tailscale subnet
router. It reports whether Tailscale and kernel forwarding are ready for the
canonical 4via6 routes assigned to that relay.

It intentionally does not contain backup, SSH orchestration, or application job
logic, credentials, or connection termination. Handrail owns those workflows;
this service only configures and describes the health of the network path they
use.

Handrail assigns each physical site an immutable site ID and translates its
original IPv4 inventory into Tailscale's 4via6 space. Relay configuration keeps
the original CIDRs in `source_ipv4_subnets` and advertises only the derived IPv6
CIDRs in `expected_subnets`. Route approval and Grants remain in the tailnet
control plane.

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

Set the stable Handrail relay ID, immutable 4via6 site ID, original IPv4
subnets, and their Handrail-derived 4via6 routes. Installation enables the
required kernel forwarding settings and tells the already-authenticated
Tailscale node to advertise exactly the canonical IPv6 CIDRs. Route
approval (unless covered by Tailscale `autoApprovers`), ACL configuration, and
firewall policy remain external.

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
is supplied, applies its subnet-router settings, and starts the service. If the
new service cannot start, the installer restores the previous installation and
configuration.

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
