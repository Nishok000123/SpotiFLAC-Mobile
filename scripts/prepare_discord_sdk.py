#!/usr/bin/env python3
"""Stage the pinned official Discord Android SDK for local builds and CI."""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Optional


VERSION = "1.10.19337"
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = PROJECT_ROOT / ".dart_tool" / "discord-sdk" / VERSION
ENCRYPTED_ARCHIVE = PROJECT_ROOT / "third_party" / "discord" / f"discord-android-{VERSION}.zip.gpg"
FILES = {
    "lib/release/discord_partner_sdk.aar":
        "b1b2491f1e1848c79fd6f1986d5aa1e0c8019e88a6e62c7be06b89e8e4870933",
    "License-Notices.txt":
        "e8afa66340c225431e69768543cc34a7240f3494a9d759189fe118620ea8eebf",
}


class SdkError(Exception):
    pass


def verify(directory: Path) -> None:
    for relative, expected in FILES.items():
        path = directory / relative
        if not path.is_file():
            raise SdkError("Missing Discord SDK file: " + relative)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise SdkError(f"Discord SDK {VERSION} checksum mismatch: {relative}")


def unpack(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as zf:
        for relative in FILES:
            matches = [info for info in zf.infolist() if not info.is_dir() and
                       (info.filename == relative or info.filename.endswith("/" + relative))]
            if len(matches) != 1:
                raise SdkError("SDK archive must contain exactly one " + relative)
            path = destination / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            # Only these fixed Android destinations are written. Never extract
            # arbitrary ZIP paths, desktop binaries, or voice-model assets.
            with zf.open(matches[0]) as source, path.open("wb") as target:
                shutil.copyfileobj(source, target)


def prepare(output: Path, source_dir: Optional[Path] = None,
            archive: Optional[Path] = None, passphrase: Optional[str] = None) -> Path:
    output = output.expanduser().resolve()
    if source_dir is None and archive is None and output.is_dir():
        verify(output)
        return output
    if source_dir is None and archive is None and not passphrase:
        raise SdkError(
            f"Discord SDK {VERSION} is required. Set SPOTIFLAC_DISCORD_SDK_DIR "
            "to the extracted official SDK, or provide DISCORD_SDK_PASSPHRASE "
            "in CI. See DISCORD.md."
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="discord-sdk-", dir=output.parent) as temporary:
        staging = Path(temporary) / "sdk"
        if source_dir is not None:
            source_dir = source_dir.expanduser().resolve()
            verify(source_dir)
            for relative in FILES:
                target = staging / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source_dir / relative, target)
        else:
            if archive is None:
                archive = Path(temporary) / "sdk.zip"
                try:
                    result = subprocess.run(
                        ["gpg", "--batch", "--quiet", "--pinentry-mode", "loopback",
                         "--passphrase-fd", "0", "--output", str(archive),
                         "--decrypt", str(ENCRYPTED_ARCHIVE)],
                        input=passphrase.encode(), stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, check=False,
                    )
                except FileNotFoundError as exc:
                    raise SdkError("Install GnuPG to decrypt the bundled Discord SDK") from exc
                if result.returncode != 0:
                    raise SdkError("SDK decryption failed; check DISCORD_SDK_PASSPHRASE")
            unpack(archive, staging)
        verify(staging)
        for relative in FILES:
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            (staging / relative).replace(target)
    verify(output)
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--source-dir", type=Path,
                        default=os.environ.get("SPOTIFLAC_DISCORD_SDK_DIR"))
    parser.add_argument("--archive", type=Path, help="official SDK ZIP for offline setup")
    args = parser.parse_args()
    try:
        output = prepare(args.output, args.source_dir, args.archive,
                         os.environ.get("DISCORD_SDK_PASSPHRASE"))
    except (SdkError, OSError, zipfile.BadZipFile) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    # stdout is just the path so build scripts can export it without eval.
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
