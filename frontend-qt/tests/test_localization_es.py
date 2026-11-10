"""The Qt table carries the Spanish column, read from frontend/l10n/es.json (the rules every file keeps are in test_localization_rules.py)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'frontend-qt'))

from nspb_qt.i18n import Lang   # noqa: E402
from nspb_qt.l10n import TABLE, t   # noqa: E402


class SpanishTable(unittest.TestCase):
    def test_t_reads_the_spanish_column(self):
        self.assertEqual(t('onboarding.start', Lang('es')), 'Comenzar')
        self.assertEqual(t('switch2.badge', Lang('es')), 'Switch 2')
        self.assertEqual(t('dep.install.begin', Lang('es'), 'zstd'), 'Instalando zstd…')
        self.assertIn('Switch 2', TABLE['switch2.help']['es'])


if __name__ == '__main__':
    unittest.main()
