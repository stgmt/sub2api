import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wait_sub2api_idle import update_active


class UpdateActiveTests(unittest.TestCase):
    def test_completed_request_is_not_resurrected_by_reordered_start(self) -> None:
        active: set[str] = set()
        completed: set[str] = set()
        request_id = "hr_1787119705_001983"

        update_active(active, completed, f"{request_id} http request completed")
        update_active(active, completed, f"{request_id} content_moderation.gateway_check_start")

        self.assertEqual(set(), active)
        self.assertEqual({request_id}, completed)

    def test_unfinished_request_remains_active(self) -> None:
        active: set[str] = set()
        completed: set[str] = set()
        update_active(active, completed, "hr_1787119708_001984 content_moderation.gateway_check_start")
        self.assertEqual({"hr_1787119708_001984"}, active)


if __name__ == "__main__":
    unittest.main()
