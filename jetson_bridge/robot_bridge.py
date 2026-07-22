from __future__ import annotations

import asyncio
import base64
import json
import logging
import math
import os
import re
import threading
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any, Dict, List, Literal, Optional, Set

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field

try:
    import rclpy
    from rclpy.node import Node
    from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
    from geometry_msgs.msg import PoseStamped, Twist
    from sensor_msgs.msg import CompressedImage
    from std_msgs.msg import Float32, String

    ROS_AVAILABLE = True
except ImportError:
    rclpy = None
    Node = object
    DurabilityPolicy = None
    QoSProfile = None
    ReliabilityPolicy = None
    PoseStamped = None
    Twist = None
    CompressedImage = None
    Float32 = None
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
CURRENT_ARM_SUBTASK_TOPIC = os.getenv("ROBOT_CURRENT_ARM_SUBTASK_TOPIC", "/current_arm_subtask")
HUMAN_WAYPOINT_TOPIC = os.getenv("ROBOT_HUMAN_WAYPOINT_TOPIC", "/human_way_point")
HUMAN_VELOCITY_TOPIC = os.getenv(
    "ROBOT_HUMAN_VELOCITY_TOPIC",
    "/human_velocity_command",
)
HUMAN_BODY_HEIGHT_TOPIC = os.getenv(
    "ROBOT_HUMAN_BODY_HEIGHT_TOPIC",
    "/human_body_height",
)
APP_ROBOT_MODE_TOPIC = os.getenv("ROBOT_APP_MODE_TOPIC", "/spot/app_robot_mode")
APP_CONTROL_SOURCE_TOPIC = os.getenv("ROBOT_APP_SOURCE_TOPIC", "/spot/app_control_source")
CONTROL_STATE_TOPIC = os.getenv("ROBOT_CONTROL_STATE_TOPIC", "/spot/control_state")
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
BATTERY_CHECK_SCRIPT = os.getenv(
    "SPOT_BATTERY_CHECK_SCRIPT",
    "/root/spot_battery_check.sh",
)
BATTERY_CHECK_TIMEOUT_SECONDS = float(
    os.getenv("SPOT_BATTERY_CHECK_TIMEOUT_SECONDS", "20")
)
MANUAL_CONTROL_AXIS_LIMIT_METERS = float(
    os.getenv("ROBOT_MANUAL_CONTROL_AXIS_LIMIT_METERS", "6")
)
BODY_HEIGHT_MIN_METERS = float(
    os.getenv("ROBOT_BODY_HEIGHT_MIN_METERS", "-0.20")
)
BODY_HEIGHT_MAX_METERS = float(
    os.getenv("ROBOT_BODY_HEIGHT_MAX_METERS", "0.20")
)
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

