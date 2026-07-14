from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import threading
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field

try:
    import rclpy
    from rclpy.node import Node
    from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
    from sensor_msgs.msg import CompressedImage
    from std_msgs.msg import String

    ROS_AVAILABLE = True
except ImportError:
    rclpy = None
    Node = object
    DurabilityPolicy = None
    QoSProfile = None
    ReliabilityPolicy = None
    CompressedImage = None
    String = None
    ROS_AVAILABLE = False


logging.basicConfig(
    level=os.getenv("ROBOT_BRIDGE_LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("robot_bridge")


TASK_TOPIC = os.getenv("ROBOT_TASK_TOPIC", os.getenv("ROBOT_COMMAND_TOPIC", "/scenario"))
CONTROL_TOPIC = os.getenv("ROBOT_CONTROL_TOPIC", "/task_control")
CURRENT_SUBTASK_TOPIC = os.getenv("ROBOT_CURRENT_SUBTASK_TOPIC", "/current_subtask")
SUBTASK_STATUS_TOPIC = os.getenv("ROBOT_SUBTASK_STATUS_TOPIC", "/subtask_status")
TASK_PLANNING_TOPIC = os.getenv("ROBOT_TASK_PLANNING_TOPIC", "/task_planning")
PROMPT_EVIDENCE_TOPIC = os.getenv(
    "ROBOT_PROMPT_EVIDENCE_TOPIC",
    "/subtask_prompt_evidance",
)
IMAGE_EVIDENCE_TOPIC = os.getenv(
    "ROBOT_IMAGE_EVIDENCE_TOPIC",
    "/subtask_image_evidence",
)
SIM_CONTROL_TOPIC = os.getenv("ROBOT_SIM_CONTROL_TOPIC", "/sim_control")
LEGACY_STATUS_TOPIC = os.getenv("ROBOT_STATUS_TOPIC", "/task_status")
AUTH_TOKEN = os.getenv("ROBOT_BRIDGE_TOKEN", "2001")
ALLOW_NO_ROS = os.getenv("ROBOT_BRIDGE_ALLOW_NO_ROS", "false").lower() in {
    "1",
    "true",
    "yes",
}

CONTROL_COMMANDS = {
    "STOP_CURRENT_TASK",
    "STOP_CURRENT_SUBTASK",
    "PAUSE_CURRENT_SUBTASK",
    "RESUME_CURRENT_SUBTASK",
}


class CommandRequest(BaseModel):
    text: str = Field(..., min_length=1)
    token: str
    source: str = "iphone"


class CommandResponse(BaseModel):
    ok: bool
    published_topic: Optional[str] = None
    command_type: str = "task"
    text: Optional[str] = None


@dataclass
class BridgeState:
    latest_status_text: Optional[str] = None
    latest_command_text: Optional[str] = None
    loop: Optional[asyncio.AbstractEventLoop] = None
    latest_status_by_topic: Dict[str, str] = field(default_factory=dict)
    status_lock: threading.Lock = field(default_factory=threading.Lock, repr=False)


class WebSocketManager:
    def __init__(self) -> None:
        self._clients: Set[WebSocket] = set()
        self._lock = asyncio.Lock()

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self._lock:
            self._clients.add(websocket)
        logger.info("status websocket connected; clients=%d", len(self._clients))

    async def disconnect(self, websocket: WebSocket) -> None:
        async with self._lock:
            self._clients.discard(websocket)
        logger.info("status websocket disconnected; clients=%d", len(self._clients))

    async def broadcast_text(self, text: str) -> None:
        async with self._lock:
            clients = list(self._clients)

        stale: List[WebSocket] = []
        for websocket in clients:
            try:
                await websocket.send_text(text)
            except Exception as exc:
                logger.warning("dropping failed websocket client: %s", exc)
                stale.append(websocket)

        if stale:
            async with self._lock:
                for websocket in stale:
                    self._clients.discard(websocket)


class RobotBridgeNode(Node):  # type: ignore[misc]
    def __init__(self, state: BridgeState, sockets: WebSocketManager) -> None:
        super().__init__("iphone_robot_voice_command_bridge")
        self._state = state
        self._sockets = sockets
        transient_qos = QoSProfile(
            depth=10,
            durability=DurabilityPolicy.TRANSIENT_LOCAL,
            reliability=ReliabilityPolicy.RELIABLE,
        )
        self._task_pub = self.create_publisher(String, TASK_TOPIC, 10)
        self._control_pub = self.create_publisher(String, CONTROL_TOPIC, 10)
        self._current_subtask_pub = self.create_publisher(
            String,
            CURRENT_SUBTASK_TOPIC,
            transient_qos,
        )

        for topic in dict.fromkeys(
            [
                SUBTASK_STATUS_TOPIC,
                SIM_CONTROL_TOPIC,
                LEGACY_STATUS_TOPIC,
            ]
        ):
            self.create_subscription(
                String,
                topic,
                lambda message, topic=topic: self._handle_status(topic, message),
                10,
            )
        for topic in dict.fromkeys(
            [
                CURRENT_SUBTASK_TOPIC,
                TASK_PLANNING_TOPIC,
                PROMPT_EVIDENCE_TOPIC,
            ]
        ):
            self.create_subscription(
                String,
                topic,
                lambda message, topic=topic: self._handle_status(topic, message),
                transient_qos,
            )
        self.create_subscription(
            CompressedImage,
            IMAGE_EVIDENCE_TOPIC,
            self._handle_image_evidence,
            transient_qos,
        )

        self.get_logger().info(
            "bridge ready: "
            f"tasks -> {TASK_TOPIC}, controls -> {CONTROL_TOPIC}, "
            f"status <- {CURRENT_SUBTASK_TOPIC}, {SUBTASK_STATUS_TOPIC}, "
            f"{TASK_PLANNING_TOPIC}, {PROMPT_EVIDENCE_TOPIC}, "
            f"{IMAGE_EVIDENCE_TOPIC}, {SIM_CONTROL_TOPIC}"
        )

    def publish_task(self, command_text: str, source: str) -> None:
        message = String()
        message.data = command_text
        self._task_pub.publish(message)
        self._state.latest_command_text = command_text
        self.get_logger().info(
            f"published iPhone task to {TASK_TOPIC} from {source}: {command_text}"
        )

    def publish_control(self, command_text: str, source: str) -> None:
        command_name = command_text.strip().upper()
        payload = {
            "command": command_name,
            "source": source,
            "timestamp": time.time(),
        }

        message = String()
        message.data = json.dumps(payload, separators=(",", ":"))
        self._control_pub.publish(message)
        self._state.latest_command_text = command_name

        # Immediate foreground-skill fallback for currently deployed nodes.
        # Exploration lifetime remains owned by the task planner and is not
        # changed by a task/subtask pause or stop.
        if command_name in {
            "STOP_CURRENT_TASK",
            "STOP_CURRENT_SUBTASK",
            "PAUSE_CURRENT_SUBTASK",
        }:
            self._current_subtask_pub.publish(self._control_as_subtask(command_name, source))

        self.get_logger().warning(
            f"published iPhone control to {CONTROL_TOPIC}: {command_name}"
        )

    @staticmethod
    def _control_as_subtask(command_name: str, source: str) -> Any:
        if command_name == "STOP_CURRENT_TASK":
            skill = "cancelled"
        elif command_name == "PAUSE_CURRENT_SUBTASK":
            skill = "paused"
        else:
            skill = "manual_stop_subtask"

        message = String()
        message.data = json.dumps(
            {
                "skill": skill,
                "instruction": f"{command_name} from {source}",
                "target": "",
                "source": source,
            },
            separators=(",", ":"),
        )
        return message

    def _handle_status(self, topic: str, message: Any) -> None:
        status_text = self._status_payload(topic, str(message.data))
        self._broadcast_event(topic, status_text)

    def _handle_image_evidence(self, message: Any) -> None:
        payload = {
            "type": "image_evidence",
            "topic": IMAGE_EVIDENCE_TOPIC,
            "timestamp": time.time(),
            "data": {
                "format": str(message.format or "jpeg"),
                "base64": base64.b64encode(bytes(message.data)).decode("ascii"),
            },
        }
        self._broadcast_event(
            IMAGE_EVIDENCE_TOPIC,
            json.dumps(payload, separators=(",", ":")),
        )

    def _broadcast_event(self, topic: str, status_text: str) -> None:
        with self._state.status_lock:
            self._state.latest_status_text = status_text
            self._state.latest_status_by_topic[topic] = status_text

        if self._state.loop is None:
            self.get_logger().warning("web event loop not ready; dropping status update")
            return

        asyncio.run_coroutine_threadsafe(
            self._sockets.broadcast_text(status_text),
            self._state.loop,
        )

    @staticmethod
    def _status_payload(topic: str, text: str) -> str:
        payload: Dict[str, Any] = {
            "topic": topic,
            "timestamp": time.time(),
        }

        if topic == CURRENT_SUBTASK_TOPIC:
            payload["type"] = "current_subtask"
        elif topic == SUBTASK_STATUS_TOPIC:
            payload["type"] = "subtask_status"
        elif topic == TASK_PLANNING_TOPIC:
            payload["type"] = "task_plan"
        elif topic == PROMPT_EVIDENCE_TOPIC:
            payload["type"] = "prompt_evidence"
        elif topic == SIM_CONTROL_TOPIC:
            payload["type"] = "task_lifecycle"
        else:
            payload["type"] = "status"

        try:
            payload["data"] = json.loads(text)
        except json.JSONDecodeError:
            payload["data"] = text

        return json.dumps(payload, separators=(",", ":"))


state = BridgeState()
sockets = WebSocketManager()
ros_node: Optional[RobotBridgeNode] = None
ros_thread: Optional[threading.Thread] = None


def start_ros() -> None:
    global ros_node, ros_thread

    if not ROS_AVAILABLE:
        if ALLOW_NO_ROS:
            logger.warning("ROS 2 is unavailable; starting in no-ROS test mode")
            return
        raise RuntimeError(
            "ROS 2 Python packages are unavailable. Source ROS 2 first, or set "
            "ROBOT_BRIDGE_ALLOW_NO_ROS=true for network-only testing."
        )

    rclpy.init(args=None)
    ros_node = RobotBridgeNode(state, sockets)

    def spin() -> None:
        assert ros_node is not None
        try:
            rclpy.spin(ros_node)
        except Exception:
            logger.exception("ROS spin crashed")

    ros_thread = threading.Thread(target=spin, name="ros2-spin", daemon=True)
    ros_thread.start()


def stop_ros() -> None:
    global ros_node

    if not ROS_AVAILABLE or ros_node is None:
        return

    ros_node.destroy_node()
    rclpy.shutdown()
    ros_node = None


@asynccontextmanager
async def lifespan(_app: FastAPI):
    state.loop = asyncio.get_running_loop()
    start_ros()
    try:
        yield
    finally:
        stop_ros()

app = FastAPI(title="iPhone Robot Voice Command Bridge", lifespan=lifespan)


@app.get("/health")
async def health() -> Dict[str, Any]:
    return {
        "ok": True,
        "ros_available": ROS_AVAILABLE,
        "ros_enabled": ros_node is not None,
        "task_topic": TASK_TOPIC,
        "control_topic": CONTROL_TOPIC,
        "current_subtask_topic": CURRENT_SUBTASK_TOPIC,
        "subtask_status_topic": SUBTASK_STATUS_TOPIC,
        "task_planning_topic": TASK_PLANNING_TOPIC,
        "prompt_evidence_topic": PROMPT_EVIDENCE_TOPIC,
        "image_evidence_topic": IMAGE_EVIDENCE_TOPIC,
        "sim_control_topic": SIM_CONTROL_TOPIC,
    }


@app.post("/command", response_model=CommandResponse)
async def command(request: CommandRequest) -> CommandResponse:
    command_text = request.text.strip()

    if request.token != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")

    if not command_text:
        raise HTTPException(status_code=400, detail="Empty or invalid command")

    command_name = command_text.upper()
    is_control = command_name in CONTROL_COMMANDS

    if ros_node is None:
        if not ALLOW_NO_ROS:
            raise HTTPException(status_code=503, detail="ROS 2 bridge is not available")
        state.latest_command_text = command_text
        logger.info("accepted command in no-ROS test mode: %s", command_text)
        published_topic = None
        command_type = "control" if is_control else "task"
    else:
        if is_control:
            ros_node.publish_control(command_name, request.source)
            published_topic = CONTROL_TOPIC
            command_type = "control"
        else:
            ros_node.publish_task(command_text, request.source)
            published_topic = TASK_TOPIC
            command_type = "task"

    return CommandResponse(
        ok=True,
        published_topic=published_topic,
        command_type=command_type,
        text=command_name if is_control else command_text,
    )


@app.websocket("/status")
async def status_stream(websocket: WebSocket) -> None:
    await sockets.connect(websocket)

    try:
        with state.status_lock:
            status_by_topic = dict(state.latest_status_by_topic)
            latest_status_text = state.latest_status_text

        replay_order = (
            TASK_PLANNING_TOPIC,
            CURRENT_SUBTASK_TOPIC,
            SUBTASK_STATUS_TOPIC,
            SIM_CONTROL_TOPIC,
            LEGACY_STATUS_TOPIC,
            PROMPT_EVIDENCE_TOPIC,
            IMAGE_EVIDENCE_TOPIC,
        )
        status_snapshot = [
            status_by_topic.pop(topic)
            for topic in replay_order
            if topic in status_by_topic
        ]
        status_snapshot.extend(status_by_topic.values())

        if status_snapshot:
            for status_text in status_snapshot:
                await websocket.send_text(status_text)
        elif latest_status_text:
            await websocket.send_text(latest_status_text)
        else:
            await websocket.send_text(
                json.dumps(
                    {
                        "state": "connected",
                        "message": "Status stream connected. Waiting for robot status.",
                        "timestamp": time.time(),
                    },
                    separators=(",", ":"),
                )
            )

        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        await sockets.disconnect(websocket)
    except Exception as exc:
        logger.warning("status websocket closed with error: %s", exc)
        await sockets.disconnect(websocket)


@app.post("/mock_status")
async def mock_status(payload: Dict[str, Any]) -> Dict[str, bool]:
    if not ALLOW_NO_ROS:
        raise HTTPException(
            status_code=403,
            detail="mock_status is enabled only when ROBOT_BRIDGE_ALLOW_NO_ROS=true",
        )

    text = json.dumps(payload, separators=(",", ":"))
    with state.status_lock:
        state.latest_status_text = text
    await sockets.broadcast_text(text)
    return {"ok": True}


def main() -> None:
    import uvicorn

    host = os.getenv("ROBOT_BRIDGE_HOST", "0.0.0.0")
    port = int(os.getenv("ROBOT_BRIDGE_PORT", "8080"))

    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
