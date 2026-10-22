#!/usr/bin/env python3
"""Sign a bundle's nested code from the inside out with hardened runtime and a timestamp.

    sign-nested.py BUNDLE IDENTITY

Every Mach-O file and every nested .app, .xpc and .framework is signed, deepest first, then
BUNDLE itself. Identifiers and entitlements already on the code are kept (Sparkle's helpers
carry their own). Notarization rejects nested code that is unsigned, ad-hoc signed, or signed
without hardened runtime or a secure timestamp.
"""
import pathlib, subprocess, sys

bundle = pathlib.Path(sys.argv[1])
identity = sys.argv[2]


def sign(path, preserve_entitlements=True):
    args = ['codesign', '--force', '--options', 'runtime', '--timestamp']
    if preserve_entitlements:
        args.append('--preserve-metadata=identifier,entitlements')
    args += ['--sign', identity, str(path)]
    subprocess.run(args, check=True)


magic = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
         b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
paths = [p for p in bundle.rglob('*') if not p.is_symlink()]
nested = [p for p in paths if p.is_dir() and p.suffix in {'.app', '.xpc', '.framework'}]
# The main executable is signed as part of BUNDLE; every other Mach-O file on its own.
main = bundle / 'Contents/MacOS' / bundle.stem if bundle.suffix == '.app' else None
for p in paths:
    if p.is_file() and p != main and not any(n / 'Contents/MacOS' / n.stem == p for n in nested):
        with p.open('rb') as stream:
            if stream.read(4) in magic:
                sign(p)
for p in sorted(nested, key=lambda p: len(p.parts), reverse=True):
    sign(p)
sign(bundle, preserve_entitlements=False)
