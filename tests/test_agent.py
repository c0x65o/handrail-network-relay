from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock


SOURCE = Path(__file__).parent.parent / "src" / "handrail_network_relay.py"
SPEC = importlib.util.spec_from_file_location("handrail_network_relay", SOURCE)
assert SPEC and SPEC.loader
relay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(relay)


class RelayTests(unittest.TestCase):
    def write_config(self, directory: Path, **values: str) -> Path:
        config = directory / "relay.ini"
        defaults = {
            "id": "relay-test-1",
            "site": "Test Site",
            "expected_subnets": "10.20.0.0/24",
            "config_revision": "7",
            "poll_interval_seconds": "30",
            "status_file": str(directory / "status.json"),
        }
        defaults.update(values)
        config.write_text(
            "[relay]\n" + "".join(f"{key} = {value}\n" for key, value in defaults.items()),
            encoding="utf-8",
        )
        return config

    def test_load_config_normalizes_and_deduplicates_subnets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path = self.write_config(
                root, expected_subnets="10.20.0.0/24, 2001:db8::/64, 10.20.0.0/24"
            )
            config = relay.load_config(str(config_path))

        self.assertEqual(config["relay_id"], "relay-test-1")
        self.assertEqual(config["config_revision"], 7)
        self.assertEqual(config["expected_subnets"], ["10.20.0.0/24", "2001:db8::/64"])

    def test_load_config_rejects_host_bits_in_subnet(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path = self.write_config(root, expected_subnets="10.20.0.5/24")
            with self.assertRaises(relay.ConfigurationError):
                relay.load_config(str(config_path))

    def test_inspection_is_healthy_when_tailscale_and_forwarding_are_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = relay.load_config(str(self.write_config(root)))
            tailscale = root / "tailscale"
            tailscale.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' '{\"BackendState\":\"Running\",\"Self\":{\"Online\":true,\"TailscaleIPs\":[\"100.64.0.10\"]}}'\n",
                encoding="utf-8",
            )
            tailscale.chmod(tailscale.stat().st_mode | stat.S_IXUSR)
            ipv4 = root / "ipv4"
            ipv6 = root / "ipv6"
            ipv4.write_text("1\n", encoding="ascii")
            ipv6.write_text("0\n", encoding="ascii")
            environment = {
                "HANDRAIL_RELAY_TAILSCALE_BIN": str(tailscale),
                "HANDRAIL_RELAY_IPV4_FORWARD_PATH": str(ipv4),
                "HANDRAIL_RELAY_IPV6_FORWARD_PATH": str(ipv6),
            }
            with mock.patch.dict(os.environ, environment):
                result = relay.inspect_relay(config)

        self.assertTrue(result["healthy"])
        self.assertEqual(result["tailscale"]["ips"], ["100.64.0.10"])
        self.assertEqual(result["expected_subnets"], ["10.20.0.0/24"])
        self.assertEqual(result["config_revision"], 7)
        self.assertEqual(result["source_commit"], relay.load_source_commit())

    def test_inspection_requires_forwarding_for_matching_ip_family(self) -> None:
        config = {
            "relay_id": "relay-test-1",
            "site": "",
            "expected_subnets": ["10.20.0.0/24", "2001:db8::/64"],
            "config_revision": 3,
            "poll_interval_seconds": 30,
            "status_file": "/tmp/status.json",
        }
        with mock.patch.object(
            relay,
            "tailscale_status",
            return_value={
                "installed": True,
                "online": True,
                "backend_state": "Running",
                "ips": ["100.64.0.10"],
                "error": None,
            },
        ), mock.patch.object(relay, "read_forwarding", side_effect=[(True, None), (False, None)]):
            result = relay.inspect_relay(config)

        self.assertFalse(result["healthy"])
        checks = {check["name"]: check for check in result["checks"]}
        self.assertTrue(checks["ipv4_forwarding"]["healthy"])
        self.assertFalse(checks["ipv6_forwarding"]["healthy"])

    def test_status_write_is_readable_and_current(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            status_path = Path(temporary) / "run" / "status.json"
            observed_at = relay.iso_timestamp(relay.utc_now())
            payload = {"healthy": True, "observed_at": observed_at}
            relay.write_status(str(status_path), payload)
            config = {"status_file": str(status_path)}
            stored, error = relay.read_status(config)

        self.assertIsNone(error)
        self.assertEqual(stored, payload)
        self.assertTrue(relay.status_is_current(payload, 30))

    def test_stale_status_is_not_current(self) -> None:
        old = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=10)
        self.assertFalse(relay.status_is_current({"observed_at": relay.iso_timestamp(old)}, 30))

    def test_tailscale_invalid_json_is_unhealthy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "tailscale"
            executable.write_text("#!/bin/sh\necho nope\n", encoding="utf-8")
            executable.chmod(0o700)
            with mock.patch.dict(
                os.environ, {"HANDRAIL_RELAY_TAILSCALE_BIN": str(executable)}
            ):
                result = relay.tailscale_status()

        self.assertFalse(result["online"])
        self.assertIn("invalid tailscale status JSON", result["error"])


if __name__ == "__main__":
    unittest.main()
