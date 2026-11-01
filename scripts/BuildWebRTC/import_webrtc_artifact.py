#!/usr/bin/env python3
"""Publish the fixed WebRTC zip/metadata pair with one macOS directory exchange."""
import ctypes
from datetime import datetime, timezone
import errno
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004
ZIP_NAME = 'WebRTC.xcframework.zip'
METADATA_NAME = 'WebRTC.xcframework.metadata'


def _rename_directory(source, destination, flags):
    if sys.platform != 'darwin':
        raise OSError(errno.ENOTSUP, 'Atomic artifact publication requires macOS')
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), flags) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def _write_metadata(path, source_name, checksum):
    timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    with path.open('w') as stream:
        stream.write(f'source_zip={source_name}\nchecksum={checksum}\nimported_at={timestamp}\n')
        stream.flush()
        os.fsync(stream.fileno())


def _validate_destination(destination):
    # Replacing this directory must not discard an unrelated user file or follow
    # an artifact-directory symlink. Only the existing pair belongs to this tool.
    if destination.is_symlink():
        raise OSError(errno.ELOOP, 'Artifact directory must not be a symbolic link', str(destination))
    if destination.exists():
        unexpected = {path.name for path in destination.iterdir()} - {ZIP_NAME, METADATA_NAME}
        if unexpected:
            raise ValueError('Artifact directory contains unrelated files; existing contents were preserved')


def _cleanup_owned_pair(staging):
    if not os.path.lexists(staging):
        return
    if not staging.is_symlink():
        for name in (ZIP_NAME, METADATA_NAME):
            try:
                (staging / name).unlink()
            except (FileNotFoundError, IsADirectoryError):
                pass
        try:
            staging.rmdir()
            return
        except OSError as error:
            if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
                raise
    print(f'Unrelated staging contents were preserved at: {staging}', file=sys.stderr)


def import_artifact(source, destination, verifier):
    source, destination, verifier = Path(source), Path(destination), Path(verifier)
    _validate_destination(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # A sibling ensures the publication operation never crosses filesystems.
    # On exchange this owned staging path receives the previous directory.
    staging = Path(tempfile.mkdtemp(prefix=f'.{destination.name}.import-', dir=destination.parent))
    try:
        staged_zip = staging / ZIP_NAME
        subprocess.run(['cp', str(source), str(staged_zip)], check=True)
        with staged_zip.open('rb+') as stream:
            os.fsync(stream.fileno())
        # Validate the copied bytes, not a source that may change before copying.
        with tempfile.TemporaryDirectory(prefix='WebRTC-verify-') as unpacked:
            subprocess.run(['unzip', '-q', str(staged_zip), '-d', unpacked], check=True)
            subprocess.run([str(verifier), str(Path(unpacked) / 'WebRTC.xcframework')], check=True)
        digest = hashlib.sha256()
        with staged_zip.open('rb') as stream:
            for block in iter(lambda: stream.read(1_048_576), b''):
                digest.update(block)
        checksum = digest.hexdigest()
        _write_metadata(staging / METADATA_NAME, source.name, checksum)
        # No delete/move fallback: unsupported filesystems leave the old pair in
        # place. An initial publication must not replace a concurrent install.
        _validate_destination(destination)
        flags = RENAME_SWAP if destination.exists() else RENAME_EXCL
        _rename_directory(staging, destination, flags)
    finally:
        _cleanup_owned_pair(staging)
    return checksum


def main():
    if len(sys.argv) != 4:
        raise ValueError('Expected source zip, artifact directory and verifier')
    checksum = import_artifact(*map(Path, sys.argv[1:]))
    print(f'Imported: {Path(sys.argv[2]) / ZIP_NAME}')
    print(f'Checksum: {checksum}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'WebRTC artifact import failed: {error}', file=sys.stderr)
        sys.exit(1)
