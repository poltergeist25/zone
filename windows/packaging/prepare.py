"""Offline packaging inputs and receipts. Never opens a camera or signs code."""
import argparse
import hashlib
import importlib.metadata as metadata
import json
import math
from pathlib import Path
import re
import struct
import zlib


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def version(root):
    value = json.loads((Path(root) / "packaging/version.json").read_text(encoding="utf-8"))
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value["version"]):
        raise ValueError("Version must be a three-component numeric version")
    return value


def icon(path):
    """Same forest tile and twelve radial strokes as the existing Qt app icon.

    Pure stdlib PNG-in-ICO avoids Qt startup, font/graphics dependencies and
    importing the sensor in the packaging process. Four samples per dimension
    anti-alias the 256px image; Windows scales this PNG ICO entry as needed.
    """
    size, samples = 256, 4
    strokes = []
    for index in range(12):
        angle = index * math.tau / 12 - math.pi / 2
        strokes.append(((64 + 33 * math.cos(angle), 64 + 33 * math.sin(angle)),
                        (64 + 45 * math.cos(angle), 64 + 45 * math.sin(angle))))
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            sums = [0, 0, 0, 0]
            for sy in range(samples):
                for sx in range(samples):
                    px, py = (x + (sx + .5) / samples) / 2, (y + (sy + .5) / samples) / 2
                    # Rounded forest tile: the incumbent inset and corner radius.
                    dx, dy = max(36 - px, 0, px - 92), max(36 - py, 0, py - 92)
                    inside = dx * dx + dy * dy <= 24 * 24
                    if not inside:
                        continue
                    color = (32, 63, 50, 255)
                    for (ax, ay), (bx, by) in strokes:
                        vx, vy = bx - ax, by - ay
                        t = max(0, min(1, ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)))
                        if (px - ax - t * vx) ** 2 + (py - ay - t * vy) ** 2 <= 16:
                            color = (246, 244, 235, 255)
                            break
                    for i, v in enumerate(color):
                        sums[i] += v
            count = samples * samples
            alpha = sums[3] // count
            rows.extend((round(sums[0] * 255 / sums[3]) if sums[3] else 0,
                         round(sums[1] * 255 / sums[3]) if sums[3] else 0,
                         round(sums[2] * 255 / sums[3]) if sums[3] else 0, alpha))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))
    Path(path).write_bytes(struct.pack("<HHH", 0, 1, 1)
                          + struct.pack("<BBBBHHII", 0, 0, 0, 0, 1, 32, len(png), 22) + png)


def collect_notices(destination, distributions=None):
    """Retain verbatim notices from the actual build environment, not guessed text.

    This is an environment inventory, not proof that every entry is shipped or
    that every license obligation is complete. Missing texts remain visible.
    """
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    inventory = []
    for dist in sorted(distributions or metadata.distributions(), key=lambda d: d.metadata.get("Name", "")):
        name = dist.metadata.get("Name", "unknown")
        slug = re.sub(r"[^A-Za-z0-9._-]", "_", name)
        texts = []
        for file in dist.files or []:
            posix = str(file).replace("\\", "/")
            parts = Path(posix).parts
            if ".." in parts or Path(posix).is_absolute():
                continue
            leaf = Path(posix).name.lower()
            if not (any(part.lower() == "licenses" for part in parts)
                    or leaf.startswith(("license", "licence", "copying", "notice", "copyright"))):
                continue
            source = Path(dist.locate_file(file))
            if not source.is_file() or source.stat().st_size > 5_000_000:
                continue
            target = destination / slug / posix
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
            texts.append({"path": target.relative_to(destination).as_posix(), "sha256": digest(target)})
        inventory.append({"name": name, "version": dist.version,
                          "declared_license": dist.metadata.get("License-Expression") or dist.metadata.get("License", ""),
                          "notice_files": texts, "notice_text_found": bool(texts)})
    report = {"schema": 1, "kind": "build-environment-notice-inventory", "packages": inventory,
              "public_release_approved": False,
              "unresolved": ["Reconcile the separate Community acquisition and exact runtime-provenance receipts before publishing.",
                             "Distribute the matching Qt/PySide/Shiboken source companion and replacement instructions beside the final binary.",
                             "Review any packages without retained notice text and reconcile this environment inventory against bundled runtime files."]}
    write_json(destination / "inventory.json", report)
    return report


def manifest(directory, output):
    directory, output = Path(directory).resolve(), Path(output).resolve()
    files = []
    for path in sorted(directory.rglob("*")):
        if path == output:
            continue
        if path.is_symlink():
            raise ValueError("Symlinks are not accepted in a Windows release tree")
        if path.is_file():
            files.append({"path": path.relative_to(directory).as_posix(), "bytes": path.stat().st_size,
                          "sha256": digest(path)})
    if not files:
        raise ValueError("Cannot issue a manifest for an empty release tree")
    write_json(output, {"schema": 1, "files": files})
    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--notices", type=Path)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    info = version(args.root)
    if args.prepare:
        icon(args.root / "packaging/zone.ico")
        runtime_terms = (args.root / "packaging/runtime-notices/Microsoft-Visual-C-Runtime-2015-2022.txt").read_text(encoding="utf-8")
        (args.root / "packaging/installer-license.txt").write_text(
            "ZONE FOR WINDOWS - FREE BETA\n\n"
            "Zone is free to download and use in this beta. No payment or account is required.\n\n"
            "The Microsoft terms below apply only to the unmodified Microsoft Visual C++ runtime libraries bundled with Zone. "
            "They do not apply to Zone itself, Qt, PySide, Shiboken or other third-party components. "
            "Those components retain their own licenses. The accompanying licenses folder and matching dependency source download "
            "explain your rights, including replacement and debugging of LGPL libraries.\n\n"
            "MICROSOFT RUNTIME TERMS\n\n" + runtime_terms, encoding="utf-8-sig")
        (args.root / "packaging/version.iss").write_text(f'#define ZoneVersion "{info["version"]}"\n', encoding="utf-8")
        (args.root / "packaging/version_info.txt").write_text(
            "VSVersionInfo(ffi=FixedFileInfo(filevers=(" + info["version"].replace(".", ",") + ",0), "
            "prodvers=(" + info["version"].replace(".", ",") + ",0), mask=0x3f, flags=0, OS=0x40004, fileType=1, subtype=0, date=(0,0)), "
            "kids=[StringFileInfo([StringTable('040904B0', [StringStruct('CompanyName', 'Gramercy Systems 212 Inc'), "
            "StringStruct('FileDescription', 'Zone'), StringStruct('FileVersion', '" + info["version"] + "'), "
            "StringStruct('ProductName', 'Zone'), StringStruct('ProductVersion', '" + info["version"] + "'), "
            "StringStruct('OriginalFilename', 'Zone.exe'), StringStruct('LegalCopyright', 'Copyright 2026 Gramercy Systems 212 Inc')])]), "
            "VarFileInfo([VarStruct('Translation', [1033, 1200])])])\n", encoding="utf-8")
    if args.notices:
        collect_notices(args.notices)
    if args.manifest:
        manifest(args.manifest, args.manifest / "release-manifest.json")


if __name__ == "__main__":
    main()
