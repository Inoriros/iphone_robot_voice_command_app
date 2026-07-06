from __future__ import annotations

import asyncio
import json
import logging
import os
import threading
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Set

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field

try:
    import rclpy
    from rclpy.node import Node
    from std_msgs.msg import String

    ROS_AVAILABLE = True
except ImportError:
    rclpy = None
    Node = object
    String = None
    ROS_AVAILABLE = False


logging.basicConfig(
    level=os.getenv("ROBOT_BRIDGE_LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("robot_bridge")


COMMAND_TOPIC = os.getenv("ROBOT_COMMAND_TOPIC", "/current_subtask")
STATUS_TOPIC = os.getenv("ROBOT_STATUS_TOPIC", "/task_status")
AUTH_TOKEN = os.getenv("ROBOT_BRIDGE_TOKEN", "change_this_token")
ALLOW_NO_ROS = os.getenv("ROBOT_BRIDGE_ALLOW_NO_ROS", "false").lower() in {
    "1",
    "true",
    "yes",
}


class CommandRequest(BaseModel):
    text: str = Field(..., min_length=1)
    token: str
    source: str = "iphone"


class CommandResponse(BaseModel):
    ok: bool
    published_topic: Optional[str] = None
    text: Optional[str] = None


@dataclass
class BridgeState:
    latest_status_text: Optional[str] = None
    latest_command_text: Optional[str] = None
    loop: Optional[asyncio.AbstractEventLoop] = None


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
        self._publisher = self.create_publisher(String, COMMAND_TOPIC, 10)
        self.create_subscription(String, STATUS_TOPIC, self._handle_status, 10)
        self.get_logger().info(
            f"bridge ready: publishing {COMMAND_TOPIC}, listening {STATUS_TOPIC}"
        )

    def publish_command(self, command_text: str, source: str) -> None:
        payload = {
            "skill": "voice_command",
            "text": command_text,
            "source": source,
            "timestamp": time.time(),
        }
        message = String()
        message.data = json.dumps(payload, separators=(",", ":"))
        self._publisher.publish(message)
        self._state.latest_command_text = command_text
        self.get_logger().info(f"published command to {COMMAND_TOPIC}: {command_text}")

    def _handle_status(self, message: Any) -> None:
        status_text = str(message.data)
        self._state.latest_status_text = status_text

        if self._state.loop is None:
            self.get_logger().warning("web event loop not ready; dropping status update")
            return

        asyncio.run_coroutine_threadsafe(
            self._sockets.broadcast_text(status_text),
            self._state.loop,
        )


state = BridgeState()
sockets = WebSocketManager()
app = FastAPI(title="iPhone Robot Voice Command Bridge")
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


@app.on_event("startup")
async def on_startup() -> None:
    state.loop = asyncio.get_running_loop()
    start_ros()


@app.on_event("shutdown")
async def on_shutdown() -> None:
    stop_ros()


@app.get("/health")
async def health() -> Dict[str, Any]:
    return {
        "ok": True,
        "ros_available": ROS_AVAILABLE,
        "ros_enabled": ros_node is not None,
        "command_topic": COMMAND_TOPIC,
        "status_topic": STATUS_TOPIC,
    }


@app.post("/command", response_model=CommandResponse)
async def command(request: CommandRequest) -> CommandResponse:
    command_text = request.text.strip()

    if request.token != AUTH_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")

    if not command_text:
        raise HTTPException(status_code=400, detail="Empty or invalid command")

    if ros_node is None:
        if not ALLOW_NO_ROS:
            raise HTTPException(status_code=503, detail="ROS 2 bridge is not available")
        state.latest_command_text = command_text
        logger.info("accepted command in no-ROS test mode: %s", command_text)
        published_topic = None
    else:
        ros_node.publish_command(command_text, request.source)
        published_topic = COMMAND_TOPIC

    return CommandResponse(ok=True, published_topic=published_topic, text=command_text)


@app.websocket("/status")
async def status_stream(websocket: WebSocket) -> None:
    await sockets.connect(websocket)

    try:
        if state.latest_status_text:
            await websocket.send_text(state.latest_status_text)
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
