#!/usr/bin/env python3
"""Download the official Windows x64 Codex VSIX; optionally repair CCS21.

This utility distributes no OpenAI extension payload and changes no extension
code, settings, login data, or running process. Python 3.9+; standard library.
SPDX-License-Identifier: MIT
"""

import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import struct
import sys
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

VERSION = "26.930.21537"
EXTENSION_ID = "openai.chatgpt"
TARGET_PLATFORM = "win32-x64"
PACKAGE_NAME = "openai.chatgpt-{}-win32-x64.vsix".format(VERSION)
PACKAGE_URL = (
    "https://openai.gallery.vsassets.io/_apis/public/gallery/publisher/"
    "openai/extension/chatgpt/{}/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage?targetPlatform=win32-x64"
).format(VERSION)
EXPECTED_SHA256 = "9eacd2fa590119245ae0a71eddf9f8f5310d070343a5586801fae99f62086251"
WINDOWS_BINARY = "extension/bin/windows-x86_64/codex.exe"
MAX_ARCHIVE_SIZE = 2 * 1024 ** 3
MAX_EXPANDED_SIZE = 3 * 1024 ** 3
MAX_FILES = 50000
CHUNK_SIZE = 1024 * 1024
MANIFEST_NAMESPACE = "http://schemas.microsoft.com/developer/vsx-schema/2011"
DEVICE_NAMES = {"CON", "PRN", "AUX", "NUL"} | {
    "{}{}".format(prefix, number)
    for prefix in ("COM", "LPT") for number in range(1, 10)
}


class RepairError(Exception):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_bounded(source, destination, maximum):
    total = 0
    while True:
        chunk = source.read(CHUNK_SIZE)
        if not chunk:
            break
        total += len(chunk)
        if total > maximum:
            raise RepairError("Download exceeds the permitted package size.")
        destination.write(chunk)


def download_package(output_dir):
    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    final_path = output_dir / PACKAGE_NAME
    if final_path.exists():
        print("Existing file will be validated: {}".format(final_path))
        return final_path, None
    print("Downloading official {} package, version {}...".format(TARGET_PLATFORM, VERSION))
    request = urllib.request.Request(PACKAGE_URL, headers={
        "User-Agent": "CCS21-Codex-platform-repair/1.0",
        "Accept-Encoding": "identity",
    })
    with tempfile.TemporaryDirectory(prefix="codex-download-", dir=str(output_dir)) as scratch:
        raw_path = Path(scratch) / "download.transport"
        decoded_path = Path(scratch) / "package.vsix"
        with urllib.request.urlopen(request, timeout=120) as response:
            encoding = response.headers.get("Content-Encoding", "").lower().strip()
            with raw_path.open("wb") as destination:
                copy_bounded(response, destination, MAX_ARCHIVE_SIZE)
        with raw_path.open("rb") as source:
            magic = source.read(2)
        # Marketplace may return gzip transport despite Accept-Encoding: identity.
        # Decode transport before checksum/ZIP validation, preserving VSIX bytes.
        if magic == b"\x1f\x8b":
            with gzip.open(raw_path, "rb") as source, decoded_path.open("wb") as destination:
                copy_bounded(source, destination, MAX_ARCHIVE_SIZE)
        elif encoding in ("", "identity", "gzip", "x-gzip") and magic == b"PK":
            decoded_path = raw_path
        else:
            raise RepairError("Server returned neither a ZIP VSIX nor gzip-encoded VSIX.")
        report = validate_package(decoded_path)
        # Never overwrite a file which appeared while the download was running.
        with final_path.open("xb") as destination, decoded_path.open("rb") as source:
            shutil.copyfileobj(source, destination, CHUNK_SIZE)
    report["path"] = str(final_path)
    return final_path, report


def safe_member_name(info):
    name = info.filename
    if not name or "\\" in name or "\x00" in name or name.startswith("/"):
        raise RepairError("Unsafe ZIP member path.")
    parts = name.rstrip("/").split("/")
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise RepairError("Unsafe ZIP member path: {}".format(name))
    for part in parts:
        if any(character in part for character in ':<>"|?*') or part.endswith((".", " ")):
            raise RepairError("Unsafe Windows ZIP member path: {}".format(name))
        if part.split(".", 1)[0].upper() in DEVICE_NAMES:
            raise RepairError("Reserved Windows name in ZIP: {}".format(name))
    mode = info.external_attr >> 16
    if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
        raise RepairError("ZIP links or special files are not permitted: {}".format(name))
    if info.flag_bits & 1:
        raise RepairError("Encrypted ZIP member is not permitted.")
    return PurePosixPath(*parts)


