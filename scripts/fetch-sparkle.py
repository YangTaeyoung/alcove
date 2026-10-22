#!/usr/bin/env python3
"""Fetch the pinned official Sparkle release into build/vendor/sparkle and print that path.

The release scripts use its tools (generate_keys, sign_update); the app itself links Sparkle
through the Swift package pinned to the same version in project.yml. Private signing keys
are never files: generate_keys and sign_update read the key from the login Keychain.
"""
import hashlib, json, pathlib, subprocess

root = pathlib.Path(__file__).resolve().parent.parent
config = json.loads((root / 'scripts/release-config.json').read_text())
vendor = root / 'build/vendor'
vendor.mkdir(parents=True, exist_ok=True)
archive = vendor / f'Sparkle-{config["sparkle_version"]}.tar.xz'
if not archive.exists():
    subprocess.run(['curl', '-fsSL', '--retry', '3',
        f'https://github.com/sparkle-project/Sparkle/releases/download/{config["sparkle_version"]}/{archive.name}',
        '-o', str(archive)], check=True)
if hashlib.sha256(archive.read_bytes()).hexdigest() != config['sparkle_sha256']:
    raise SystemExit('Sparkle archive checksum mismatch; refusing to use it')
destination = vendor / 'sparkle'
destination.mkdir(exist_ok=True)
# The pinned digest authenticates the archive; tar keeps the framework's symlinks.
subprocess.run(['tar', '-xf', str(archive), '-C', str(destination)], check=True)
print(destination)
