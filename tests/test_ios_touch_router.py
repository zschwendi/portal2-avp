"""Commandes tactiles iOS : tests/checks_touch_router.c compilé seul (un seul
appel au compilateur, ASan et UBSan) et exécuté sur l'hôte, sans abi-smoke.
Ils couvrent la logique C de runtime/ios/touch_router.c, pas la surcouche UIKit."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

DRIVER = r'''
#include <stdio.h>
typedef void (*rt_check_fn)(void);
static struct { const char *name; rt_check_fn fn; } checks[64];
static int count;
void rt_register_check(const char *name, rt_check_fn fn) {
    if (count < 64) { checks[count].name = name; checks[count].fn = fn; ++count; }
}
int main(void) {
    for (int i = 0; i < count; ++i) { checks[i].fn(); printf("ok %s\n", checks[i].name); }
    printf("%d\n", count);
    return 0;
}
'''


class TouchRouterTest(unittest.TestCase):
    def test_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            driver = Path(tmp) / 'driver.c'
            driver.write_text(DRIVER)
            exe = Path(tmp) / 'touch-router'
            subprocess.run(['clang', '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                            '-I', str(ROOT / 'runtime'), '-I', str(ROOT / 'tests'),
                            str(ROOT / 'tests/checks_touch_router.c'), str(driver), '-o', str(exe)],
                           check=True)
            out = subprocess.run([str(exe)], check=True, capture_output=True, text=True).stdout
        names = [line[3:] for line in out.splitlines() if line.startswith('ok ')]
        self.assertGreaterEqual(len(names), 8, out)
        for name in ('touch_router_multi_finger_release', 'touch_router_cancel_releases_and_forgets',
                     'touch_router_menu_vs_game_route', 'touch_router_rotation_releases',
                     'touch_router_controller_handoff_and_background', 'touch_router_layout_fits'):
            self.assertIn(name, names)

    def test_overlay_uses_router(self):
        # La surcouche UIKit délègue la propriété des doigts au routeur testé et
        # relâche tout au départ en arrière-plan, à la connexion d'une manette ou
        # d'un clavier et à chaque nouvelle disposition.
        source = (ROOT / 'runtime/ios/touch_controls.m').read_text()
        for needle in ('rt_touch_down(', 'rt_touch_up(', 'rt_touch_set_menu(', 'rt_touch_set_hidden(',
                       'rt_touch_set_active(', 'rt_touch_set_layout(', 'UIApplicationWillResignActiveNotification',
                       'UIApplicationDidEnterBackgroundNotification', 'GCControllerDidConnectNotification'):
            self.assertIn(needle, source)
        self.assertNotIn('NSMapTable', source)


if __name__ == '__main__':
    unittest.main()
