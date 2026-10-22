#!/usr/bin/env python3
"""Write appcast.xml next to a signed archive, from Sparkle's sign_update output; no secrets.

    make-appcast.py VERSION BUILD ARCHIVE SIGNATURE

VERSION is CFBundleShortVersionString and BUILD is CFBundleVersion, which is what Sparkle
compares to decide whether an update is newer.
"""
import datetime, email.utils, json, pathlib, re, sys, xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ROOT = pathlib.Path(__file__).resolve().parent.parent


def signed(archive_name, signature_name):
    """The archive, its Ed25519 signature and its length, checked against the archive."""
    archive = pathlib.Path(archive_name)
    signature = pathlib.Path(signature_name).read_text()
    match = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', signature)
    length = re.search(r'length="(\d+)"', signature)
    if not match or not length or int(length[1]) != archive.stat().st_size:
        raise SystemExit(f'Missing signature or archive length mismatch: {archive.name}')
    return archive, match[1], length[1]


def main(args):
    if len(args) != 4:
        raise SystemExit(__doc__)
    version, build, archive_name, signature_name = args
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not build.isdigit():
        raise SystemExit(f'Expected VERSION like 0.2.3 and a numeric BUILD, got {version!r} {build!r}')
    config = json.loads((ROOT / 'scripts/release-config.json').read_text())
    archive, signature, length = signed(archive_name, signature_name)
    repo = config['repository']

    ET.register_namespace('sparkle', SPARKLE)
    rss = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Alcove updates'
    ET.SubElement(channel, 'link').text = f'https://github.com/{repo}'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Alcove {version}'
    ET.SubElement(item, 'pubDate').text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = build
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = config['minimum_system_version']
    ET.SubElement(item, f'{{{SPARKLE}}}fullReleaseNotesLink').text = f'https://github.com/{repo}/releases/tag/v{version}'
    ET.SubElement(item, 'description').text = f'Release notes: https://github.com/{repo}/releases/tag/v{version}'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/{repo}/releases/download/v{version}/{archive.name}',
        'length': length,
        'type': 'application/octet-stream',
        f'{{{SPARKLE}}}edSignature': signature,
    })
    ET.indent(rss)
    ET.ElementTree(rss).write(archive.parent / 'appcast.xml', encoding='utf-8', xml_declaration=True)


if __name__ == '__main__':
    main(sys.argv[1:])
