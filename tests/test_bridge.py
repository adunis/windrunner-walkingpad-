import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
import walkingpad_app as app


def frame(size=6, origin=(7, 4), request=(0x5A, 30, 0x83)):
    w, h = 120, 48
    buf = bytearray(w * h * 4)
    for n, rgb in enumerate(((0x12, 0x34, 0x56), (0xA5, 70, 0x85), request)):
        for y in range(origin[1], origin[1] + size):
            for x in range(origin[0] + n * size, origin[0] + (n + 1) * size):
                j = (y * w + x) * 4
                buf[j:j + 4] = bytes((*reversed(rgb), 255))
    return bytes(buf), w, h


class BridgeTests(unittest.TestCase):
    def test_scaled_squares_at_arbitrary_window_offsets(self):
        for size in (1, 2, 3, 4, 6, 9, 12):
            for origin in ((0, 0), (7, 4), (23, 17)):
                with self.subTest(size=size, origin=origin):
                    found = app.find_marker(*frame(size, origin))
                    cx, cy = origin[0] + size // 2, origin[1] + size // 2
                    self.assertEqual(found, ((cx, cy), (cx + size, cy), (cx + size * 2, cy)))

    def test_missing_or_corrupted_request_is_not_manual_mode(self):
        for request in ((0, 0, 0), (0x5A, 255, 0x83), (0x5A, 30, 0xFF)):
            self.assertIsNone(app.find_marker(*frame(request=request)))
            self.assertIsNone(app.decode_request(*request))
        self.assertEqual(app.decode_request(0x5A, 30, 0x80)["app_mode"], False)

    def test_truncated_frame(self):
        self.assertIsNone(app.find_marker(b"\x56\x34\x12", 1, 1))

    def test_extended_session_and_combat_flags(self):
        for flags in (0x87, 0x8F):
            request = app.decode_request(0x5A, 10, flags)
            self.assertTrue(request["run"])
            self.assertTrue(request["session_active"])
            self.assertIsNotNone(app.find_marker(*frame(request=(0x5A, 10, flags))))
        for flags in (0x81, 0x89, 0x85, 0x8D):
            self.assertFalse(app.decode_request(0x5A, 0, flags)["run"])
        self.assertIsNone(app.decode_request(0x5A, 10, 0x8B))
        self.assertFalse(app.decode_request(0x5A, 0, 0x87)["run"])

    def test_cached_read_loss_and_relocation(self):
        bridge = app.WowBridge()
        def capture(rect=None):
            if rect is None:
                buf, w, h = frame()
                return -1920, -100, w, h, buf
            buf = bytearray(rect[2] * 4)
            for x, rgb in ((0, (0x12, 0x34, 0x56)), (6, (0xA5, 70, 0x85)),
                           (12, request[0])):
                buf[x * 4:x * 4 + 4] = bytes((*reversed(rgb), 255))
            return *rect, bytes(buf)
        request = [(0x5A, 30, 0x83)]
        bridge._capture = Mock(side_effect=capture)
        with patch.object(app, "IS_WINDOWS", True):
            self.assertTrue(bridge.read()["app_mode"])
            self.assertLess(bridge.pos[0][0], 0)
            request[0] = (0, 0, 0)
            for _ in range(4):
                self.assertIsNone(bridge.read())
            self.assertIsNone(bridge.pos)
            self.assertIsNone(bridge.last)
            request[0] = (0x5A, 30, 0x83)
            bridge.last_search = 0
            self.assertTrue(bridge.read()["app_mode"])

    def test_capture_failure_clears_stale_data(self):
        bridge = app.WowBridge()
        bridge.last = {"moving": True}
        bridge._capture = Mock(side_effect=OSError("capture failed"))
        with patch.object(app, "IS_WINDOWS", True):
            self.assertIsNone(bridge.read())
        self.assertIsNone(bridge.last)

    def test_link_loss_does_not_fall_back_to_keyboard(self):
        game = app.GameMode.__new__(app.GameMode)
        game.wow = Mock()
        game.wow.read.return_value = None
        game.s = {"direction": "follow"}
        game.link = True
        game.link_lost = Mock()
        game.follow_step = Mock()
        with patch.object(app, "IS_WINDOWS", True):
            game._tick(app.time.time())
        game.link_lost.assert_called_once()
        game.follow_step.assert_not_called()

    def test_one_tenth_speed_change_is_sent(self):
        game = app.GameMode.__new__(app.GameMode)
        game.pad = Mock(connected=True, belt_on=True, target_speed=4.0, hold_until=0)
        game.link, game.manual, game.suppressed = True, False, False
        game.link_lost_since, game.last_moving = None, True
        game.link_step(dict(moving=True, target=4.1, run=True, mounted=False,
                            taxi=False, vehicle=False, known=True, speed=7.0))
        game.pad.set_speed.assert_called_once_with(4.1, quiet=True)


if __name__ == "__main__":
    unittest.main()
