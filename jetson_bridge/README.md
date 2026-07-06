# Jetson Robot Voice Command Bridge

FastAPI bridge for the iPhone app.

It exposes:

- `POST /command` for verified iPhone commands.
- `WebSocket /status` for live robot task status.
- ROS 2 publisher: `/current_subtask` as `std_msgs/msg/String`.
- ROS 2 subscriber: `/task_status` as `std_msgs/msg/String`.

## Install on Jetson

```bash
cd ~/iphone_robot_voice_command_app/jetson_bridge
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Make sure ROS 2 is sourced before running:

```bash
source /opt/ros/humble/setup.bash
```

Use your installed ROS 2 distro path if it is not Humble.

## Run

```bash
export ROBOT_BRIDGE_TOKEN="change_this_token"
python3 robot_bridge.py
```

The server listens on:

```text
http://0.0.0.0:8080
```

Your iPhone should connect to the Jetson IP address on the same Wi-Fi network.

## Test From Another Machine

```bash
curl -X POST http://JETSON_IP:8080/command \
  -H "Content-Type: application/json" \
  -d '{"text":"start exploration and find the elevator","token":"change_this_token","source":"iphone"}'
```

On the Jetson, check the ROS topic:

```bash
ros2 topic echo /current_subtask
```

The iPhone task-control buttons send these exact command texts through the same `/command` endpoint:

```text
STOP_CURRENT_TASK
STOP_CURRENT_SUBTASK
PAUSE_CURRENT_SUBTASK
```

Robot-side consumers of `/current_subtask` should handle stop messages as high-priority stop requests and pause messages as subtask pause requests.

Publish fake status:

```bash
ros2 topic pub /task_status std_msgs/msg/String \
  "{data: '{\"state\":\"running\",\"skill\":\"exploration\",\"message\":\"Exploring hallway\",\"progress\":0.42}'}"
```

## Laptop Test Mode Without ROS

For network/UI testing only:

```bash
export ROBOT_BRIDGE_ALLOW_NO_ROS=true
python3 robot_bridge.py
```

In this mode `/command` accepts commands but does not publish to ROS.
