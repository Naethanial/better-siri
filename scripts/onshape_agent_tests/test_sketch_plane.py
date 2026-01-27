import unittest

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from scripts.onshape_agent_tests._bootstrap import ensure_onshape_agent_on_path


class SketchPlaneTests(unittest.TestCase):
    def _mod(self):
        # Import lazily to avoid module-level side-effects when running discovery.
        import importlib

        ensure_onshape_agent_on_path()

        return importlib.import_module("onshape_mcp_server")

    def test_query_string_front_unescaped(self):
        m = self._mod()
        qs = m._sketch_plane_query_string("Front")
        self.assertEqual(qs, 'query=qCreatedBy(makeId("Front"), EntityType.FACE);')
        self.assertNotIn('\\\\\"', qs)

    def test_plane_aliases(self):
        m = self._mod()
        self.assertEqual(m._normalize_plane_id("xy"), "Top")
        self.assertEqual(m._normalize_plane_id("XZ"), "Front")
        self.assertEqual(m._normalize_plane_id("yZ"), "Right")

    def test_plane_case_insensitive(self):
        m = self._mod()
        self.assertEqual(m._normalize_plane_id("front"), "Front")
        self.assertEqual(m._normalize_plane_id("TOP"), "Top")
        self.assertEqual(m._normalize_plane_id("Right"), "Right")

    def test_passthrough_query(self):
        m = self._mod()
        qs = "query=qNthElement(qEverything(EntityType.FACE), 0);"
        self.assertEqual(m._sketch_plane_query_string(qs), qs)


if __name__ == "__main__":
    unittest.main()
