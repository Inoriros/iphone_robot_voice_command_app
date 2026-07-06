# Jetson Robot Voice Command Bridge

FastAPI bridge for the iPhone app.

It exposes:

- `POST /command` for verified iPhone commands.
- `WebSocket /status` for live robot task status.
- ROS 2 publisher: `/scenario` as `std_msgs/msg/String` for normal spoken tasks.
- ROS 2 publisher: `/task_control` as `std_msgs/msg/String` for stop/pause/resume controls.
- ROS 2 fallback publishers: `/current_subtask` and `/start_exploration` for immediate runtime preemption.
- ROS 2 status subscribers: `/current_subtask`, `/subtask_status`, `/task_planning`, `/sim_control`, plus optional `/task_status`.

## How It Connects To The Robot

The current SAIR task planner starts tasks from `/scenario`, not `/current_subtask`.
The phone should keep sending every spoken command to:

```http
POST http://JETSON_IP:8080/command
```

The bridge decides what to do:

- Normal text, for example `find the red fire extinguisher`, is published directly to `/scenario`.
- `STOP_CURRENT_TASK`, `STOP_CURRENT_SUBTASK`, `PAUSE_CURRENT_SUBTASK`, and `RESUME_CURRENT_SUBTASK` are published to `/task_control`.
- Stop/pause commands also publish a non-active `/current_subtask` marker and `/start_exploration=false` so currently running exploration, following, VLM guidance, and navigation skills can preempt quickly.

The task planner listens to `/task_control`:

- `STOP_CURRENT_TASK`: cancel the whole active plan and set the coordinator idle.
- `STOP_CURRENT_SUBTASK`: stop the current subtask and advance to the next one.
- `PAUSE_CURRENT_SUBTASK`: stop runtime motion and keep the current subtask index.
- `RESUME_CURRENT_SUBTASK`: dispatch the paused subtask again.

The app should read live status from:

```text
ws://JETSON_IP:8080/status
```

Each WebSocket message is JSON with:

```json
{"type":"current_subtask","topic":"/current_subtask","timestamp":123.0,"data":{"skill":"exploration"}}
```

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
export ROBOT_BRIDGE_TOKEN="2001"
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
  -d '{"text":"start exploration and find the elevator","token":"2001","source":"iphone"}'
```

On the Jetson, check the ROS topic:

```bash
ros2 topic echo /scenario
```

The iPhone task-control buttons send these exact command texts through the same `/command` endpoint:

```text
STOP_CURRENT_TASK
STOP_CURRENT_SUBTASK
PAUSE_CURRENT_SUBTASK
```

Robot-side consumers of `/current_subtask` should handle stop messages as high-priority stop requests and pause messages as subtask pause requests.

You can test a stop button from another machine:

```bash
curl -X POST http://JETSON_IP:8080/command \
  -H "Content-Type: application/json" \
  -d '{"text":"STOP_CURRENT_TASK","token":"2001","source":"iphone"}'
```

Publish fake status:

```bash
ros2 topic pub /task_status std_msgs/msg/String \
  "{data: '{\"state\":\"running\",\"skill\":\"exploration\",\"message\":\"Exploring hallway\",\"progress\":0.42}'}"
```

For the real robot system, the bridge streams status automatically from `/current_subtask`, `/subtask_status`, `/task_planning`, and `/sim_control`, so `/task_status` is only needed for custom status messages.

## Laptop Test Mode Without ROS

For network/UI testing only:

```bash
export ROBOT_BRIDGE_ALLOW_NO_ROS=true
python3 robot_bridge.py
```

In this mode `/command` accepts commands but does not publish to ROS.
