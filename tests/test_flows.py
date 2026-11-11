import asyncio
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
import walkingpad_app as app


def controller():
    game = app.GameMode.__new__(app.GameMode)
    game.pad = app.Pad()
    game.pad.log = Mock()
    game.pad.state["connection"] = "connected"
    game.keys = Mock()
    game.s = dict(app.DEFAULTS)
    game.link = False
    game.manual = False
    game.suppressed = False
    game.idle_since = None
    game.link_lost_since = None
    game.publish = Mock()
    return game


class FlowTests(unittest.TestCase):
    def test_refresh_settings_does_not_disable_unknown_child_lock(self):
        game = controller()
        game.pad.read_prefs()
        self.assertTrue(game.pad.queue.empty())

    def test_stop_requires_movement_release_before_restart(self):
        game = controller()
        game.pad.belt_on = True
        game.desired_speed = Mock(return_value=(3.0, "W held"))
        game.user_stop()
        game.follow_step()
        self.assertFalse(game.pad.belt_on)
        game.desired_speed.return_value = (0.0, "released")
        game.follow_step()
        game.desired_speed.return_value = (3.0, "new movement")
        game.follow_step()
        self.assertTrue(game.pad.belt_on)

    def test_remote_stop_also_latches_generic_input(self):
        game = controller()
        game.on_external_stop()
        game.desired_speed = Mock(return_value=(3.0, "stick held"))
        game.follow_step()
        self.assertFalse(game.pad.belt_on)

    def test_long_link_loss_keeps_addon_ownership(self):
        game = controller()
        game.link = True
        game.link_lost_since = app.time.time() - 121
        game.link_lost()
        self.assertTrue(game.link)

    def test_addon_pause_overrides_app_manual_start(self):
        game = controller()
        game.link, game.manual, game.last_moving = True, True, False
        game.pad.belt_on = True
        game.link_step(dict(moving=False, run=False, target=0))
        self.assertFalse(game.pad.belt_on)

    def test_drive_stop_does_not_rehold_keys_during_deceleration(self):
        game = controller()
        game.pad.state.update(speed=3, mode="auto")
        game.pad.last_status_time = app.time.time()
        game.sprinting = False
        game.admin_logged = 0
        game.user_stop()
        with patch.object(app, "game_window_ok", return_value=(True, "WoW")):
            game.drive_step(False)
        self.assertTrue(all(call.args[1] is False for call in game.keys.set.call_args_list))


class AsyncFlowTests(unittest.IsolatedAsyncioTestCase):
    async def test_stop_cancels_start_already_waiting_for_command_gap(self):
        game = controller()
        pad = game.pad
        pad.client = Mock(is_connected=True)
        sent = []
        async def write(kind, payload):
            sent.append(payload)
            if payload == app.cmd_mode(app.MODE_STANDBY):
                pad.client.is_connected = False
        pad._write = write
        pad.start(3)
        # First mode command goes out immediately; Stop arrives while Start
        # is already dequeued and waiting for the command gap.
        stopped = False
        async def sleep(_):
            nonlocal stopped
            if not stopped:
                stopped = True
                pad.stop()
        with patch.object(app.asyncio, "sleep", side_effect=sleep):
            await pad.worker()
        self.assertNotIn(app.cmd_start(), sent)
        self.assertIn(app.cmd_speed(0), sent)

    async def test_shutdown_prevents_game_tick_restarting_belt(self):
        game = controller()
        game.wow = Mock()
        game.pad.client = Mock()
        async def disconnect():
            pass
        game.pad.client.disconnect = disconnect
        async def sleep(_):
            game._tick(0)
            # Simulate the worker draining Stop commands.
            while not game.pad.queue.empty():
                game.pad.queue.get_nowait()
        with patch.object(app, "game", game), patch.object(app, "pad", game.pad), \
                patch.object(app.asyncio, "sleep", side_effect=sleep):
            await app.shutdown()
        game.wow.read.assert_not_called()
        self.assertFalse(game.pad.belt_on)


if __name__ == "__main__":
    unittest.main()
