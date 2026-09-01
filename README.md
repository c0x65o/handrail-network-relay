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
- `curl`, `tar`, and `sha256sum` when using pull-based updates
- `ssh` and `scp` on the operator machine when pushing an update

## Repository layout

```text
src/                 Relay process and command-line interface
config/              Example relay configuration
packaging/systemd/   Hardened systemd service
scripts/             Install, package, push-update, and uninstall tooling
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

From a checkout or an unpacked release bundle:

```bash
sudo ./scripts/install.sh --config ./relay.ini
```

The installer creates the locked-down `handrail-relay` system account, installs
each immutable version under `/usr/local/lib/handrail-network-relay/releases`,
atomically switches the `current` symlink, preserves an existing config unless
`--config` is supplied, and starts the service. If the new service cannot start,
the installer restores the previous release and configuration.

Check it with:

```bash
sudo systemctl status handrail-network-relay
sudo /usr/local/bin/handrail-network-relay status
sudo /usr/local/bin/handrail-network-relay health
```

## Build and push an update

Build a release bundle and checksum:

```bash
make release
```

For an initial remote installation, push it over SSH with a configuration file:

```bash
./scripts/push-update.sh \
  --host 10.20.0.10 \
  --user relay-admin \
  --port 22 \
  --identity ~/.ssh/relay-admin \
  --config ./relay.ini \
  --artifact dist/handrail-network-relay-$(cat VERSION).tar.gz
```

Omit `--config` on later pushes to preserve the relay's installed configuration.

The push script verifies the archive locally, copies it to a fresh remote
temporary directory, verifies it again on the relay, and invokes the bundled
installer through `sudo`. It does not store or copy the SSH key into the relay
software.

For a pull-based update, run the installed updater on the relay with an HTTPS
artifact URL and its expected SHA-256 digest. The digest is mandatory:

```bash
sudo handrail-network-relay-update https://downloads.example/relay.tar.gz SHA256
```

## Development

```bash
make test
make check
```

The service writes an atomically replaced JSON status document to
`/run/handrail-network-relay/status.json`. No listener or inbound port is opened
by the agent.
