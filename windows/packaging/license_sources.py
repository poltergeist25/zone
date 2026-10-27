"""Build-time, checksum-pinned dependency source companion. Not app runtime."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(entry, cache):
    target = Path(cache) / entry["filename"]
    if target.exists() and sha256(target) == entry["sha256"]:
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".download")
    try:
        total = 0
        with urllib.request.urlopen(entry["url"], timeout=60) as response, temporary.open("wb") as stream:
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                total += len(chunk)
                if total > 100_000_000:
                    raise ValueError("Source archive exceeds its bounded download size")
                stream.write(chunk)
        if sha256(temporary) != entry["sha256"]:
            raise ValueError("Dependency source checksum mismatch: " + entry["filename"])
        temporary.replace(target)
        return target
    finally:
        temporary.unlink(missing_ok=True)


def bundle(output, cache):
    manifest = json.loads((HERE / "source-manifest.json").read_text(encoding="utf-8"))
    files = [(fetch(entry, cache), "sources/" + entry["filename"]) for entry in manifest["sources"]]
    files.extend((HERE / name, name) for name in ["source-manifest.json", "licensing.md"])
    files.extend((path, "modelnotices/" + path.relative_to(HERE / "modelnotices").as_posix())
                 for path in sorted((HERE / "modelnotices").rglob("*")) if path.is_file())
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".temporary")
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED) as archive:
            for path, name in files:
                info = zipfile.ZipInfo(name, (2026, 10, 26, 0, 0, 0))
                info.external_attr = 0o644 << 16
                archive.writestr(info, path.read_bytes())
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    receipt = {"schema": 1, "archive": output.name, "sha256": sha256(output),
               "sources": [{"filename": e["filename"], "sha256": e["sha256"]} for e in manifest["sources"]]}
    output.with_suffix(output.suffix + ".json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return receipt


def verify_model(path):
    expected = json.loads((HERE / "modelnotices/components.json").read_text(encoding="utf-8"))
    if sha256(path) != expected["bundle_sha256"]:
        raise ValueError("Task bundle differs from the licensed component inventory")
    with zipfile.ZipFile(path) as archive:
        if set(archive.namelist()) != set(expected["components"]):
            raise ValueError("Unexpected task bundle component")
        for name, item in expected["components"].items():
            if hashlib.sha256(archive.read(name)).hexdigest() != item["sha256"]:
                raise ValueError("Task component differs: " + name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--cache", type=Path, default=HERE / "source-cache")
    parser.add_argument("--verify-model", type=Path)
    args = parser.parse_args()
    if args.verify_model:
        verify_model(args.verify_model)
    if args.output:
        print(json.dumps(bundle(args.output, args.cache)))
    if not args.output and not args.verify_model:
        parser.error("Supply --output and/or --verify-model")