ARM_ACTION_COMMANDS = {
    "ARM_RELAX": {
        "action_name": "move_to_relax",
        "start_pos": [0.0, 0.0, 0.0],
        "target_pos": [0.0, 0.0, 0.0],
    },
    "ARM_BUTTON": {
        "action_name": "move_to_button",
        "start_pos": [0.0, 0.0, 0.0],
        "target_pos": [0.0, 0.0, 0.0],
    },
    "ARM_PRESS": {
        "action_name": "move_to_press",
        "start_pos": [0.0, 0.0, 0.0],
        "target_pos": [0.0, 0.0, 0.0],
    },
    "ARM_GRASP_BOTTLE": {
        "action_name": "grasp_water_bottle",
        "start_pos": [0.0, 0.0, 0.0],
        "target_pos": [0.0, 0.0, 0.0],
    },
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


class BatteryRequest(BaseModel):
    token: str
    source: str = "iphone"


class BatteryResponse(BaseModel):
    ok: bool
    percentage: float
    message: str


class ManualControlRequest(BaseModel):
    x: float = Field(
        ...,
        ge=-MANUAL_CONTROL_AXIS_LIMIT_METERS,
        le=MANUAL_CONTROL_AXIS_LIMIT_METERS,
    )
    y: float = Field(
        ...,
        ge=-MANUAL_CONTROL_AXIS_LIMIT_METERS,
        le=MANUAL_CONTROL_AXIS_LIMIT_METERS,
    )
    yaw: float = Field(..., ge=-math.pi, le=math.pi)
    token: str
    source: str = "iphone"


class ManualControlResponse(BaseModel):
    ok: bool
    published_topic: Optional[str] = None
    message: str


class ManualVelocityRequest(BaseModel):
    forward: float = Field(..., ge=-1.0, le=1.0)
    strafe: float = Field(..., ge=-1.0, le=1.0)
    yaw: float = Field(..., ge=-1.0, le=1.0)
    token: str
    source: str = "iphone"


class ManualVelocityResponse(BaseModel):
    ok: bool
    published_topic: Optional[str] = None
    message: str


class BodyHeightRequest(BaseModel):
    height: float = Field(
        ...,
        ge=BODY_HEIGHT_MIN_METERS,
        le=BODY_HEIGHT_MAX_METERS,
    )
    token: str
    source: str = "iphone"


class BodyHeightResponse(BaseModel):
    ok: bool
    published_topic: Optional[str] = None
    height: float
    message: str


class RobotModeRequest(BaseModel):
    mode: Literal["sit", "stand", "walk"]
    token: str
    source: str = "iphone"


class RobotModeResponse(BaseModel):
    ok: bool
    published_topic: Optional[str] = None
    mode: str
    message: str


class ControlSourceRequest(BaseModel):
    source_mode: Literal["waypoint", "hold", "sbus"]
    token: str
    source: str = "iphone"


class ControlSourceResponse(BaseModel):
    ok: bool
    published_topic: Optional[str] = None
    source_mode: str
    message: str


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
        arm_subtask_qos = QoSProfile(
            depth=1,
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
        self._current_arm_subtask_pub = self.create_publisher(
            String,
            CURRENT_ARM_SUBTASK_TOPIC,
            arm_subtask_qos,
        )
        self._human_waypoint_pub = self.create_publisher(PoseStamped, HUMAN_WAYPOINT_TOPIC, 10)
        self._app_robot_mode_pub = self.create_publisher(String, APP_ROBOT_MODE_TOPIC, 10)
        self._app_control_source_pub = self.create_publisher(String, APP_CONTROL_SOURCE_TOPIC, 10)
        self._human_velocity_pub = self.create_publisher(Twist, HUMAN_VELOCITY_TOPIC, 10)

        self._human_body_height_pub = self.create_publisher(Float32, HUMAN_BODY_HEIGHT_TOPIC, 10)
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
                CONTROL_STATE_TOPIC,
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
            f"arm actions -> {CURRENT_ARM_SUBTASK_TOPIC}, "
            f"manual goals -> {HUMAN_WAYPOINT_TOPIC}, "
            f"app mode -> {APP_ROBOT_MODE_TOPIC}, "
            f"app source -> {APP_CONTROL_SOURCE_TOPIC}, "
            f"manual velocity -> {HUMAN_VELOCITY_TOPIC}, "
            f"body height -> {HUMAN_BODY_HEIGHT_TOPIC}, "
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

    def publish_arm_action(self, command_name: str, source: str) -> None:
        payload = ARM_ACTION_COMMANDS[command_name]
        message = String()
        message.data = json.dumps(payload, separators=(",", ":"))
        self._current_arm_subtask_pub.publish(message)
        self._state.latest_command_text = command_name

        self.get_logger().warning(
            f"published iPhone arm action to {CURRENT_ARM_SUBTASK_TOPIC} "
            f"from {source}: {message.data}"
        )

    def publish_human_waypoint(self, x: float, y: float, yaw: float, source: str) -> None:
        message = PoseStamped()
        message.header.stamp = self.get_clock().now().to_msg()
        message.header.frame_id = "body"
        message.pose.position.x = x
        message.pose.position.y = y
        message.pose.position.z = 0.0
        message.pose.orientation.x = 0.0
        message.pose.orientation.y = 0.0
        message.pose.orientation.z = math.sin(yaw / 2.0)
        message.pose.orientation.w = math.cos(yaw / 2.0)
        self._human_waypoint_pub.publish(message)

        self.get_logger().warning(
            f"published iPhone body-local goal to {HUMAN_WAYPOINT_TOPIC} "
            f"from {source}: x={x:.2f}, y={y:.2f}, yaw={yaw:.2f}"
        )

    def publish_app_robot_mode(self, mode: str, source: str) -> None:
        message = String()
        message.data = mode
        self._app_robot_mode_pub.publish(message)
        self.get_logger().warning(
            f"published iPhone robot mode to {APP_ROBOT_MODE_TOPIC} "
            f"from {source}: {mode.upper()}"
        )

    def publish_human_velocity(
        self,
        forward: float,
        strafe: float,
        yaw: float,
        source: str,
    ) -> None:
        message = Twist()
        message.linear.x = forward
        message.linear.y = strafe
        message.angular.z = yaw
        self._human_velocity_pub.publish(message)

        self.get_logger().info(
            f"published iPhone deadman velocity to {HUMAN_VELOCITY_TOPIC} "
            f"from {source}: forward={forward:.2f}, "
            f"strafe={strafe:.2f}, yaw={yaw:.2f}"
        )

    def publish_human_body_height(self, height: float, source: str) -> None:
        message = Float32()
        message.data = height
        self._human_body_height_pub.publish(message)
        self.get_logger().warning(
            f"published iPhone body height to {HUMAN_BODY_HEIGHT_TOPIC} "
            f"from {source}: offset={height:+.2f}m"
        )

    def publish_app_control_source(self, source_mode: str, source: str) -> None:
        message = String()
        message.data = source_mode
        self._app_control_source_pub.publish(message)
        self.get_logger().warning(
            f"published iPhone control source to {APP_CONTROL_SOURCE_TOPIC} "
            f"from {source}: {source_mode.upper()}"
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
        elif topic == CONTROL_STATE_TOPIC:
            payload["type"] = "control_state"
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


def parse_battery_percentage(output: str) -> float:
    match = re.search(
        r"Battery\s+Remain:\s*([0-9]+(?:\.[0-9]+)?)\s*%",
        output,
        flags=re.IGNORECASE,
    )
    if match is None:
        raise ValueError("battery percentage was not present in script output")

    percentage = float(match.group(1))
    if not 0 <= percentage <= 100:
        raise ValueError("battery percentage was outside the expected range")
    return percentage


async def read_spot_battery_percentage() -> float:
    if not os.path.isfile(BATTERY_CHECK_SCRIPT):
        logger.error("battery check script not found: %s", BATTERY_CHECK_SCRIPT)
        raise HTTPException(
            status_code=503,
            detail="Spot battery check is not configured on the Jetson.",
        )

    try:
        process = await asyncio.create_subprocess_exec(
            "/bin/bash",
            BATTERY_CHECK_SCRIPT,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError as exc:
        logger.exception("could not start battery check: %s", exc)
        raise HTTPException(
            status_code=503,
            detail="Spot battery check could not be started.",
        ) from exc

    try:
        stdout, stderr = await asyncio.wait_for(
            process.communicate(),
            timeout=BATTERY_CHECK_TIMEOUT_SECONDS,
        )
    except asyncio.TimeoutError as exc:
        process.kill()
        await process.communicate()
        logger.error(
            "battery check timed out after %.1f seconds",
            BATTERY_CHECK_TIMEOUT_SECONDS,
        )
        raise HTTPException(
            status_code=504,
            detail="Spot did not return its battery level in time.",
        ) from exc

    output = stdout.decode("utf-8", errors="replace").strip()
    error_output = stderr.decode("utf-8", errors="replace").strip()
    if process.returncode != 0:
        logger.error(
            "battery check failed with exit code %s: %s",
            process.returncode,
            error_output or output,
        )
        raise HTTPException(
            status_code=502,
            detail="Could not read the Spot battery level.",
        )

    try:
        return parse_battery_percentage(output)
    except ValueError as exc:
        logger.error("unexpected battery check output: %s", output)
        raise HTTPException(
            status_code=502,
            detail="Spot returned an unreadable battery level.",
        ) from exc


@app.get("/health")
async def health() -> Dict[str, Any]:
    return {
        "ok": True,
        "ros_available": ROS_AVAILABLE,
        "ros_enabled": ros_node is not None,
        "task_topic": TASK_TOPIC,
        "control_topic": CONTROL_TOPIC,
        "current_subtask_topic": CURRENT_SUBTASK_TOPIC,
        "current_arm_subtask_topic": CURRENT_ARM_SUBTASK_TOPIC,
        "human_waypoint_topic": HUMAN_WAYPOINT_TOPIC,
        "app_robot_mode_topic": APP_ROBOT_MODE_TOPIC,
        "app_control_source_topic": APP_CONTROL_SOURCE_TOPIC,
        "control_state_topic": CONTROL_STATE_TOPIC,
        "human_velocity_topic": HUMAN_VELOCITY_TOPIC,
        "manual_control_axis_limit_m": MANUAL_CONTROL_AXIS_LIMIT_METERS,
        "subtask_status_topic": SUBTASK_STATUS_TOPIC,
        "task_planning_topic": TASK_PLANNING_TOPIC,
        "human_body_height_topic": HUMAN_BODY_HEIGHT_TOPIC,
        "body_height_min_m": BODY_HEIGHT_MIN_METERS,
        "body_height_max_m": BODY_HEIGHT_MAX_METERS,
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
    is_arm_action = command_name in ARM_ACTION_COMMANDS

    if ros_node is None:
        if not ALLOW_NO_ROS:
            raise HTTPException(status_code=503, detail="ROS 2 bridge is not available")
        state.latest_command_text = (
            command_name if is_control or is_arm_action else command_text
        )
        logger.info("accepted command in no-ROS test mode: %s", command_text)
        published_topic = None
        if is_control:
            command_type = "control"
        elif is_arm_action:
            command_type = "arm"
        else:
            command_type = "task"
    else:
        if is_control:
            ros_node.publish_control(command_name, request.source)
            published_topic = CONTROL_TOPIC
            command_type = "control"
        elif is_arm_action:
            ros_node.publish_arm_action(command_name, request.source)
            published_topic = CURRENT_ARM_SUBTASK_TOPIC
            command_type = "arm"
        else:
            ros_node.publish_task(command_text, request.source)
            published_topic = TASK_TOPIC
            command_type = "task"

    return CommandResponse(
        ok=True,
        published_topic=published_topic,
        command_type=command_type,
        text=command_name if is_control or is_arm_action else command_text,
    )


@app.post("/manual_control", response_model=ManualControlResponse)
async def manual_control(request: ManualControlRequest) -> ManualControlResponse:
    if request.token != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")

    published_topic: Optional[str] = None
    if ros_node is None:
        if not ALLOW_NO_ROS:
            raise HTTPException(status_code=503, detail="ROS 2 bridge is not available")
        logger.info(
            "accepted manual control in no-ROS test mode: x=%.2f, y=%.2f, yaw=%.2f",
            request.x,
            request.y,
            request.yaw,
        )
    else:
        ros_node.publish_human_waypoint(
            request.x,
            request.y,
            request.yaw,
            request.source,
        )
        published_topic = HUMAN_WAYPOINT_TOPIC

    return ManualControlResponse(
        ok=True,
        published_topic=published_topic,
        message="Manual goal published. Spot requires WALK with phone control enabled.",
    )


@app.post("/manual_velocity", response_model=ManualVelocityResponse)
async def manual_velocity(request: ManualVelocityRequest) -> ManualVelocityResponse:
    if request.token != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")

    published_topic: Optional[str] = None
    if ros_node is None:
        if not ALLOW_NO_ROS:
            raise HTTPException(status_code=503, detail="ROS 2 bridge is not available")
        logger.info(
            "accepted manual velocity in no-ROS test mode: "
            "forward=%.2f, strafe=%.2f, yaw=%.2f",
            request.forward,
            request.strafe,
            request.yaw,
        )
    else:
        ros_node.publish_human_velocity(
            request.forward,
            request.strafe,
            request.yaw,
            request.source,
        )
        published_topic = HUMAN_VELOCITY_TOPIC

    is_stop = max(
        abs(request.forward),
        abs(request.strafe),
        abs(request.yaw),
    ) < 1e-6
    return ManualVelocityResponse(
        ok=True,
        published_topic=published_topic,
        message=(
            "Direct motion stopped."
            if is_stop
            else "Deadman velocity refreshed; release the button to stop."
        ),
    )


@app.post("/body_height", response_model=BodyHeightResponse)
async def body_height(request: BodyHeightRequest) -> BodyHeightResponse:
    if request.token != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")

    published_topic: Optional[str] = None
    if ros_node is None:
        if not ALLOW_NO_ROS:
            raise HTTPException(status_code=503, detail="ROS 2 bridge is not available")
        logger.info(
            "accepted body height in no-ROS test mode: offset=%+.2fm",
            request.height,
        )
    else:
        ros_node.publish_human_body_height(request.height, request.source)
        published_topic = HUMAN_BODY_HEIGHT_TOPIC

    return BodyHeightResponse(
        ok=True,
        published_topic=published_topic,
        height=request.height,
        message=(
            f"Requested standing height offset {request.height:+.2f} m. "
            "Spot requires Phone control plus WALK."
        ),
    )


@app.post("/robot_mode", response_model=RobotModeResponse)
async def robot_mode(request: RobotModeRequest) -> RobotModeResponse:
    if request.token != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")

    published_topic: Optional[str] = None
    if ros_node is None:
        if not ALLOW_NO_ROS:
            raise HTTPException(status_code=503, detail="ROS 2 bridge is not available")
        logger.info(
            "accepted robot mode in no-ROS test mode from %s: %s",
            request.source,
            request.mode.upper(),
        )
    else:
        ros_node.publish_app_robot_mode(request.mode, request.source)
        published_topic = APP_ROBOT_MODE_TOPIC

    return RobotModeResponse(
        ok=True,
        published_topic=published_topic,
        mode=request.mode,
        message=(
            f"Requested {request.mode.upper()}. "
            "Spot accepts app mode changes only while SBUS is unavailable."
        ),
    )


@app.post("/control_source", response_model=ControlSourceResponse)
async def control_source(request: ControlSourceRequest) -> ControlSourceResponse:
    if request.token != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")

    published_topic: Optional[str] = None
    if ros_node is None:
        if not ALLOW_NO_ROS:
            raise HTTPException(status_code=503, detail="ROS 2 bridge is not available")
        logger.info(
            "accepted control source in no-ROS test mode from %s: %s",
            request.source,
            request.source_mode.upper(),
        )
    else:
        ros_node.publish_app_control_source(request.source_mode, request.source)
        published_topic = APP_CONTROL_SOURCE_TOPIC

    source_label = {
        "waypoint": "NAVIGATION",
        "hold": "STOP",
        "sbus": "PHONE",
    }[request.source_mode]
    return ControlSourceResponse(
        ok=True,
        published_topic=published_topic,
        source_mode=request.source_mode,
        message=(
            f"Requested {source_label} control source. "
            "Spot accepts app source changes only while SBUS is unavailable."
        ),
    )


@app.post("/battery", response_model=BatteryResponse)
async def battery(request: BatteryRequest) -> BatteryResponse:
    if request.token != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")

    percentage = await read_spot_battery_percentage()
    formatted_percentage = f"{percentage:g}%"
    logger.info(
        "reported Spot battery to %s: %s",
        request.source,
        formatted_percentage,
    )
    return BatteryResponse(
        ok=True,
        percentage=percentage,
        message=f"Spot battery: {formatted_percentage}",
    )


@app.websocket("/status")
async def status_stream(websocket: WebSocket) -> None:
    await sockets.connect(websocket)

    try:
        with state.status_lock:
            status_by_topic = dict(state.latest_status_by_topic)
            latest_status_text = state.latest_status_text

        replay_order = (
            CONTROL_STATE_TOPIC,
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
