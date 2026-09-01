from pathlib import Path
import unittest


ROOT = Path(__file__).parent.parent


class PackagingTests(unittest.TestCase):
    def test_installer_uses_versioned_releases_and_atomic_current_link(self) -> None:
        installer = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        self.assertIn("releases_dir=${install_root}/releases", installer)
        self.assertIn("release_key=${version}-${source_commit}", installer)
        self.assertIn('mv -Tf "$next_link" "$current_link"', installer)
        self.assertIn("restoring the previous installation", installer)
        self.assertIn('mv -Tf "$rollback_link" "$current_link"', installer)
        self.assertIn('SOURCE_COMMIT', installer)
        self.assertIn(
            'install -d -o root -g root -m 0755 "$release_staging" '
            '"${release_staging}/scripts"',
            installer,
        )
        self.assertIn(
            'ln -sfnT "${current_link}/handrail-network-relay" '
            '/usr/local/bin/handrail-network-relay',
            installer,
        )
        self.assertIn('[[ ! -x /usr/local/bin/handrail-network-relay ]]', installer)

    def test_service_executes_only_the_current_release(self) -> None:
        unit = (ROOT / "packaging" / "systemd" / "handrail-network-relay.service").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "ExecStart=/usr/local/lib/handrail-network-relay/current/handrail-network-relay",
            unit,
        )
        self.assertIn("Type=exec", unit)

    def test_updater_fetches_the_public_repository_without_artifacts(self) -> None:
        updater = (ROOT / "scripts" / "update-from-git.sh").read_text(encoding="utf-8")
        self.assertIn("https://github.com/c0x65o/handrail-network-relay.git", updater)
        self.assertIn('fetch --quiet --depth 1 origin "$repository_ref"', updater)
        self.assertNotIn("tar", updater)
        self.assertNotIn("curl", updater)


if __name__ == "__main__":
    unittest.main()
