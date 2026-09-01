from pathlib import Path
import unittest


ROOT = Path(__file__).parent.parent


class PackagingTests(unittest.TestCase):
    def test_installer_uses_versioned_releases_and_atomic_current_link(self) -> None:
        installer = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        self.assertIn("releases_dir=${install_root}/releases", installer)
        self.assertIn("release_dir=${releases_dir}/${version}", installer)
        self.assertIn('mv -Tf "$next_link" "$current_link"', installer)
        self.assertIn("restoring the previous release", installer)
        self.assertIn('mv -Tf "$rollback_link" "$current_link"', installer)

    def test_service_executes_only_the_current_release(self) -> None:
        unit = (ROOT / "packaging" / "systemd" / "handrail-network-relay.service").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "ExecStart=/usr/local/lib/handrail-network-relay/current/handrail-network-relay",
            unit,
        )

    def test_tag_workflow_publishes_archive_and_checksum(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        self.assertIn('tags:\n      - "v*"', workflow)
        self.assertIn("make release", workflow)
        self.assertIn(".tar.gz.sha256", workflow)
        self.assertIn("--verify-tag", workflow)


if __name__ == "__main__":
    unittest.main()
