import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
V2_ROOT = ROOT / "Resources" / "V2Knowledge"
sys.path.insert(0, str(V2_ROOT))

from retrieve_top12 import retrieve


class RetrieveTop12Tests(unittest.TestCase):
    def retrieve(self, history):
        knowledge_base = (
            ROOT
            / "Resources"
            / "KnowledgeBase"
            / "Grozziie-China-KB-2026-08-24.zip"
        )
        self.assertTrue(knowledge_base.is_file())
        with tempfile.TemporaryDirectory() as directory:
            return retrieve(
                {
                    "knowledge_base_path": str(knowledge_base),
                    "history_jsonl": history,
                    "cache_directory": directory,
                    "seed_cache_directory": str(V2_ROOT / "cache"),
                }
            )

    def test_video_request_returns_compact_original_evidence_with_tmall_url(self):
        result = self.retrieve(
            "\n".join(
                [
                    '{"sender":"customer","v":"M880班次有重叠"}',
                    '{"sender":"service","v":"建议手动打卡"}',
                    '{"sender":"customer","v":"视频发给我"}',
                ]
            )
        )

        self.assertEqual(result["version"], "v2-top12")
        self.assertLess(len(result["context"]), 45_000)
        self.assertIn("http://cloud.video.taobao.com", result["context"])
        self.assertTrue(
            "491279010943.mp4" in result["context"]
            or "491279178909.mp4" in result["context"]
        )

    def test_third_party_card_position_video_includes_exact_link(self):
        result = self.retrieve(
            '{"sender":"customer","v":"M880第三方卡可以打印，但打印位置偏了，'
            '请发第三方卡打印位置微调视频。"}'
        )

        self.assertLess(len(result["context"]), 45_000)
        self.assertIn("491279178909.mp4", result["context"])


if __name__ == "__main__":
    unittest.main()
