#!/usr/bin/env python3
"""Build the native Mac app. Requires Xcode Command Line Tools."""
import argparse
import platform
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--destination', type=Path, default=Path.home() / 'Applications/Watermark Remover')
args = parser.parse_args()
app = args.destination.resolve() / 'Watermark Remover.app'
contents = app / 'Contents'
minimum_macos = '13.0'
for directory in ('MacOS', 'Resources'):
    (contents / directory).mkdir(parents=True, exist_ok=True)
subprocess.run(['swiftc', '-swift-version', '5', '-O', '-target',
                f'{platform.machine()}-apple-macosx{minimum_macos}', '-framework', 'AppKit',
                '-framework', 'UniformTypeIdentifiers', str(source / 'WatermarkRemover.swift'),
                '-o', str(contents / 'MacOS/WatermarkRemover')], check=True)
shutil.copyfile(source / 'remove_watermark.py', contents / 'Resources/remove_watermark.py')
with tempfile.TemporaryDirectory() as temporary:
    iconset = Path(temporary) / 'AppIcon.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            target = iconset / f'icon_{size}x{size}{suffix}.png'
            pixels = str(size * scale)
            subprocess.run(['sips', '-z', pixels, pixels, str(source / 'AppIcon.png'),
                            '--out', str(target)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['iconutil', '-c', 'icns', '-o', str(contents / 'Resources/AppIcon.icns'),
                    str(iconset)], check=True)
with (contents / 'Info.plist').open('wb') as handle:
    plistlib.dump({
        'CFBundleName': 'Watermark Remover',
        'CFBundleDisplayName': 'Watermark Remover',
        'CFBundleIdentifier': 'local.manu.watermark-remover',
        'CFBundleExecutable': 'WatermarkRemover',
        'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '2',
        'CFBundleIconFile': 'AppIcon.icns',
        'CFBundleShortVersionString': '1.0',
        'LSMinimumSystemVersion': minimum_macos,
        'NSHighResolutionCapable': True,
        'NSHumanReadableCopyright': 'Local video editing utility',
        'CFBundleDocumentTypes': [{
            'CFBundleTypeName': 'Video', 'CFBundleTypeRole': 'Viewer',
            'LSHandlerRank': 'Alternate',
            'CFBundleTypeExtensions': ['mp4', 'mov', 'm4v', 'mkv', 'webm'],
        }],
    }, handle)
subprocess.run(['xattr', '-cr', str(app)], check=True)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
shutil.copy2(source / 'README.md', args.destination / 'README.md')
print(app)
