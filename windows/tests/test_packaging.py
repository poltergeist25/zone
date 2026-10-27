import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("zone_packaging_prepare", ROOT / "packaging/prepare.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PackagingTests(unittest.TestCase):
    def test_manifest_hashes_actual_files_and_excludes_itself(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "Zone.exe").write_bytes(b"not-a-real-exe")
            output = root / "release-manifest.json"
            first = prepare.manifest(root, output)
            second = prepare.manifest(root, output)
            self.assertEqual(first, second)
            self.assertEqual(first[0]["sha256"], prepare.digest(root / "Zone.exe"))
            self.assertEqual(first[0]["bytes"], 14)

    def test_empty_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                prepare.manifest(temp, Path(temp) / "manifest.json")

    def test_icon_is_deterministic_png_ico(self):
        with tempfile.TemporaryDirectory() as temp:
            first, second = Path(temp) / "a.ico", Path(temp) / "b.ico"
            prepare.icon(first)
            prepare.icon(second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            data = first.read_bytes()
            self.assertEqual(struct.unpack("<HHH", data[:6]), (0, 1, 1))
            self.assertEqual(data[22:30], b"\x89PNG\r\n\x1a\n")

    def test_version_and_installer_do_not_launch_or_delete_profiles(self):
        self.assertEqual(prepare.version(ROOT)["version"], "1.0.0")
        source = (ROOT / "packaging/Zone.iss").read_text(encoding="utf-8")
        actual = "\n".join(line for line in source.splitlines() if not line.lstrip().startswith(";"))
        self.assertIn("PrivilegesRequired=lowest", actual)
        self.assertNotIn("[Run]", actual)
        self.assertNotIn("[UninstallDelete]", actual)
        self.assertNotIn("{userappdata}", actual)

    def test_notices_inventory_retains_verbatim_and_flags_gaps(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "LICENSE").write_text("Original license text", encoding="utf-8")
            class FakeDist:
                metadata = {"Name": "Synthetic", "License": "MIT"}
                version = "1"
                files = [Path("LICENSE")]
                def locate_file(self, file):
                    return root / file
            destination = root / "notices"
            report = prepare.collect_notices(destination, [FakeDist()])
            self.assertEqual((destination / "Synthetic/LICENSE").read_text(), "Original license text")
            self.assertFalse(report["public_release_approved"])
            self.assertTrue(report["unresolved"])
            self.assertTrue(json.loads((destination / "inventory.json").read_text())["packages"][0]["notice_text_found"])


if __name__ == "__main__":
    unittest.main()
