# Jetson Robot Voice Command Bridge

FastAPI bridge for the iPhone app.

It exposes:

- `POST /command` for verified iPhone commands.
- `POST /battery` for authenticated Spot battery checks.
- `WebSocket /status` for live robot task status.
- ROS 2 publisher: `/scenario` as `std_msgs/msg/String` for normal spoken tasks.
- ROS 2 publisher: `/task_control` as `std_msgs/msg/String` for stop/pause/resume controls.
- ROS 2 fallback publisher: `/current_subtask` for immediate foreground-skill preemption.
- ROS 2 publisher: `/current_arm_subtask` for fixed arm actions.
- ROS 2 status subscribers: `/current_subtask`, `/subtask_status`, `/task_planning`, `/subtask_prompt_evidance`, `/subtask_image_evidence`, `/sim_control`, plus optional `/task_status`.

## How It Connects To The Robot

The current SAIR task planner starts tasks from `/scenario`, not `/current_subtask`.
The phone should keep sending every spoken command to:

```http
POST http://JETSON_IP:8080/command
```

The bridge decides what to do:

- Normal text, for example `find the red fire extinguisher`, is published directly to `/scenario`.
- `STOP_CURRENT_TASK`, `STOP_CURRENT_SUBTASK`, `PAUSE_CURRENT_SUBTASK`, and `RESUME_CURRENT_SUBTASK` are published to `/task_control`.
- `ARM_RELAX`, `ARM_BUTTON`, and `ARM_PRESS` publish fixed action JSON to `/current_arm_subtask`.
- Stop/pause commands also publish a non-active `/current_subtask` marker so following, VLM guidance, and navigation skills can preempt quickly. They do not stop the persistent exploration module or clear its history.

The battery button sends an authenticated request to:

```http
POST http://JETSON_IP:8080/battery
```

```json
{"token":"2001","source":"iphone"}
```

The bridge runs `/root/spot_battery_check.sh` and returns the parsed percentage.
Override the script path or the 20-second timeout when needed:

```bash
export SPOT_BATTERY_CHECK_SCRIPT="/path/to/spot_battery_check.sh"
export SPOT_BATTERY_CHECK_TIMEOUT_SECONDS="20"
```

The task planner listens to `/task_control`:

- `STOP_CURRENT_TASK`: cancel the whole active plan and set the coordinator idle.
- `STOP_CURRENT_SUBTASK`: stop the current subtask and advance to the next one.
- `PAUSE_CURRENT_SUBTASK`: stop runtime motion and keep the current subtask index.
- `RESUME_CURRENT_SUBTASK`: dispatch the paused subtask again.

The app should read live status from:

```text
ws://JETSON_IP:8080/status
```

Use `ws://`, not `http://`, for `/status`. A browser-style HTTP `GET /status` will return `404` because `/status` is a WebSocket endpoint.

Each WebSocket message is JSON with:

```json
{"type":"current_subtask","topic":"/current_subtask","timestamp":123.0,"data":{"skill":"exploration"}}
```

The bridge also sends:

- `task_plan`: parsed `/task_planning` JSON.
- `prompt_evidence`: parsed `/subtask_prompt_evidance` JSON.
- `image_evidence`: `/subtask_image_evidence` with `format` and base64 image bytes.

The latest event for each ROS topic is retained by the bridge and replayed to
a newly connected status WebSocket.

## Install on Jetson

Use the same Python environment that will run the bridge. On this Jetson that is usually `sair_stack`:

```bash
conda activate sair_stack
cd ~/iphone_robot_voice_command_app/jetson_bridge
python3 -m pip install -r requirements.txt
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
  -d '{"text":"search for the elevator","token":"2001","source":"iphone"}'
```

Test the Spot battery endpoint:

```bash
curl -X POST http://JETSON_IP:8080/battery \
  -H "Content-Type: application/json" \
  -d '{"token":"2001","source":"manual-test"}'
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

The three arm buttons send `ARM_RELAX`, `ARM_BUTTON`, and `ARM_PRESS` through
`/command`. The bridge publishes these respective payloads:

```text
{"action_name":"move_to_relax","start_pos":[0.0,0.0,0.0],"target_pos":[0.0,0.0,0.0]}
{"action_name":"move_to_button","start_pos":[0.0,0.0,0.0],"target_pos":[0.0,0.0,0.0]}
{"action_name":"move_to_press","start_pos":[0.0,0.0,0.0],"target_pos":[0.0,0.0,0.0]}
```

Test an arm button and watch the ROS topic:

```bash
curl -X POST http://JETSON_IP:8080/command \
  -H "Content-Type: application/json" \
  -d '{"text":"ARM_RELAX","token":"2001","source":"manual-test"}'

ros2 topic echo /current_arm_subtask
```

You can test a stop button from another machine:

```bash
curl -X POST http://JETSON_IP:8080/command \
  -H "Content-Type: application/json" \
  -d '{"text":"STOP_CURRENT_TASK","token":"2001","source":"iphone"}'
```

Publish fake status:

```bash
ros2 topic pub /task_status std_msgs/msg/String \
  "{data: '{\"state\":\"running\",\"skill\":\"searching_navigation\",\"message\":\"Searching hallway\",\"progress\":0.42}'}"
```

For the real robot system, the bridge streams status automatically from `/current_subtask`, `/subtask_status`, `/task_planning`, `/subtask_prompt_evidance`, `/subtask_image_evidence`, and `/sim_control`, so `/task_status` is only needed for custom status messages.

## Laptop Test Mode Without ROS

For network/UI testing only:

```bash
export ROBOT_BRIDGE_ALLOW_NO_ROS=true
python3 robot_bridge.py
```

In this mode `/command` accepts commands but does not publish to ROS.

## Troubleshooting

If the server logs this warning:

```text
No supported WebSocket library detected
```

install the requirements in the Python environment that runs `robot_bridge.py`:

```bash
cd ~/iphone_robot_voice_command_app/jetson_bridge
python3 -m pip install -r requirements.txt
```

Then restart the bridge.
