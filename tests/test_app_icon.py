"""Original app icon: generated catalogs, layer formats and build wiring.

Checks the committed output of art/icon/generate_icon.swift (dimensions and
colour type read from the PNG headers, asset catalog references, the split oval's
recorded geometry and where its halves land in the decoded PNGs), the visionOS
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
import zlib

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


def png_pixels(path):
    """pixel(x, y) -> RGBA tuple for an 8-bit, non-interlaced RGB or RGBA PNG."""
    data, pos, idat = path.read_bytes(), 8, b''
    width, height, depth, colour_type = png_header(path)
    assert depth == 8 and colour_type in (RGB, RGBA) and data[28] == 0, path
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        if kind == b'IDAT':
            idat += data[pos + 8:pos + 8 + length]
        pos += 12 + length
    raw, bpp = zlib.decompress(idat), 3 if colour_type == RGB else 4
    stride, rows, prev = width * bpp, [], bytearray(width * bpp)
    for y in range(height):
        kind, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a, b = line[i - bpp] if i >= bpp else 0, prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if kind == 1: line[i] = (line[i] + a) & 255
            elif kind == 2: line[i] = (line[i] + b) & 255
            elif kind == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return lambda x, y: tuple(rows[y][x * bpp:(x + 1) * bpp]) + ((255,) if bpp == 3 else ())


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

    def test_split_oval_fits_the_circle_and_keeps_its_seams_under_parallax(self):
        params = json.loads((ROOT / 'art/icon/parameters.json').read_text())
        self.assertEqual([(h['name'], h['layer'], h['side']) for h in params['halves']],
                         [('blue', 'Middle', 'left'), ('orange', 'Front', 'right')])
        oval = params['emblem']
        shifts = [params['back']['preview_shift_px']] + [h['preview_shift_px'] for h in params['halves']]
        # The stroke's outer edge peaks at the major-axis ends: well inside the visionOS circle (radius 512)
        # even at the largest preview parallax shift.
        extent = math.dist(oval['centre_px'], (512, 512)) + oval['semi_axes_px'][1] + oval['stroke_px'] / 2
        self.assertAlmostEqual(oval['outer_extent_px'], extent, places=1)
        self.assertLess(extent + max(map(abs, shifts)), 420)
        # The two halves shift against each other by at most this much; the seams stay clearly open.
        self.assertGreaterEqual(oval['seam_px'] - abs(shifts[2] - shifts[1]), 16)

    def test_rendered_halves_sit_on_their_own_layers(self):
        oval = json.loads((ROOT / 'art/icon/parameters.json').read_text())['emblem']
        (cx, cy), (rx, ry) = oval['centre_px'], oval['semi_axes_px']
        c, s = math.cos(math.radians(oval['tilt_deg'])), math.sin(math.radians(oval['tilt_deg']))
        at = lambda x, y: (round(cx + x * c - y * s), round(cy + x * s + y * c))  # oval frame -> pixel
        layer = lambda name: STACK / f'{name}.solidimagestacklayer/Content.imageset/{name}.png'
        middle, front, back = png_pixels(layer('Middle')), png_pixels(layer('Front')), png_pixels(layer('Back'))
        flat = png_pixels(IOS_SET / 'AppIcon.png')
        blue, orange = at(-rx, 0), at(rx, 0)
        self.assertEqual((middle(*blue)[3], front(*blue)[3]), (255, 0))
        self.assertEqual((middle(*orange)[3], front(*orange)[3]), (0, 255))
        r, g, b = flat(*blue)[:3]
        self.assertGreater(b, r + 100)
        r, g, b = flat(*orange)[:3]
        self.assertGreater(r, b + 100)
        for seam in (at(0, -ry), at(0, ry)):  # open seams: clear on both colour layers, porcelain beneath
            self.assertEqual((middle(*seam)[3], front(*seam)[3]), (0, 0), seam)
            self.assertGreater(min(back(*seam)[:3]), 200, seam)
        for corner in ((0, 0), (1023, 0), (0, 1023), (1023, 1023), (512, 512)):
            self.assertEqual((middle(*corner)[3], front(*corner)[3]), (0, 0), corner)


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
