#!/usr/bin/env python3
"""Small, dependency-free health agent for a Handrail Tailscale subnet relay."""

from __future__ import annotations

import argparse
import configparser
import datetime as dt
import ipaddress
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any


DEFAULT_CONFIG = "/etc/handrail-network-relay/config.ini"
DEFAULT_STATUS = "/run/handrail-network-relay/status.json"
MIN_POLL_SECONDS = 5
MAX_POLL_SECONDS = 3600


class ConfigurationError(ValueError):
    """Raised when relay configuration is missing or unsafe."""


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_timestamp(value: dt.datetime) -> str:
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def load_version() -> str:
    script_path = Path(__file__).resolve()
    candidates = (script_path.with_name("VERSION"), script_path.parent.parent / "VERSION")
    for candidate in candidates:
        try:
            value = candidate.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if value:
            return value
    return "development"


def load_source_commit() -> str | None:
    script_path = Path(__file__).resolve()
    candidates = (script_path.with_name("SOURCE_COMMIT"), script_path.parent.parent / "SOURCE_COMMIT")
    for candidate in candidates:
        try:
            value = candidate.read_text(encoding="ascii").strip().lower()
        except OSError:
            continue
        if len(value) == 40 and all(character in "0123456789abcdef" for character in value):
            return value
    try:
        completed = subprocess.run(
            ["git", "-C", str(script_path.parent.parent), "rev-parse", "--verify", "HEAD"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        return None
    value = completed.stdout.strip().lower()
    return value if completed.returncode == 0 and len(value) == 40 else None


def parse_subnets(raw_value: str) -> list[str]:
    subnets: list[str] = []
    for raw_subnet in raw_value.split(","):
        value = raw_subnet.strip()
        if not value:
            continue
        try:
            subnet = ipaddress.ip_network(value, strict=True)
        except ValueError as exc:
            raise ConfigurationError(f"invalid expected subnet {value!r}: {exc}") from exc
        normalized = str(subnet)
        if normalized not in subnets:
            subnets.append(normalized)
    if not subnets:
        raise ConfigurationError("relay.expected_subnets must contain at least one CIDR")
    return subnets


def load_config(path: str) -> dict[str, Any]:
    parser = configparser.ConfigParser(interpolation=None)
    if not parser.read(path):
        raise ConfigurationError(f"could not read config file: {path}")
    if "relay" not in parser:
        raise ConfigurationError("config must contain a [relay] section")

    relay = parser["relay"]
    relay_id = relay.get("id", "").strip()
    if not relay_id or relay_id == "replace-with-handrail-relay-id":
        raise ConfigurationError("relay.id must be set to the ID assigned by Handrail")
    if len(relay_id) > 128:
        raise ConfigurationError("relay.id cannot exceed 128 characters")

    try:
        poll_seconds = relay.getint("poll_interval_seconds", fallback=30)
    except ValueError as exc:
        raise ConfigurationError("relay.poll_interval_seconds must be an integer") from exc
    if not MIN_POLL_SECONDS <= poll_seconds <= MAX_POLL_SECONDS:
        raise ConfigurationError(
            f"relay.poll_interval_seconds must be between {MIN_POLL_SECONDS} and {MAX_POLL_SECONDS}"
        )

    try:
        config_revision = relay.getint("config_revision", fallback=1)
    except ValueError as exc:
        raise ConfigurationError("relay.config_revision must be an integer") from exc
    if config_revision < 1:
        raise ConfigurationError("relay.config_revision must be at least 1")

    status_file = relay.get("status_file", DEFAULT_STATUS).strip()
    if not Path(status_file).is_absolute():
        raise ConfigurationError("relay.status_file must be an absolute path")

    return {
        "relay_id": relay_id,
        "site": relay.get("site", "").strip(),
        "expected_subnets": parse_subnets(relay.get("expected_subnets", "")),
        "config_revision": config_revision,
        "poll_interval_seconds": poll_seconds,
        "status_file": status_file,
    }


def read_forwarding(path: str) -> tuple[bool, str | None]:
    try:
        return Path(path).read_text(encoding="ascii").strip() == "1", None
    except OSError as exc:
        return False, str(exc)


def tailscale_status() -> dict[str, Any]:
    executable = os.environ.get("HANDRAIL_RELAY_TAILSCALE_BIN", "/usr/bin/tailscale")
    try:
        completed = subprocess.run(
            [executable, "status", "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except FileNotFoundError:
        return {
            "installed": False,
            "online": False,
            "backend_state": None,
            "ips": [],
            "error": "tailscale executable not found",
        }
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {
            "installed": True,
            "online": False,
            "backend_state": None,
            "ips": [],
            "error": str(exc),
        }

    if completed.returncode != 0:
        error = completed.stderr.strip() or f"tailscale exited {completed.returncode}"
        return {
            "installed": True,
            "online": False,
            "backend_state": None,
            "ips": [],
            "error": error[:500],
        }

    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        return {
            "installed": True,
            "online": False,
            "backend_state": None,
            "ips": [],
            "error": f"invalid tailscale status JSON: {exc}",
        }

    backend_state = payload.get("BackendState")
    self_status = payload.get("Self") if isinstance(payload.get("Self"), dict) else {}
    ips = self_status.get("TailscaleIPs") or payload.get("TailscaleIPs") or []
    ips = [value for value in ips if isinstance(value, str)]
    return {
        "installed": True,
        "online": backend_state == "Running" and bool(self_status.get("Online", True)),
        "backend_state": backend_state,
        "ips": ips,
        "error": None,
    }


def inspect_relay(config: dict[str, Any]) -> dict[str, Any]:
    tailscale = tailscale_status()
    ipv4_path = os.environ.get(
        "HANDRAIL_RELAY_IPV4_FORWARD_PATH", "/proc/sys/net/ipv4/ip_forward"
    )
    ipv6_path = os.environ.get(
        "HANDRAIL_RELAY_IPV6_FORWARD_PATH", "/proc/sys/net/ipv6/conf/all/forwarding"
    )
    ipv4_enabled, ipv4_error = read_forwarding(ipv4_path)
    ipv6_enabled, ipv6_error = read_forwarding(ipv6_path)
    requires_ipv4 = any(
        ipaddress.ip_network(route).version == 4 for route in config["expected_subnets"]
    )
    requires_ipv6 = any(
        ipaddress.ip_network(route).version == 6 for route in config["expected_subnets"]
    )

    checks = [
        {
            "name": "tailscale_online",
            "healthy": tailscale["online"],
            "detail": tailscale["error"] or tailscale["backend_state"] or "unknown",
        },
        {
            "name": "ipv4_forwarding",
            "healthy": not requires_ipv4 or ipv4_enabled,
            "detail": ipv4_error or ("enabled" if ipv4_enabled else "disabled"),
            "required": requires_ipv4,
        },
        {
            "name": "ipv6_forwarding",
            "healthy": not requires_ipv6 or ipv6_enabled,
            "detail": ipv6_error or ("enabled" if ipv6_enabled else "disabled"),
            "required": requires_ipv6,
        },
    ]

    return {
        "schema_version": 1,
        "relay_id": config["relay_id"],
        "site": config["site"] or None,
        "agent_version": load_version(),
        "source_commit": load_source_commit(),
        "config_revision": config["config_revision"],
        "observed_at": iso_timestamp(utc_now()),
        "healthy": all(check["healthy"] for check in checks),
        "expected_subnets": config["expected_subnets"],
        "tailscale": tailscale,
        "forwarding": {"ipv4": ipv4_enabled, "ipv6": ipv6_enabled},
        "checks": checks,
    }


def write_status(path: str, status: dict[str, Any]) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=".status-", dir=destination.parent, text=True
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(status, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, 0o644)
        os.replace(temporary_name, destination)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def read_status(config: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None]:
    try:
        status = json.loads(Path(config["status_file"]).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, str(exc)
    if not isinstance(status, dict):
        return None, "status document is not a JSON object"
    return status, None


def status_is_current(status: dict[str, Any], poll_seconds: int) -> bool:
    try:
        observed = dt.datetime.fromisoformat(
            str(status["observed_at"]).replace("Z", "+00:00")
        )
    except (KeyError, TypeError, ValueError):
        return False
    return utc_now() - observed <= dt.timedelta(seconds=max(15, poll_seconds * 3))


def command_run(config: dict[str, Any]) -> int:
    stopping = False

    def request_stop(_signum: int, _frame: Any) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    while not stopping:
        try:
            write_status(config["status_file"], inspect_relay(config))
        except Exception as exc:  # Keep the supervised process alive after transient failures.
            print(f"status refresh failed: {exc}", file=sys.stderr, flush=True)
        deadline = time.monotonic() + config["poll_interval_seconds"]
        while not stopping and time.monotonic() < deadline:
            time.sleep(min(0.5, max(0, deadline - time.monotonic())))
    return 0


def command_status(config: dict[str, Any], as_json: bool) -> int:
    status, error = read_status(config)
    if error:
        print(f"relay status unavailable: {error}", file=sys.stderr)
        return 1
    assert status is not None
    current = status_is_current(status, config["poll_interval_seconds"])
    if as_json:
        output = dict(status)
        output["current"] = current
        print(json.dumps(output, indent=2, sort_keys=True))
    else:
        health = "healthy" if status.get("healthy") and current else "unhealthy"
        print(
            f"{config['relay_id']}: {health} "
            f"(observed {status.get('observed_at', 'unknown')})"
        )
    return 0 if status.get("healthy") and current else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="relay configuration file")
    parser.add_argument("--version", action="version", version=load_version())
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("run", help="run the status refresh loop")
    commands.add_parser("validate-config", help="validate configuration and exit")
    check = commands.add_parser("check", help="perform and print a live one-shot check")
    check.add_argument("--json", action="store_true", help="emit JSON")
    status = commands.add_parser("status", help="read the most recent status")
    status.add_argument("--json", action="store_true", help="emit JSON")
    commands.add_parser("health", help="exit successfully when recent status is healthy")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        config = load_config(args.config)
    except ConfigurationError as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2

    if args.command == "run":
        return command_run(config)
    if args.command == "validate-config":
        print(f"configuration valid for relay {config['relay_id']}")
        return 0
    if args.command == "check":
        status = inspect_relay(config)
        if args.json:
            print(json.dumps(status, indent=2, sort_keys=True))
        else:
            print("healthy" if status["healthy"] else "unhealthy")
        return 0 if status["healthy"] else 1
    if args.command == "status":
        return command_status(config, args.json)
    if args.command == "health":
        return command_status(config, False)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
