"""Original app icon: generated catalogs, layer formats and build wiring.

Checks the committed output of art/icon/generate_icon.swift (dimensions and
colour type read from the PNG headers, asset catalog references), the visionOS
project wiring and tools/build_ios.py's partial-plist merge. No Xcode needed.
"""
import json
import math
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import build_ios  # noqa: E402

STACK = ROOT / 'visionos/GameAssets.xcassets/AppIcon.solidimagestack'
IOS_SET = ROOT / 'ios/Assets.xcassets/AppIcon.appiconset'
RGB, RGBA = 2, 6


def png_header(path):
    """(width, height, bit depth, colour type) from a PNG's IHDR chunk."""
    data = path.read_bytes()[:33]
    assert data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR', path
    return struct.unpack('>IIBB', data[16:26])


class GeneratedIconTests(unittest.TestCase):
    def test_vision_layers_are_1024_with_an_opaque_back(self):
        layers = json.loads((STACK / 'Contents.json').read_text())['layers']
        self.assertEqual([layer['filename'] for layer in layers],
                         ['Front.solidimagestacklayer', 'Middle.solidimagestacklayer', 'Back.solidimagestacklayer'])
        for name, colour_type in (('Front', RGBA), ('Middle', RGBA), ('Back', RGB)):
            imageset = STACK / f'{name}.solidimagestacklayer/Content.imageset'
            images = json.loads((imageset / 'Contents.json').read_text())['images']
            self.assertEqual(images, [dict(filename=f'{name}.png', idiom='vision', scale='2x')])
            self.assertEqual(png_header(imageset / f'{name}.png'), (1024, 1024, 8, colour_type), name)

    def test_ios_icon_is_a_single_opaque_universal_1024(self):
        images = json.loads((IOS_SET / 'Contents.json').read_text())['images']
        self.assertEqual(images, [dict(filename='AppIcon.png', idiom='universal', platform='ios', size='1024x1024')])
        self.assertEqual(png_header(IOS_SET / 'AppIcon.png'), (1024, 1024, 8, RGB))

    def test_catalogs_hold_only_referenced_images(self):
        for catalog in (ROOT / 'visionos/GameAssets.xcassets', ROOT / 'ios/Assets.xcassets'):
            for png in catalog.rglob('*.png'):
                listed = json.loads((png.parent / 'Contents.json').read_text())['images']
                self.assertIn(png.name, [image.get('filename') for image in listed], png)

    def test_parameters_record_both_gateways(self):
        params = json.loads((ROOT / 'art/icon/parameters.json').read_text())
        self.assertEqual([p['name'] for p in params['portals']], ['cyan', 'amber'])
        for portal in params['portals']:
            cx, cy = portal['screen']['centre_px']
            rx, ry = portal['screen']['radii_px']
            a = math.radians(portal['screen']['rotation_deg'])
            outline = [(cx + rx * math.cos(t) * math.cos(a) - ry * math.sin(t) * math.sin(a),
                        cy + rx * math.cos(t) * math.sin(a) + ry * math.sin(t) * math.cos(a))
                       for t in (i * math.pi / 180 for i in range(360))]
            # Rim well inside the visionOS circular mask (radius 512), leaving room for the glow.
            self.assertLess(max(math.dist(p, (512, 512)) for p in outline), 420, portal['name'])


class IconWiringTests(unittest.TestCase):
    def test_catalog_belongs_to_the_game_target_only(self):
        targets = (ROOT / 'visionos/project.yml').read_text().split('\ntargets:\n')[1].split('\nschemes:\n')[0]
        game, renderer = targets.split('\n  Portal2RendererCheck:\n')
        self.assertIn('- path: GameAssets.xcassets', game)
        self.assertIn('ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon', game)
        self.assertNotIn('GameAssets.xcassets', renderer)

    def test_partial_plist_replaces_icon_keys_and_keeps_the_rest(self):
        with tempfile.TemporaryDirectory() as tmp:
            info, partial = Path(tmp) / 'Info.plist', Path(tmp) / 'partial.plist'
            info.write_bytes(plistlib.dumps(dict(
                CFBundleExecutable='portal2', MinimumOSVersion='17.0',
                CFBundleIcons=dict(CFBundlePrimaryIcon=dict(CFBundleIconFiles=['AppIcon60x60'])))))
            icons = dict(CFBundlePrimaryIcon=dict(CFBundleIconFiles=['AppIcon60x60'], CFBundleIconName='AppIcon'))
            partial.write_bytes(plistlib.dumps({'CFBundleIcons': icons, 'CFBundleIcons~ipad': icons}))
            build_ios.merge_partial_plist(info, partial)
            merged = plistlib.loads(info.read_bytes())
        self.assertEqual(merged['CFBundleIcons'], icons)
        self.assertEqual(merged['CFBundleIcons~ipad'], icons)
        self.assertEqual((merged['CFBundleExecutable'], merged['MinimumOSVersion']), ('portal2', '17.0'))


if __name__ == '__main__':
    unittest.main()