def read_small_member(archive, name):
    try:
        info = archive.getinfo(name)
    except KeyError:
        raise RepairError("Required package file is missing: {}".format(name))
    if info.file_size > 4 * 1024 ** 2:
        raise RepairError("Package metadata is unexpectedly large.")
    return archive.read(info)


def validate_package(path):
    path = path.resolve()
    if not path.is_file() or path.stat().st_size > MAX_ARCHIVE_SIZE:
        raise RepairError("VSIX must be an existing file smaller than 2 GiB.")
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            if len(infos) > MAX_FILES or sum(info.file_size for info in infos) > MAX_EXPANDED_SIZE:
                raise RepairError("ZIP exceeds the permitted file count or expanded size.")
            seen = set()
            files = set()
            for info in infos:
                name = str(safe_member_name(info)).casefold()
                if name in seen:
                    raise RepairError("Duplicate ZIP path: {}".format(info.filename))
                seen.add(name)
                if not info.is_dir():
                    files.add(name)
            for name in seen:
                parent = PurePosixPath(name).parent
                while str(parent) != ".":
                    if str(parent) in files:
                        raise RepairError("ZIP file conflicts with a parent directory.")
                    parent = parent.parent
            manifest = ET.fromstring(read_small_member(archive, "extension.vsixmanifest"))
            identity = manifest.find("{{{}}}Metadata/{{{}}}Identity".format(
                MANIFEST_NAMESPACE, MANIFEST_NAMESPACE))
            if identity is None:
                raise RepairError("VSIX identity is missing.")
            expected = {"Publisher": "openai", "Id": "chatgpt", "Version": VERSION,
                        "TargetPlatform": TARGET_PLATFORM}
            for key, value in expected.items():
                if identity.get(key) != value:
                    raise RepairError("Wrong {}: expected {}, found {}.".format(
                        key, value, identity.get(key, "<missing>")))
            package = json.loads(read_small_member(archive, "extension/package.json"))
            if (package.get("publisher"), package.get("name"), package.get("version")) != (
                    "openai", "chatgpt", VERSION):
                raise RepairError("package.json identity/version does not match the required extension.")
            read_small_member(archive, "[Content_Types].xml")
            try:
                with archive.open(WINDOWS_BINARY) as source:
                    binary_header = source.read(1024 * 1024)
            except KeyError:
                raise RepairError("Windows backend is missing: {}".format(WINDOWS_BINARY))
            if binary_header[:2] != b"MZ" or len(binary_header) < 64:
                raise RepairError("Windows backend does not contain a PE executable.")
            pe_offset = struct.unpack_from("<I", binary_header, 0x3C)[0]
            if (pe_offset + 6 > len(binary_header) or
                    binary_header[pe_offset:pe_offset + 4] != b"PE\x00\x00" or
                    struct.unpack_from("<H", binary_header, pe_offset + 4)[0] != 0x8664):
                raise RepairError("Windows backend is not a valid x86-64 PE executable.")
            failed = archive.testzip()
            if failed is not None:
                raise RepairError("ZIP checksum failure: {}".format(failed))
        digest = sha256(path)
        if digest != EXPECTED_SHA256:
            raise RepairError("SHA-256 differs from the verified official fixed-version package: {}".format(digest))
        return {"path": str(path), "extension": EXTENSION_ID, "version": VERSION,
                "platform": TARGET_PLATFORM, "sha256": digest, "files": len(infos)}
    except (zipfile.BadZipFile, ET.ParseError, json.JSONDecodeError, UnicodeError) as error:
        raise RepairError("Invalid VSIX: {}".format(error)) from error


def extract_package(path, destination):
    destination = destination.resolve()
    with zipfile.ZipFile(path) as archive:
        for info in archive.infolist():
            relative = safe_member_name(info)
            target = destination.joinpath(*relative.parts)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as source, target.open("xb") as output:
                shutil.copyfileobj(source, output, CHUNK_SIZE)
            # Retain official file contents and ordinary modification timestamps.
            stamp = datetime.datetime(*info.date_time).timestamp()
            os.utime(target, (stamp, stamp))


def default_deployed_plugins():
    local_data = os.environ.get("LOCALAPPDATA")
    if not local_data:
        raise RepairError("LOCALAPPDATA is unavailable; specify --deployed-plugins.")
    return Path(local_data) / "Texas Instruments" / "CCS" / "ccs2101" / "0" / "theia" / "deployedPlugins"


