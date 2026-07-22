import importlib.util
import sys
import types
import unittest
from pathlib import Path


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


class SwiftArmTrackingSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (
            ROOT / "RobotVoiceCommandApp" / "RobotClient.swift"
        ).read_text()

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
