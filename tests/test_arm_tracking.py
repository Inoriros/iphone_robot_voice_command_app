import asyncio
import importlib.util
import json
import sys
import types
import unittest
from functools import lru_cache
from pathlib import Path
from unittest.mock import AsyncMock, call, patch


ROOT = Path(__file__).resolve().parents[1]


@lru_cache(maxsize=1)
def load_bridge_module():
    fastapi = types.ModuleType("fastapi")

    class FastAPI:
        def __init__(self, *args, **kwargs):
            self.routes = []

        def _route(self, path, *args, **kwargs):
            def register(function):
                self.routes.append(types.SimpleNamespace(path=path))
                return function

            return register

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

    def test_move_to_front_push_uses_compatible_arm_action_payload(self):
        self.assertEqual(
            self.bridge.ARM_ACTION_COMMANDS["ARM_FRONT_PUSH"],
            {
                "action_name": "move_to_frontPush",
                "start_pos": [0.0, 0.0, 0.0],
                "target_pos": [0.0, 0.0, 0.0],
            },
        )

    def test_push_actions_use_exact_minimal_payloads(self):
        self.assertEqual(
            self.bridge.ARM_ACTION_COMMANDS["ARM_EXECUTE_FRONT_PUSH"],
            {"action_name": "frontPush"},
        )
        self.assertEqual(
            self.bridge.ARM_ACTION_COMMANDS["ARM_BUTTON_PUSH"],
            {"action_name": "buttonPush"},
        )


class BridgeRosbagControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bridge = load_bridge_module()

    def test_bridge_test_module_is_reused_between_test_classes(self):
        self.assertIs(self.bridge, load_bridge_module())

    def test_rosbag_services_match_host_manager(self):
        self.assertEqual(
            self.bridge.ROSBAG_SERVICES,
            {
                "start": "/sair/rosbag/start",
                "stop": "/sair/rosbag/stop",
                "delete_latest": "/sair/rosbag/delete_latest",
                "status": "/sair/rosbag/get_status",
            },
        )
        self.assertEqual(
            self.bridge.ROSBAG_STATUS_TOPIC,
            "/sair/rosbag/status",
        )

    def test_rosbag_status_topic_uses_dedicated_websocket_event(self):
        payload = json.loads(
            self.bridge.RobotBridgeNode._status_payload(
                self.bridge.ROSBAG_STATUS_TOPIC,
                '{"recording":true,"state":"recording"}',
            )
        )
        self.assertEqual(payload["type"], "rosbag_status")
        self.assertTrue(payload["data"]["recording"])

    def test_rosbag_trigger_returns_host_manager_message(self):
        response = types.SimpleNamespace(success=True, message="Recording started")
        future = types.SimpleNamespace(
            done=lambda: True,
            result=lambda: response,
        )
        client = types.SimpleNamespace(
            service_is_ready=lambda: True,
            call_async=lambda request: future,
        )
        node = types.SimpleNamespace(rosbag_client=lambda action: client)
        trigger = types.SimpleNamespace(Request=object)

        with (
            patch.object(self.bridge, "ros_node", node),
            patch.object(self.bridge, "Trigger", trigger),
        ):
            message = asyncio.run(self.bridge.call_rosbag_trigger("start"))

        self.assertEqual(message, "Recording started")

    def test_rosbag_trigger_preserves_manager_rejection(self):
        response = types.SimpleNamespace(
            success=False,
            message="No rosbag recording is active",
        )
        future = types.SimpleNamespace(
            done=lambda: True,
            result=lambda: response,
        )
        client = types.SimpleNamespace(
            service_is_ready=lambda: True,
            call_async=lambda request: future,
        )
        node = types.SimpleNamespace(rosbag_client=lambda action: client)
        trigger = types.SimpleNamespace(Request=object)

        with (
            patch.object(self.bridge, "ros_node", node),
            patch.object(self.bridge, "Trigger", trigger),
        ):
            with self.assertRaisesRegex(
                self.bridge.RosbagServiceRejected,
                "No rosbag recording is active",
            ):
                asyncio.run(self.bridge.call_rosbag_trigger("stop"))


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
        self.assertEqual(
            run_tmux.await_args_list,
            [
                call(
                    "new-session",
                    "-d",
                    "-s",
                    self.bridge.PLATFORM_TMUX_SESSION,
                    "-n",
                    "platform",
                    "-c",
                    self.bridge.PLATFORM_DIRECTORY,
                    self.bridge.platform_start_shell_command(),
                ),
                call(
                    "new-window",
                    "-t",
                    f"{self.bridge.PLATFORM_TMUX_SESSION}:",
                    "-n",
                    "nav",
                    "-c",
                    self.bridge.NAV_DIRECTORY,
                    self.bridge.nav_start_shell_command(),
                ),
            ],
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

    def test_nav_start_failure_removes_partial_platform_session(self):
        run_tmux = AsyncMock(
            side_effect=[
                (0, "", ""),
                (1, "", "navigation failed"),
                (0, "", ""),
            ]
        )
        with (
            patch.object(
                self.bridge,
                "platform_tmux_session_exists",
                AsyncMock(return_value=False),
            ),
            patch.object(self.bridge, "run_tmux_command", run_tmux),
            patch.object(self.bridge, "validate_platform_start_configuration"),
        ):
            with self.assertRaisesRegex(RuntimeError, "navigation failed"):
                asyncio.run(self.bridge.start_platform_session())

        self.assertEqual(
            run_tmux.await_args_list[-1],
            call(
                "kill-session",
                "-t",
                self.bridge.PLATFORM_TMUX_SESSION,
            ),
        )

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
        self.assertEqual(
            run_tmux.await_args_list,
            [
                call(
                    "send-keys",
                    "-t",
                    f"{self.bridge.PLATFORM_TMUX_SESSION}:nav",
                    "C-c",
                ),
                call(
                    "send-keys",
                    "-t",
                    f"{self.bridge.PLATFORM_TMUX_SESSION}:platform",
                    "C-c",
                ),
            ],
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
                    f"{self.bridge.PLATFORM_TMUX_SESSION}:nav",
                    "C-c",
                ),
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

    def test_nav_shell_command_activates_sair_stack_and_runs_script(self):
        command = self.bridge.nav_start_shell_command()

        self.assertIn("/bin/bash -lc", command)
        self.assertIn("conda activate", command)
        self.assertIn(self.bridge.PLATFORM_CONDA_ENV, command)
        self.assertIn(self.bridge.NAV_START_SCRIPT, command)
        self.assertIn("export LOG_DIR=", command)
        self.assertIn(self.bridge.NAV_LOG_DIRECTORY, command)


class BridgeOdometryControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bridge = load_bridge_module()

    def test_authenticated_odometry_routes_are_registered(self):
        route_paths = {route.path for route in self.bridge.app.routes}
        self.assertIn("/odometry/start", route_paths)
        self.assertIn("/odometry/stop", route_paths)

    def test_start_uses_dedicated_odometry_tmux_session(self):
        session_exists = AsyncMock(side_effect=[False, True])
        run_tmux = AsyncMock(return_value=(0, "", ""))
        with (
            patch.object(self.bridge, "odometry_tmux_session_exists", session_exists),
            patch.object(self.bridge, "run_tmux_command", run_tmux),
            patch.object(self.bridge.asyncio, "sleep", AsyncMock()),
            patch.object(
                self.bridge,
                "validate_odometry_start_configuration",
            ) as validate_configuration,
        ):
            started = asyncio.run(self.bridge.start_odometry_session())

        self.assertTrue(started)
        validate_configuration.assert_called_once_with()
        run_tmux.assert_awaited_once_with(
            "new-session",
            "-d",
            "-s",
            self.bridge.ODOMETRY_TMUX_SESSION,
            "-n",
            self.bridge.ODOMETRY_TMUX_WINDOW,
            "-c",
            self.bridge.ODOMETRY_DIRECTORY,
            self.bridge.odometry_start_shell_command(),
        )

    def test_start_does_not_duplicate_existing_odometry_session(self):
        run_tmux = AsyncMock()
        with (
            patch.object(
                self.bridge,
                "odometry_tmux_session_exists",
                AsyncMock(return_value=True),
            ),
            patch.object(self.bridge, "run_tmux_command", run_tmux),
        ):
            started = asyncio.run(self.bridge.start_odometry_session())

        self.assertFalse(started)
        run_tmux.assert_not_awaited()

    def test_stop_interrupts_only_odometry_window(self):
        session_exists = AsyncMock(side_effect=[True, False])
        run_tmux = AsyncMock(return_value=(0, "", ""))
        with (
            patch.object(self.bridge, "odometry_tmux_session_exists", session_exists),
            patch.object(self.bridge, "run_tmux_command", run_tmux),
        ):
            result = asyncio.run(self.bridge.stop_odometry_session())

        self.assertEqual(result, (True, False))
        run_tmux.assert_awaited_once_with(
            "send-keys",
            "-t",
            f"{self.bridge.ODOMETRY_TMUX_SESSION}:{self.bridge.ODOMETRY_TMUX_WINDOW}",
            "C-c",
        )

    def test_forced_stop_kills_only_odometry_session(self):
        run_tmux = AsyncMock(return_value=(0, "", ""))
        with (
            patch.object(
                self.bridge,
                "odometry_tmux_session_exists",
                AsyncMock(return_value=True),
            ),
            patch.object(self.bridge, "run_tmux_command", run_tmux),
            patch.object(self.bridge, "ODOMETRY_STOP_TIMEOUT_SECONDS", 0.0),
        ):
            result = asyncio.run(self.bridge.stop_odometry_session())

        self.assertEqual(result, (True, True))
        self.assertEqual(
            run_tmux.await_args_list[-1],
            call("kill-session", "-t", self.bridge.ODOMETRY_TMUX_SESSION),
        )

    def test_odometry_shell_command_matches_requested_launch(self):
        command = self.bridge.odometry_start_shell_command()

        self.assertIn("/bin/bash -lc", command)
        self.assertIn(self.bridge.ODOMETRY_SETUP_SCRIPT, command)
        self.assertIn("exec ros2 launch super_lio hesai.py rviz:=false", command)


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
        self.assertIn("SAIR Platform + Navigation", self.content_source)
        self.assertIn('.alert("Start SAIR platform and navigation?"', self.content_source)
        self.assertIn('.alert("Stop SAIR platform and navigation?"', self.content_source)

    def test_odometry_buttons_use_authenticated_dedicated_routes(self):
        self.assertIn('odometryStartPath = "/odometry/start"', self.config_source)
        self.assertIn('odometryStopPath = "/odometry/stop"', self.config_source)
        self.assertIn("OdometryControlRequest", self.models_source)
        self.assertIn("OdometryControlResponse", self.models_source)
        self.assertIn("func startOdometry", self.source)
        self.assertIn("func stopOdometry", self.source)
        self.assertIn('Label("Start Odometry"', self.content_source)
        self.assertIn('Label("Stop Odometry"', self.content_source)
        self.assertIn("odometrySection", self.content_source)
        self.assertIn(
            'exec ros2 launch super_lio hesai.py rviz:=false',
            (ROOT / "jetson_bridge" / "robot_bridge.py").read_text(),
        )

    def test_push_arm_buttons_use_exact_action_names(self):
        self.assertIn(
            'armMoveToFrontPushCommand = "ARM_FRONT_PUSH"',
            self.config_source,
        )
        self.assertIn(
            'armFrontPushCommand = "ARM_EXECUTE_FRONT_PUSH"',
            self.config_source,
        )
        self.assertIn(
            'armMoveToFrontPushCommand: "move_to_frontPush"',
            self.config_source,
        )
        self.assertIn('armFrontPushCommand: "frontPush"', self.config_source)
        self.assertIn(
            'armButtonPushCommand = "ARM_BUTTON_PUSH"',
            self.config_source,
        )
        self.assertIn('armButtonPushCommand: "buttonPush"', self.config_source)
        self.assertIn('Label("move to frontPush"', self.content_source)
        self.assertIn('Label("frontPush"', self.content_source)
        self.assertIn('Label("buttonPush"', self.content_source)
        self.assertIn(
            "sendFixedCommand(AppConfig.armMoveToFrontPushCommand)",
            self.content_source,
        )
        self.assertIn(
            "sendFixedCommand(AppConfig.armFrontPushCommand)",
            self.content_source,
        )
        self.assertIn(
            "sendFixedCommand(AppConfig.armButtonPushCommand)",
            self.content_source,
        )

        def grid_row_containing(marker: str) -> str:
            marker_index = self.content_source.index(marker)
            row_start = self.content_source.rfind("GridRow {", 0, marker_index)
            row_end = self.content_source.find(
                "\n                GridRow {",
                marker_index,
            )
            return self.content_source[row_start:row_end]

        self.assertIn(
            "AppConfig.armButtonPushCommand",
            grid_row_containing("AppConfig.armButtonCommand"),
        )
        self.assertIn(
            "AppConfig.armFrontPushCommand",
            grid_row_containing("AppConfig.armMoveToFrontPushCommand"),
        )

    def test_rosbag_buttons_use_authenticated_bridge_routes(self):
        self.assertIn('rosbagStartPath = "/rosbag/start"', self.config_source)
        self.assertIn('rosbagStopPath = "/rosbag/stop"', self.config_source)
        self.assertIn(
            'rosbagDeleteLatestPath = "/rosbag/delete_latest"',
            self.config_source,
        )
        self.assertIn("RosbagControlRequest", self.models_source)
        self.assertIn('Label("Start Recording"', self.content_source)
        self.assertIn('Label("Stop Recording"', self.content_source)
        self.assertIn('Label("Delete Latest Recording"', self.content_source)
        self.assertIn('"Delete latest rosbag?"', self.content_source)
        self.assertIn("robot.refreshRosbagStatus", self.content_source)
        self.assertIn('case "rosbag_status"', self.source)
        self.assertIn("struct RosbagStatus", self.models_source)
        self.assertIn("response.decodedStatus?.displayText", self.source)

    def test_secondary_controls_are_collapsed_and_arm_follows_height(self):
        self.assertIn(
            "@State private var showingSpotBaseFunctions = false",
            self.content_source,
        )
        self.assertIn(
            "@State private var showingTaskFunctions = false",
            self.content_source,
        )
        self.assertIn(
            "@State private var showingBodyRelativeWaypoint = false",
            self.content_source,
        )

        spot_base = self.content_source.split(
            "private var spotBaseFunctionsSection",
            1,
        )[1].split("private var taskFunctionsSection", 1)[0]
        for section in ("batterySection", "platformSection", "odometrySection", "rosbagSection"):
            self.assertIn(section, spot_base)

        task_functions = self.content_source.split(
            "private var taskFunctionsSection",
            1,
        )[1].split("private var platformSection", 1)[0]
        for section in (
            "statusSection",
            "commandSection",
            "taskPlanSection",
            "subtaskProofSection",
            "stopControlsSection",
        ):
            self.assertIn(section, task_functions)

        phone_controls = self.content_source.split(
            "private var phoneControlSection",
            1,
        )[1].split("private var controlSourceController", 1)[0]
        self.assertLess(
            phone_controls.index("standingHeightController"),
            phone_controls.index("armControlsSection"),
        )
        self.assertLess(
            phone_controls.index("armControlsSection"),
            phone_controls.index("driveJoystickController"),
        )
        self.assertLess(
            phone_controls.index("driveJoystickController"),
            phone_controls.index("directMovementController"),
        )
        self.assertLess(
            phone_controls.index("directMovementController"),
            phone_controls.index("rotationController"),
        )
        self.assertIn("waypointDisclosureController", phone_controls)

    def test_direct_movement_buttons_target_point_three_meters_per_second(self):
        self.assertIn(
            "directMovementSpeedMetersPerSecond = 0.3",
            self.config_source,
        )
        self.assertIn("directMovementForwardInput = 0.6", self.config_source)
        self.assertIn("directMovementStrafeInput = 0.75", self.config_source)
        self.assertIn(
            "return (AppConfig.directMovementForwardInput, 0, 0)",
            self.content_source,
        )
        self.assertIn(
            "return (0, AppConfig.directMovementStrafeInput, 0)",
            self.content_source,
        )
        self.assertIn("move at 0.3 m/s", self.content_source)

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
