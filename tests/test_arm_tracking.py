import asyncio
import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, call, patch


ROOT = Path(__file__).resolve().parents[1]


def load_bridge_module():
    fastapi = types.ModuleType("fastapi")

    class FastAPI:
        def __init__(self, *args, **kwargs):
            pass

        def _route(self, *args, **kwargs):
            return lambda function: function

        get = _route
        post = _route
        websocket = _route

    class HTTPException(Exception):
        def __init__(self, status_code, detail):
            super().__init__(detail)
            self.status_code = status_code
            self.detail = detail

    fastapi.FastAPI = FastAPI
    fastapi.HTTPException = HTTPException
    fastapi.WebSocket = type("WebSocket", (), {})
    fastapi.WebSocketDisconnect = type("WebSocketDisconnect", (Exception,), {})

    pydantic = types.ModuleType("pydantic")
    pydantic.BaseModel = type("BaseModel", (), {})
    pydantic.Field = lambda default=..., **kwargs: default

    saved_modules = {
        name: sys.modules.get(name)
        for name in ("fastapi", "pydantic")
    }
    sys.modules["fastapi"] = fastapi
    sys.modules["pydantic"] = pydantic

    module_name = "robot_bridge_under_test"
    bridge_path = ROOT / "jetson_bridge" / "robot_bridge.py"
    spec = importlib.util.spec_from_file_location(module_name, bridge_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        for name, previous in saved_modules.items():
            if previous is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous


class BridgeArmHistoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bridge = load_bridge_module()

    def test_arm_history_is_bounded_and_ordered(self):
        state = self.bridge.BridgeState()
        extra_events = 5

        for index in range(self.bridge.ARM_STATUS_HISTORY_LIMIT + extra_events):
            self.bridge.remember_status_event(
                state,
                self.bridge.ARM_SKILL_STATUS_TOPIC,
                f"arm-{index}",
            )

        self.assertEqual(
            len(state.arm_status_history),
            self.bridge.ARM_STATUS_HISTORY_LIMIT,
        )
        self.assertEqual(state.arm_status_history[0], f"arm-{extra_events}")
        self.assertEqual(
            state.arm_status_history[-1],
            f"arm-{self.bridge.ARM_STATUS_HISTORY_LIMIT + extra_events - 1}",
        )

    def test_snapshot_replays_arm_history_without_duplicate_latest_event(self):
        latest_by_topic = {
            self.bridge.CONTROL_STATE_TOPIC: "control",
            self.bridge.ARM_SKILL_STATUS_TOPIC: "arm-latest",
            self.bridge.CURRENT_SUBTASK_TOPIC: "subtask",
        }

        snapshot = self.bridge.build_status_snapshot(
            latest_by_topic,
            ["arm-accepted", "arm-running", "arm-latest"],
        )

        self.assertEqual(
            snapshot,
            ["control", "arm-accepted", "arm-running", "arm-latest", "subtask"],
        )

    def test_observe_higher_uses_exact_arm_action_payload(self):
        self.assertEqual(
            self.bridge.ARM_ACTION_COMMANDS["ARM_OBSERVE_HIGHER"],
            {
                "action_name": "move_to_high_button",
                "start_pos": [0.0, 0.0, 0.0],
                "target_pos": [0.0, 0.0, 0.0],
            },
        )


class BridgePlatformControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bridge = load_bridge_module()

    def test_start_uses_dedicated_tmux_session_and_working_directory(self):
        session_exists = AsyncMock(side_effect=[False, True])
        run_tmux = AsyncMock(return_value=(0, "", ""))

        with (
            patch.object(self.bridge, "platform_tmux_session_exists", session_exists),
            patch.object(self.bridge, "run_tmux_command", run_tmux),
            patch.object(self.bridge.asyncio, "sleep", AsyncMock()),
            patch.object(
                self.bridge,
                "validate_platform_start_configuration",
            ) as validate_configuration,
        ):
            started = asyncio.run(self.bridge.start_platform_session())

        self.assertTrue(started)
        validate_configuration.assert_called_once_with()
        run_tmux.assert_awaited_once_with(
            "new-session",
            "-d",
            "-s",
            self.bridge.PLATFORM_TMUX_SESSION,
            "-n",
            "platform",
            "-c",
            self.bridge.PLATFORM_DIRECTORY,
            self.bridge.platform_start_shell_command(),
        )

    def test_start_does_not_duplicate_existing_session(self):
        run_tmux = AsyncMock()
        with (
            patch.object(
                self.bridge,
                "platform_tmux_session_exists",
                AsyncMock(return_value=True),
            ),
            patch.object(self.bridge, "run_tmux_command", run_tmux),
        ):
            started = asyncio.run(self.bridge.start_platform_session())

        self.assertFalse(started)
        run_tmux.assert_not_awaited()

    def test_invalid_session_name_is_rejected_before_tmux_runs(self):
        run_tmux = AsyncMock()
        with (
            patch.object(self.bridge, "PLATFORM_TMUX_SESSION", "other:0"),
            patch.object(self.bridge, "run_tmux_command", run_tmux),
        ):
            with self.assertRaisesRegex(RuntimeError, "session name is invalid"):
                asyncio.run(self.bridge.platform_tmux_session_exists())

        run_tmux.assert_not_awaited()

    def test_stop_sends_ctrl_c_and_avoids_forced_kill_when_session_exits(self):
        session_exists = AsyncMock(side_effect=[True, False])
        run_tmux = AsyncMock(return_value=(0, "", ""))
        with (
            patch.object(self.bridge, "platform_tmux_session_exists", session_exists),
            patch.object(self.bridge, "run_tmux_command", run_tmux),
        ):
            result = asyncio.run(self.bridge.stop_platform_session())

        self.assertEqual(result, (True, False))
        run_tmux.assert_awaited_once_with(
            "send-keys",
            "-t",
            f"{self.bridge.PLATFORM_TMUX_SESSION}:platform",
            "C-c",
        )

    def test_stop_forced_cleanup_targets_only_platform_session(self):
        run_tmux = AsyncMock(return_value=(0, "", ""))
        with (
            patch.object(
                self.bridge,
                "platform_tmux_session_exists",
                AsyncMock(return_value=True),
            ),
            patch.object(self.bridge, "run_tmux_command", run_tmux),
            patch.object(self.bridge, "PLATFORM_STOP_TIMEOUT_SECONDS", 0.0),
        ):
            result = asyncio.run(self.bridge.stop_platform_session())

        self.assertEqual(result, (True, True))
        self.assertEqual(
            run_tmux.await_args_list,
            [
                call(
                    "send-keys",
                    "-t",
                    f"{self.bridge.PLATFORM_TMUX_SESSION}:platform",
                    "C-c",
                ),
                call("kill-session", "-t", self.bridge.PLATFORM_TMUX_SESSION),
            ],
        )

    def test_start_shell_command_activates_sair_stack_and_runs_script(self):
        command = self.bridge.platform_start_shell_command()

        self.assertIn("/bin/bash -lc", command)
        self.assertIn("conda activate", command)
        self.assertIn(self.bridge.PLATFORM_CONDA_ENV, command)
        self.assertIn(self.bridge.PLATFORM_START_SCRIPT, command)


class SwiftArmTrackingSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (
            ROOT / "RobotVoiceCommandApp" / "RobotClient.swift"
        ).read_text()
        cls.config_source = (
            ROOT / "RobotVoiceCommandApp" / "AppConfig.swift"
        ).read_text()
        cls.content_source = (
            ROOT / "RobotVoiceCommandApp" / "ContentView.swift"
        ).read_text()
        cls.models_source = (
            ROOT / "RobotVoiceCommandApp" / "RobotModels.swift"
        ).read_text()

    def test_platform_buttons_use_authenticated_dedicated_routes(self):
        self.assertIn('platformStartPath = "/platform/start"', self.config_source)
        self.assertIn('platformStopPath = "/platform/stop"', self.config_source)
        self.assertIn("PlatformControlRequest", self.models_source)
        self.assertIn("func startPlatform", self.source)
        self.assertIn("func stopPlatform", self.source)
        self.assertIn('Label("Start Platform"', self.content_source)
        self.assertIn('Label("Stop Platform"', self.content_source)
        self.assertIn('.alert("Start SAIR_platform?"', self.content_source)
        self.assertIn('.alert("Stop SAIR_platform?"', self.content_source)

    def test_arm_response_callback_checks_generation_before_handling_result(self):
        callback = self.source.split(
            "URLSession.shared.dataTask(with: request)",
            1,
        )[1].split("}.resume()", 1)[0]

        self.assertLess(
            callback.index("self.armCommandGeneration != armRequestGeneration"),
            callback.index("if let error"),
        )
        self.assertIn(
            "guard isArmCommandActive, armCommandGeneration == generation",
            self.source,
        )

    def test_status_timeout_keeps_arm_controls_locked(self):
        timeout_body = self.source.split(
            "private func scheduleArmTimeout",
            1,
        )[1].split("func connectStatusWebSocket", 1)[0]

        self.assertNotIn("isArmCommandActive = false", timeout_body)
        self.assertIn("self.armCommandTimedOut = true", timeout_body)


if __name__ == "__main__":
    unittest.main()
