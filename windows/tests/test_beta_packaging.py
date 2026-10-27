"""Offline release-boundary regressions for the Windows beta packaging inputs.

Every mutable input and output lives in a TemporaryDirectory. Only prepare.icon
is mocked (for --prepare runs) because the image renderer is unrelated and slow.
"""
import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("zone_beta_packaging_prepare", ROOT / "packaging/prepare.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)

BOM = b"\xef\xbb\xbf"
TERMS_NAME = "packaging/runtime-notices/Microsoft-Visual-C-Runtime-2015-2022.txt"
TERMS = ("SYNTHETIC MICROSOFT SOFTWARE LICENSE TERMS — Visual C++ 2015–2022 Runtime\n"
         "© Microsoft Corporation. “Distributable Code” résumé 日本語 \U0001d11e\n"
         "\n"
         "\t1. Indented clause with trailing spaces   \n"
         "2. Final clause without a trailing newline")
OUTPUTS = ("packaging/installer-license.txt", "packaging/version.iss", "packaging/version_info.txt")
# Written in sorted order; names avoid case and separator ordering ambiguity.
RELEASE = {
    "bin/zone-helper.exe": b"MZ synthetic helper",
    "lib/msvcp140.dll": b"MZ synthetic msvcp140",
    "lib/vcruntime140.dll": bytes(range(256)) * 6250,  # > 1 MiB, spans digest chunks
    "licenses/microsoft/Microsoft-Visual-C-Runtime-2015-2022.txt": TERMS.encode("utf-8"),
    "licenses/pyside6/LICENSE.txt": "GNU LGPL v3 (synthetic) © Qt — 日本\n".encode("utf-8"),
    "zone.exe": b"MZ synthetic zone",
}


def make_root(base, version_value="7.12.305", terms=TERMS):
    root = Path(base) / "root"
    (root / "packaging").mkdir(parents=True)
    (root / "packaging/version.json").write_text(json.dumps({
        "version": version_value, "display_version": "7.12", "publisher": "Synthetic Publisher",
        "app_id": "{00000000-0000-0000-0000-000000000000}"}), encoding="utf-8")
    if terms is not None:
        source = root / TERMS_NAME
        source.parent.mkdir(parents=True)
        source.write_bytes(terms.encode("utf-8"))
    return root


def run_main(*argv):
    with mock.patch.object(sys, "argv", ["prepare.py"] + [str(arg) for arg in argv]):
        prepare.main()


def run_prepare(root):
    with mock.patch.object(prepare, "icon"):
        run_main("--root", root, "--prepare")


def write_release(release):
    for relative, data in RELEASE.items():
        target = release / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


class BetaPackagingBoundaryTests(unittest.TestCase):
    def symlink_or_skip(self, target, link, directory=False):
        try:
            os.symlink(target, link, target_is_directory=directory)
        except (OSError, NotImplementedError) as error:
            self.skipTest(f"Symlink creation is unavailable on this host: {error}")

    def test_prepare_license_is_bom_utf8_retains_runtime_terms_and_scopes_them(self):
        with tempfile.TemporaryDirectory() as temp:
            root = make_root(temp)
            source_before = (root / TERMS_NAME).read_bytes()
            run_prepare(root)
            raw = (root / "packaging/installer-license.txt").read_bytes()
            self.assertTrue(raw.startswith(BOM), "installer license must be UTF-8 with BOM")
            text = raw[len(BOM):].decode("utf-8").replace("\r\n", "\n")
            self.assertNotIn("﻿", text)
            head, heading, tail = text.partition("MICROSOFT RUNTIME TERMS\n\n")
            self.assertTrue(heading, "runtime terms heading missing")
            self.assertEqual(tail, TERMS, "supplied runtime terms must be retained exactly")
            self.assertEqual(text.count(TERMS), 1)

            flat = " ".join(head.split())
            lowered = flat.lower()
            self.assertIn("free beta", lowered)
            self.assertIn("free to download and use", lowered)
            self.assertIn("no payment or account is required", lowered)
            sentences = re.split(r"(?<=\.)\s+", flat)
            only = [s for s in sentences if "apply only to" in s]
            self.assertEqual(len(only), 1, sentences)
            self.assertIn("Microsoft Visual C++ runtime", only[0])
            for name in ("Qt", "PySide", "Shiboken"):
                self.assertNotIn(name, only[0])
            excluded = [s for s in sentences if "do not apply" in s]
            self.assertEqual(len(excluded), 1, sentences)
            for name in ("Zone itself", "Qt", "PySide", "Shiboken", "other third-party components"):
                self.assertIn(name, excluded[0])

            self.assertEqual((root / TERMS_NAME).read_bytes(), source_before)
            self.assertEqual(source_before, TERMS.encode("utf-8"))

    def test_version_metadata_uses_supplied_version_consistently_and_is_reproducible(self):
        with tempfile.TemporaryDirectory() as temp:
            root = make_root(temp, "7.12.305")
            run_prepare(root)
            first = {name: (root / name).read_bytes() for name in OUTPUTS}
            run_prepare(root)
            self.assertEqual({name: (root / name).read_bytes() for name in OUTPUTS}, first)

            iss = (root / "packaging/version.iss").read_text(encoding="utf-8")
            self.assertEqual(re.findall(r'^#define\s+(\w+)\s+"([^"]*)"\s*$', iss, re.M),
                             [("ZoneVersion", "7.12.305")])
            zone_iss = (ROOT / "packaging/Zone.iss").read_text(encoding="utf-8")
            self.assertIn('#include "version.iss"', zone_iss)
            self.assertIn("{#ZoneVersion}", zone_iss)

            info = (root / "packaging/version_info.txt").read_text(encoding="utf-8")
            tuples, strings = {}, {}
            for node in ast.walk(ast.parse(info, mode="eval")):
                if isinstance(node, ast.keyword) and node.arg in ("filevers", "prodvers"):
                    tuples[node.arg] = ast.literal_eval(node.value)
                if isinstance(node, ast.Call) and getattr(node.func, "id", None) == "StringStruct":
                    key, value = (ast.literal_eval(arg) for arg in node.args)
                    strings[key] = value
            self.assertEqual(tuples, {"filevers": (7, 12, 305, 0), "prodvers": (7, 12, 305, 0)})
            self.assertEqual((strings["FileVersion"], strings["ProductVersion"]), ("7.12.305", "7.12.305"))
            for text in (iss, info):
                self.assertNotIn("1.0.0", text)

            # A new supplied version replaces, rather than mixes with, the previous one.
            (root / "packaging/version.json").write_text(json.dumps({"version": "7.12.306"}), encoding="utf-8")
            run_prepare(root)
            iss = (root / "packaging/version.iss").read_text(encoding="utf-8")
            info = (root / "packaging/version_info.txt").read_text(encoding="utf-8")
            self.assertIn('"7.12.306"', iss)
            self.assertNotIn("7.12.305", iss + info)
            self.assertIn("7,12,306,0", info)
            self.assertEqual((root / OUTPUTS[0]).read_bytes(), first[OUTPUTS[0]])

    def test_missing_runtime_terms_raises_without_license_or_version_metadata(self):
        for layout in ("no-notices-directory", "empty-notices-directory"):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as temp:
                root = make_root(temp, terms=None)
                if layout == "empty-notices-directory":
                    (root / TERMS_NAME).parent.mkdir(parents=True)
                with mock.patch.object(prepare, "icon"), self.assertRaises(OSError):
                    run_main("--root", root, "--prepare")
                for name in OUTPUTS:
                    self.assertFalse((root / name).exists(), name)

    def test_invalid_version_is_rejected_before_any_preparation_output(self):
        invalid = ("", "1", "1.0", "1.0.0.0", "v1.0.0", "1.0.0-beta.1", "1.0.0+build.5", " 1.0.0",
                   "1.0.0 ", "1.0.0\n", "1..0", "1.0.", ".1.0", "a.b.c", "1.0.x", "1,0,0", "１.0.0")
        for value in invalid:
            with self.subTest(version=value), tempfile.TemporaryDirectory() as temp:
                root = make_root(temp, value)
                release = Path(temp) / "release"
                release.mkdir()
                (release / "zone.exe").write_bytes(b"MZ synthetic zone")
                with mock.patch.object(prepare, "icon") as icon:
                    with self.assertRaises(ValueError):
                        run_main("--root", root, "--prepare", "--manifest", release)
                icon.assert_not_called()
                for name in OUTPUTS:
                    self.assertFalse((root / name).exists(), name)
                self.assertFalse((release / "release-manifest.json").exists())
        for value in ("0.0.0", "10.200.3000"):
            with self.subTest(valid=value), tempfile.TemporaryDirectory() as temp:
                root = make_root(temp, value)
                run_prepare(root)
                self.assertIn(f'"{value}"', (root / "packaging/version.iss").read_text(encoding="utf-8"))

    def test_manifest_lists_exact_sorted_bytes_and_hashes_and_tracks_content(self):
        self.assertEqual(list(RELEASE), sorted(RELEASE))
        with tempfile.TemporaryDirectory() as temp:
            root = make_root(temp)
            release = Path(temp) / "release"
            write_release(release)
            (release / "empty/nested").mkdir(parents=True)
            output = release / "release-manifest.json"
            run_main("--root", root, "--manifest", release)
            first = output.read_bytes()
            expected = [{"path": path, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                        for path, data in RELEASE.items()]
            self.assertEqual(json.loads(first.decode("utf-8")), {"schema": 1, "files": expected})

            run_main("--root", root, "--manifest", release)
            self.assertEqual(output.read_bytes(), first, "rerun must be byte-identical and exclude itself")

            changed = "lib/vcruntime140.dll"
            data = bytearray(RELEASE[changed])
            data[-1] ^= 0xFF
            (release / changed).write_bytes(bytes(data))
            run_main("--root", root, "--manifest", release)
            self.assertNotEqual(output.read_bytes(), first)
            updated = json.loads(output.read_text(encoding="utf-8"))["files"]
            self.assertEqual([entry["path"] for entry in updated], list(RELEASE))
            for before, after in zip(expected, updated):
                if before["path"] == changed:
                    self.assertEqual(after["bytes"], before["bytes"])
                    self.assertEqual(after["sha256"], hashlib.sha256(bytes(data)).hexdigest())
                    self.assertNotEqual(after["sha256"], before["sha256"])
                else:
                    self.assertEqual(after, before)

    def test_release_tree_symlinks_are_refused_without_manifest(self):
        for kind in ("file", "directory", "dangling"):
            with self.subTest(symlink=kind), tempfile.TemporaryDirectory() as temp:
                root = make_root(temp)
                outside = Path(temp) / "outside"
                outside.mkdir()
                (outside / "foreign.dll").write_bytes(b"outside the release")
                release = Path(temp) / "release"
                write_release(release)
                link = release / "lib/linked"
                if kind == "file":
                    self.symlink_or_skip(outside / "foreign.dll", link)
                elif kind == "directory":
                    self.symlink_or_skip(outside, link, directory=True)
                else:
                    self.symlink_or_skip(outside / "missing.dll", link)
                with self.assertRaises(ValueError):
                    run_main("--root", root, "--manifest", release)
                self.assertFalse((release / "release-manifest.json").exists())
                self.assertEqual((outside / "foreign.dll").read_bytes(), b"outside the release")

    def test_empty_release_tree_is_rejected_without_manifest(self):
        for layout in ("empty", "only-empty-directories"):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as temp:
                root = make_root(temp)
                release = Path(temp) / "release"
                release.mkdir()
                if layout == "only-empty-directories":
                    (release / "lib/empty").mkdir(parents=True)
                with self.assertRaises(ValueError):
                    run_main("--root", root, "--manifest", release)
                self.assertFalse((release / "release-manifest.json").exists())

    def test_notice_inventory_preserves_exact_unicode_bytes_and_reports_gaps(self):
        with tempfile.TemporaryDirectory() as temp:
            site = Path(temp) / "site"
            lgpl = ("GNU LESSER GENERAL PUBLIC LICENSE (synthetic)\r\n"
                    "© The Qt Company — résumé 日本語 \U0001d11e\r\n").encode("utf-8")
            notice = BOM + "NOTICE über Shiboken\n\tno trailing newline".encode("utf-8")
            sources = {"PySide6-6.0.dist-info/licenses/LICENSE.LGPLv3": lgpl, "shiboken6/NOTICE": notice,
                       "shiboken6/__init__.py": b"", "nolicense/__init__.py": b"# code only\n"}
            for relative, data in sources.items():
                (site / relative).parent.mkdir(parents=True, exist_ok=True)
                (site / relative).write_bytes(data)
            (Path(temp) / "outside-LICENSE").write_bytes(b"not part of any distribution")

            class FakeDist:
                def __init__(self, name, files, declared=""):
                    self.metadata = {"Name": name, "License": declared}
                    self.version = "1.0"
                    self.files = files

                def locate_file(self, file):
                    return site / file

            dists = [FakeDist("shiboken6", [Path("shiboken6/__init__.py"), Path("shiboken6/NOTICE"),
                                            Path("../outside-LICENSE")], "LGPL-3.0"),
                     FakeDist("PySide6", [Path("PySide6-6.0.dist-info/licenses/LICENSE.LGPLv3")], "LGPL-3.0"),
                     FakeDist("no-notice-package", [Path("nolicense/__init__.py")], "MIT"),
                     FakeDist("no-file-record", None)]
            destination = Path(temp) / "notices"
            report = prepare.collect_notices(destination, dists)

            packages = {package["name"]: package for package in report["packages"]}
            self.assertEqual(set(packages), {"shiboken6", "PySide6", "no-notice-package", "no-file-record"})
            retained = (("PySide6", "PySide6/PySide6-6.0.dist-info/licenses/LICENSE.LGPLv3", lgpl),
                        ("shiboken6", "shiboken6/shiboken6/NOTICE", notice))
            for name, relative, data in retained:
                self.assertEqual((destination / relative).read_bytes(), data)
                self.assertEqual(packages[name]["notice_files"],
                                 [{"path": relative, "sha256": hashlib.sha256(data).hexdigest()}])
                self.assertTrue(packages[name]["notice_text_found"])
                self.assertEqual(packages[name]["declared_license"], "LGPL-3.0")
            for name in ("no-notice-package", "no-file-record"):
                self.assertEqual(packages[name]["notice_files"], [])
                self.assertFalse(packages[name]["notice_text_found"], name)
            self.assertEqual(sorted(path.relative_to(destination).as_posix()
                                    for path in destination.rglob("*") if path.is_file()),
                             sorted([relative for _, relative, _ in retained] + ["inventory.json"]))
            self.assertFalse(report["public_release_approved"])
            self.assertTrue(report["unresolved"])
            self.assertEqual(json.loads((destination / "inventory.json").read_text(encoding="utf-8")), report)
            for relative, data in sources.items():
                self.assertEqual((site / relative).read_bytes(), data)


if __name__ == "__main__":
    unittest.main()