def is_within(path, directory):
    try:
        path.resolve().relative_to(directory.resolve())
        return True
    except ValueError:
        return False


def install_package(path, deployed_plugins, backup_root):
    if os.name != "nt" or platform.machine().lower() not in ("amd64", "x86_64"):
        raise RepairError("--install is only supported on Windows x64.")
    deployed_plugins = deployed_plugins.resolve()
    if not deployed_plugins.is_dir():
        raise RepairError("CCS deployedPlugins directory does not exist.")
    target = deployed_plugins / (EXTENSION_ID + "@" + VERSION)
    if target.is_symlink() or not target.is_dir():
        raise RepairError("Existing exact-version extension directory is missing or is a link: {}".format(target))
    backup_root = backup_root.resolve()
    if is_within(backup_root, deployed_plugins) or is_within(deployed_plugins, backup_root):
        raise RepairError("Backup directory must be outside and independent of deployedPlugins.")
    backup_root.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup = backup_root / ((EXTENSION_ID + "@" + VERSION) + "-" + timestamp)
    # Copy backup first. If this fails, the installed directory is untouched.
    print("Creating backup outside the CCS extension scan: {}".format(backup))
    shutil.copytree(target, backup, symlinks=True)
    staging_root = Path(tempfile.mkdtemp(prefix="codex-platform-stage-", dir=str(deployed_plugins.parent)))
    keep_staging = False
    try:
        staged = staging_root / "windows-package"
        previous = staging_root / "previous-installation"
        staged.mkdir()
        extract_package(path, staged)
        moved_previous = False
        moved_new = False
        try:
            # All renames use the same filesystem; stage is outside plugin scan.
            target.rename(previous)
            moved_previous = True
            staged.rename(target)
            moved_new = True
            if not (target / WINDOWS_BINARY).is_file():
                raise RepairError("Installed Windows backend is unexpectedly missing.")
        except Exception as error:
            try:
                if moved_new:
                    target.rename(staging_root / "failed-new-installation")
                if moved_previous:
                    previous.rename(target)
                elif not target.exists():
                    shutil.copytree(backup, target, symlinks=True)
            except Exception as restore_error:
                # Keep the backup and temporary previous directory for recovery.
                keep_staging = True
                raise RepairError("Installation failed; automatic restoration failed. Backup: {}. Staging: {}. {}".format(
                    backup, staging_root, restore_error)) from error
            raise RepairError("Installation failed; prior installation was restored. Close CCS and retry. {}".format(error)) from error
    finally:
        if not keep_staging:
            try:
                shutil.rmtree(staging_root)
            except OSError as cleanup_error:
                print("WARNING: temporary staging could not be cleaned up: {}. {}".format(
                    staging_root, cleanup_error), file=sys.stderr)
    print("Installed official {} version {}. Backup: {}".format(TARGET_PLATFORM, VERSION, backup))
    print("Required next step: open CCS, then Ctrl+Shift+P -> Reload Window.")
    print("Runtime success is not yet verified. Check backend startup and the Codex sidebar after reload.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=Path.cwd() / "codex-download",
                        help="directory for official download (default: ./codex-download)")
    parser.add_argument("--vsix", type=Path, help="validate/use an existing VSIX without downloading")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--install", action="store_true", help="opt in to backup and replace the CCS installed package")
    action.add_argument("--validate-only", action="store_true", help="only validate; does not alter the CCS installation")
    parser.add_argument("--deployed-plugins", type=Path, help="CCS21 deployedPlugins directory (Windows default auto-detected)")
    parser.add_argument("--backup-dir", type=Path,
                        default=Path.home() / "Documents" / "Codex" / "CCS21-Codex-backups",
                        help="backup root outside CCS (default: Documents/Codex/CCS21-Codex-backups)")
    args = parser.parse_args(argv)
    try:
        if args.vsix:
            package_path = args.vsix.resolve()
            report = validate_package(package_path)
        else:
            package_path, report = download_package(args.output_dir)
            if report is None:
                report = validate_package(package_path)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if args.install:
            deployed = args.deployed_plugins if args.deployed_plugins else default_deployed_plugins()
            # Recheck bytes immediately before any installation mutation.
            if sha256(package_path) != EXPECTED_SHA256:
                raise RepairError("VSIX changed since validation.")
            install_package(package_path, deployed, args.backup_dir)
        else:
            print("Validation passed. CCS was not changed; use --install to opt in to replacement.")
        return 0
    except (RepairError, OSError, urllib.error.URLError, EOFError) as error:
        print("ERROR: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
