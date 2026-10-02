#!/usr/bin/env python3
"""Precisely adapt Codex 26.930.21537 sidebar selection and view revival for CCS/Theia.
Default: check only. --apply opts in; --restore ORIGINAL_JS restores a backup.
No extension payload is distributed. Python 3.9+, standard library only.
SPDX-License-Identifier: MIT
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile

VERSION = "26.930.21537"
ORIGINAL_SHA256 = "241516830f7a2fa29ae50c7f5a3a4011f4964697f8d883631ab69ef40f683bab"
PATCHED_SHA256 = "adb104453824bf13be4492d32db850cb1e28be208192b85822bb81639d53f2ea"
BEFORE = b"function WN(t){let e=YVt(t);"
AFTER = b"function WN(t){if(process.env.THEIA_PARENT_PID)return!1;let e=YVt(t);"
BEFORE_VIEW = b"async resolveWebviewView(e,r,n){this.sidebarView=e,"
AFTER_VIEW = b"async resolveWebviewView(e,r,n){if(process.env.THEIA_PARENT_PID){let o=this.__ccsPendingWebviews??=new Map;o.set(e.viewType,e);await new Promise(i=>setTimeout(i,250));if(o.get(e.viewType)!==e)return;o.delete(e.viewType);if(n?.isCancellationRequested)return}this.sidebarView=e,"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def transform_source(data):
    if data.count(BEFORE) != 1 or data.count(BEFORE_VIEW) != 1:
        raise ValueError("Expected exactly one sidebar selector and one view resolver.")
    return data.replace(BEFORE, AFTER, 1).replace(BEFORE_VIEW, AFTER_VIEW, 1)


def within(path, directory):
    try:
        path.resolve().relative_to(directory.resolve())
        return True
    except ValueError:
        return False


def replace_atomic(target, replacement, expected_current):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix="codex-theia-", suffix=".tmp",
                                         dir=str(target.parent), delete=False) as output:
            temporary = Path(output.name)
            output.write(replacement)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, target.stat().st_mode)
        if digest(target.read_bytes()) != expected_current:
            raise ValueError("Extension changed during preparation; no replacement performed.")
        os.replace(temporary, target)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extension-dir", type=Path, help="installed extension directory containing package.json")
    parser.add_argument("--backup-dir", type=Path,
                        default=Path.home() / "Documents" / "Codex" / "CCS21-Codex-backups")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--apply", action="store_true")
    action.add_argument("--restore", type=Path, metavar="ORIGINAL_JS")
    args = parser.parse_args(argv)
    try:
        if args.extension_dir is None:
            local_data = os.environ.get("LOCALAPPDATA")
            if not local_data:
                raise ValueError("Specify --extension-dir when LOCALAPPDATA is unavailable.")
            args.extension_dir = Path(local_data) / "Texas Instruments" / "CCS" / "ccs2101" / "0" / "theia" / "deployedPlugins" / ("openai.chatgpt@" + VERSION) / "extension"
        directory = args.extension_dir.resolve()
        package = json.loads((directory / "package.json").read_text(encoding="utf-8-sig"))
        if (package.get("publisher"), package.get("name"), package.get("version")) != ("openai", "chatgpt", VERSION):
            raise ValueError("Only openai.chatgpt {} is supported.".format(VERSION))
        binary = directory / "bin" / "windows-x86_64" / "codex.exe"
        if not binary.is_file() or binary.stat().st_size < 1024 * 1024:
            raise ValueError("Windows x64 Codex backend is missing; repair the platform package first.")
        with binary.open("rb") as source:
            header = source.read(1024 * 1024)
        offset = struct.unpack_from("<I", header, 0x3C)[0] if len(header) >= 64 else len(header)
        if (header[:2] != b"MZ" or offset + 6 > len(header) or
                header[offset:offset + 4] != b"PE\x00\x00" or
                struct.unpack_from("<H", header, offset + 4)[0] != 0x8664):
            raise ValueError("Codex backend is not a Windows x64 executable.")
        target = directory / "out" / "extension.js"
        if target.is_symlink():
            raise ValueError("Extension JavaScript must be an ordinary file.")
        current = target.read_bytes()
        current_hash = digest(current)
        if current_hash not in (ORIGINAL_SHA256, PATCHED_SHA256):
            raise ValueError("Unrecognized extension.js hash; refusing to modify this build.")
        if args.restore:
            original = args.restore.resolve().read_bytes()
            if digest(original) != ORIGINAL_SHA256:
                raise ValueError("Backup does not match the exact official original source.")
            if current_hash == ORIGINAL_SHA256:
                print("Already original; nothing changed.")
                return 0
            replace_atomic(target, original, current_hash)
            print("Original JavaScript restored.")
        elif args.apply:
            if current_hash == PATCHED_SHA256:
                print("Compatibility patch already present; nothing changed.")
                return 0
            replacement = transform_source(current)
            if digest(replacement) != PATCHED_SHA256:
                raise ValueError("Patched hash mismatch; nothing changed.")
            backup_root = args.backup_dir.resolve()
            deployed_plugins = directory.parent.parent
            if within(backup_root, deployed_plugins) or within(deployed_plugins, backup_root):
                raise ValueError("Backup must be outside the CCS plugin scan directory.")
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            backup = backup_root / ("codex-theia-sidebar-" + stamp) / "extension.js"
            backup.parent.mkdir(parents=True, exist_ok=False)
            shutil.copy2(target, backup)
            if digest(backup.read_bytes()) != ORIGINAL_SHA256:
                raise ValueError("Backup verification failed; nothing changed.")
            print("Original backup: {}".format(backup))
            replace_atomic(target, replacement, current_hash)
            print("Exact Theia sidebar-selection patch applied.")
        else:
            print("Recognized {} source; check only, nothing changed.".format(
                "patched" if current_hash == PATCHED_SHA256 else "official original"))
            return 0
        print("Required: CCS Ctrl+Shift+P -> Reload Window. Runtime success is not yet verified.")
        return 0
    except (OSError, ValueError) as error:
        print("ERROR: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
