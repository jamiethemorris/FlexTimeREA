"""Build configuration checks; no framework is executed by these tests."""
import os
from pathlib import Path
import subprocess
import sys
import unittest


class BuildConfiguration(unittest.TestCase):
    def test_logic_location_can_be_configured_without_loading_framework(self):
        root = Path(__file__).resolve().parent
        selected = root / 'runtime' / 'synthetic-install' / 'Logic Pro.app'
        env = {**os.environ, 'FLEX_LOGIC_APP': str(selected)}
        command = [sys.executable, '-c',
                   'import build; print(build.MADSP)']
        result = subprocess.run(command, cwd=root, env=env, text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(selected / 'Contents' /
                         'Frameworks' / 'MADSP.framework' / 'Versions' / 'A' / 'MADSP'))
        self.assertFalse(selected.exists())


if __name__ == '__main__':
    unittest.main()
