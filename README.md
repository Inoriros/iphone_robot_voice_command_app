# iPhone Robot Voice Command App

SwiftUI iPhone app plus Jetson bridge for sending high-level robot task commands by voice.

The iPhone performs speech-to-text locally, lets the user edit/verify the recognized command, then sends the command to a Jetson AGX Orin over robot Wi-Fi. The Jetson bridge publishes commands into ROS 2 and streams robot task status back to the app.

## Architecture

```text
iPhone app
  - Apple Speech framework: microphone audio to recognized text
  - SwiftUI: editable command text, connection controls, status display
  - HTTP POST: sends verified command to Jetson
  - WebSocket: receives task status, task plans, and reasoning evidence

Jetson bridge
  - FastAPI POST /command
  - FastAPI POST /battery
  - FastAPI POST /manual_control
  - FastAPI POST /manual_velocity
  - FastAPI POST /body_height
  - FastAPI POST /robot_mode
  - FastAPI POST /control_source
  - FastAPI WebSocket /status
  - ROS 2 publishers: /scenario, /task_control, /current_arm_subtask, /human_way_point,
    /human_velocity_command, /human_body_height, /spot/app_robot_mode, and /spot/app_control_source
  - ROS 2 subscribers: task status, /arm_skill_status, /task_planning, and reasoning evidence
```

## Repository Layout

```text
RobotVoiceCommandApp.xcodeproj/     Xcode project
RobotVoiceCommandApp/               SwiftUI iPhone app source
jetson_bridge/                      Python FastAPI + ROS 2 bridge for Jetson
```

## iPhone Requirements

- Mac with Xcode installed.
- iPhone running iOS 17 or newer.
- Apple ID configured in Xcode signing.
- iPhone and Jetson connected to the same Wi-Fi network.

## Build and Install on iPhone

1. Open the project in Xcode:

   ```text
   RobotVoiceCommandApp.xcodeproj
   ```

2. Connect your iPhone to the Mac.

3. In Xcode, select your iPhone as the run destination.

4. Select the `RobotVoiceCommandApp` target, then open **Signing & Capabilities**.

5. Enable **Automatically manage signing** and select your Apple ID/team.

6. If Xcode says the bundle identifier is unavailable, change it to something unique, for example:

   ```text
   com.yourname.RobotVoiceCommandApp
   ```

7. Press **Run** in Xcode.

8. On first launch, allow these iPhone permissions:

   - Microphone
   - Speech Recognition
   - Local Network

If Developer Mode is required, iOS usually shows it after the first Xcode install attempt. Enable it under **Settings > Privacy & Security > Developer Mode**, then restart the phone if prompted.

## Run the Jetson Bridge

Copy or clone this repository onto the Jetson, then install the bridge dependencies:

```bash
cd iphone_robot_voice_command_app/jetson_bridge
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Source ROS 2 before starting the bridge:

```bash
source /opt/ros/humble/setup.bash
```

Use your actual ROS 2 distro path if it is not Humble.

Start the bridge:

```bash
export ROBOT_BRIDGE_TOKEN="2001"
python3 robot_bridge.py
```

By default the bridge listens on:

```text
http://0.0.0.0:8080
```

The iPhone app should use the Jetson's Wi-Fi IP address, for example:

```text
192.168.8.150
```

## App Usage

1. Enter the Jetson IP address.
2. Enter the auth token. It must match `ROBOT_BRIDGE_TOKEN` on the Jetson.
3. Tap **Connect** to open the status WebSocket.
4. Tap **Check Battery** at any time to show Spot's current battery percentage.
5. Tap **Start Listening** and speak a high-level robot command.
6. Tap **Stop Listening**.
7. Edit or verify the recognized text.
8. Tap **Send**.

The app never auto-sends partial speech recognition results. Commands are only sent after the user taps **Send**.

The app also has fixed task-control buttons:

```text
Stop Task       sends STOP_CURRENT_TASK
Stop Subtask    sends STOP_CURRENT_SUBTASK
Pause Subtask   sends PAUSE_CURRENT_SUBTASK
```

The Jetson bridge forwards these controls on `/task_control` and publishes an
immediate `/current_subtask` preemption marker for stop/pause commands.

The app also has seven fixed arm controls:

```text
Relax             sends ARM_RELAX
Move to Button    sends ARM_BUTTON
Press Button      sends ARM_PRESS
Observe Bottle    sends ARM_OBSERVE_BOTTLE
Grasp Bottle      sends ARM_GRASP_BOTTLE
Release Bottle    sends ARM_RELEASE_BOTTLE
Place Down Bottle sends ARM_PLACE_DOWN_BOTTLE
```

The app receives live mode authority from `/spot/control_state`:

- While SBUS is available, its physical mode/source switches own the robot.
- When SBUS is disabled, disconnected, timed out, or in failsafe, the app unlocks
  both the **Navigation**/**Stop**/**Phone** source buttons and the
  **SIT**/**STAND**/**WALK** mode buttons.
- The user must explicitly select both a source and a mode after SBUS is lost.
- **Navigation** + **WALK** enables autonomous `/way_point` goals.
- **Phone** + **WALK** enables standing height, direct buttons, the drive
  joystick, and the body-relative waypoint panel.
- **Stop** cancels base motion, clears active waypoints, and commands Spot to stand.
- The first valid recovered SBUS packet stops any app trajectory and returns
  both switches to the physical controller.

- **Standing Height:** select an offset from -20 cm to +20 cm and tap **Apply
  Height**; **Nominal** resets the offset to zero.
- **Direct Rotation:** press and hold **Left** or **Right**; release to stop.
- **Direct Movement:** press and hold an arrow; release to stop.
- **Drive Joystick:** choose a persistent 100%–200% maximum throttle, then drag
  vertically for forward/reverse and horizontally for steering. The default is
  150%, and diagonal drag makes Spot move and rotate simultaneously.
- **Body-Relative Waypoint:** choose a range from 2–6 m, then tap the square
  panel. Its fixed center arrow is Spot, up is forward, and left is Spot's left.
  The target yaw follows the center-to-target line.

The bridge publishes direct motion as `Twist` messages on
`/human_velocity_command` and panel goals as body-frame `PoseStamped` messages
on `/human_way_point`. Direct commands refresh while a button is held or the
joystick is dragged. The joystick publishes `forward` and `yaw` together so Spot
can move along a curve. With the default 0.5 m/s controller scale, the slider
covers 0.5–1.0 m/s and its initial 150% setting produces 0.75 m/s. Release publishes
zero velocity, and the Spot controller also stops after 0.35 seconds without a
refresh. While SBUS is connected in
SBUS + WALK, moving any physical stick cancels phone motion immediately.

## Network API

The iPhone sends commands to:

```text
POST http://JETSON_IP:8080/command
```

Request body:

```json
{
  "text": "search for the elevator",
  "token": "2001",
  "source": "iphone"
}
```

Fixed task-control request bodies use the same endpoint and token:

```json
{
  "text": "STOP_CURRENT_TASK",
  "token": "2001",
  "source": "iphone"
}
```

```json
{
  "text": "STOP_CURRENT_SUBTASK",
  "token": "2001",
  "source": "iphone"
}
```

```json
{
  "text": "PAUSE_CURRENT_SUBTASK",
  "token": "2001",
  "source": "iphone"
}
```

Fixed arm-action requests use the same endpoint. For example:

```json
{
  "text": "ARM_RELAX",
  "token": "2001",
  "source": "iphone"
}
```

The bridge maps the seven command texts to `/current_arm_subtask` payloads:

```text
ARM_RELAX   -> {"action_name":"move_to_relax","start_pos":[0.0,0.0,0.0],"target_pos":[0.0,0.0,0.0]}
ARM_BUTTON  -> {"action_name":"move_to_button","start_pos":[0.0,0.0,0.0],"target_pos":[0.0,0.0,0.0]}
ARM_PRESS   -> {"action_name":"move_to_press","start_pos":[0.0,0.0,0.0],"target_pos":[0.0,0.0,0.0]}
ARM_OBSERVE_BOTTLE -> {"action_name":"move_to_bottle","start_pos":[0.0,0.0,0.0],"target_pos":[0.0,0.0,0.0]}
ARM_GRASP_BOTTLE -> {"action_name":"grasp_water_bottle","start_pos":[0.0,0.0,0.0],"target_pos":[0.0,0.0,0.0]}
ARM_RELEASE_BOTTLE -> {"action_name":"release_bottle","start_pos":[0.0,0.0,0.0],"target_pos":[0.0,0.0,0.0]}
ARM_PLACE_DOWN_BOTTLE -> {"action_name":"place_down_bottle","start_pos":[0.0,0.0,0.0],"target_pos":[0.0,0.0,0.0]}
```

`ARM_GRASP_BOTTLE` remains the existing one-shot grasp command and publishes
exactly `grasp_water_bottle`—never `move_to_grasp`. `ARM_OBSERVE_BOTTLE` moves
the arm to the bottle observation pose. `ARM_RELEASE_BOTTLE` publishes
`release_bottle`, while `ARM_PLACE_DOWN_BOTTLE` runs the place-down sequence.

`/current_arm_subtask` uses reliable, transient-local, keep-last depth-1 QoS.
Each button tap publishes its command once, and the live status WebSocket must be
connected before the app enables an arm command.

The bridge subscribes to `/arm_skill_status` as `std_msgs/msg/String` with
reliable, transient-local, keep-last depth-20 QoS. Immediately before publishing
an arm command, it records the ROS clock and returns that send boundary in the
`/command` response.

The bridge and app each retain up to 100 arm status events. After a send, the app
finds the first recognized lifecycle event whose `action_name` matches, whose
`stamp_sec` is at least the send boundary, and whose `command_id` is not the prior
command. It then locks onto that ID and ignores every other command. This also
lets a reconnect recover when the original `accepted` event was missed but a
later `started`, `running`, or terminal event is available.

Arm buttons unlock only after `completed`, `failed`, `canceled`, or `rejected`.
A 10-second acceptance delay or 180-second execution-status delay shows a warning
but keeps the controls locked until status recovers. The one-shot replacement
switch appears only after the current skill has a controller-issued command ID.
Each HTTP completion is tied to its command generation, so a delayed response
from an older request cannot clear or confirm the replacement command.

Before tapping **Grasp Bottle**, the wrist camera must see the bottle and
`/detect_3d_bbox`, `/plan_pose_intu`, `/plan_joint_target`, and the
`pure_arm_pickup` action server must be running.

Phone motion controls send:

```text
POST http://JETSON_IP:8080/manual_control
```

```json
{
  "x": 1.0,
  "y": 0.5,
  "yaw": 0.0,
  "token": "2001",
  "source": "iphone"
}
```

Coordinates use Spot's body frame: `x` is forward, `y` is left, and `yaw` is
relative to the current heading in radians.

Direct press-and-hold controls and the drive joystick send normalized velocity
refreshes to:

```text
POST http://JETSON_IP:8080/manual_velocity
```

```json
{
  "forward": 1.0,
  "strafe": 0.0,
  "yaw": 0.0,
  "token": "2001",
  "source": "iphone"
}
```

`strafe` and `yaw` remain in `[-1, 1]`. Press-and-hold forward/reverse commands
also remain in `[-1, 1]`; only the car-style joystick scales `forward` using
the persistent user-selected limit from 1.0 through 2.0. Its maximum range is
`[-2, 2]`. Vertical displacement maps to `forward`, horizontal displacement
maps to `yaw`, and `strafe` remains zero, so diagonal drag produces
forward/reverse motion and rotation together. The app sends a zero command on
release. The controller limits actual speed and stops if refreshes time out.


Standing-height controls send a body-height offset relative to Spot's nominal stand:

```text
POST http://JETSON_IP:8080/body_height
```

```json
{
  "height": 0.10,
  "token": "2001",
  "source": "iphone"
}
```

The accepted range is -0.20 m to +0.20 m. The controller requires **Phone** +
**WALK**, rejects the request while a physical SBUS stick is active, stops any
active phone trajectory, and then sends the new stand posture. **Nominal** sends
`0.0`.

Fallback robot-mode controls send:

```text
POST http://JETSON_IP:8080/robot_mode
```

```json
{
  "mode": "walk",
  "token": "2001",
  "source": "iphone"
}
```

Valid modes are `sit`, `stand`, and `walk`. The Spot controller ignores this
topic while SBUS is available.

Fallback control-source controls send:

```text
POST http://JETSON_IP:8080/control_source
```

```json
{
  "source_mode": "sbus",
  "token": "2001",
  "source": "iphone"
}
```

Valid values mirror the physical three-position control-source switch:
`waypoint` selects Navigation, `hold` selects Stop, and `sbus` selects Phone.
The Spot controller ignores this topic while SBUS is available.

The battery button sends:

```text
POST http://JETSON_IP:8080/battery
```

```json
{
  "token": "2001",
  "source": "iphone"
}
```

The bridge runs `/root/spot_battery_check.sh` by default and returns the parsed
percentage. Set `SPOT_BATTERY_CHECK_SCRIPT` before starting the bridge if the
script is installed elsewhere.

The app receives status from:

```text
ws://JETSON_IP:8080/status
```

The bridge accepts simple string status messages or JSON status messages from ROS 2.
It also streams and the app displays:

- `/task_planning` as a `task_plan` event.
- `/subtask_prompt_evidance` as a `prompt_evidence` event.
- `/subtask_image_evidence` as an `image_evidence` event containing base64 compressed image bytes.

Example status WebSocket message from the Jetson bridge:

```json
{
  "state": "running",
  "skill": "searching_navigation",
  "subtask": "find the elevator",
  "message": "Exploring hallway",
  "progress": 0.42
}
```

## ROS 2 Topics

Command topics published by the bridge:

```text
/scenario
std_msgs/msg/String

/task_control
std_msgs/msg/String

/current_arm_subtask
std_msgs/msg/String

/arm_skill_status
std_msgs/msg/String

/human_way_point
geometry_msgs/msg/PoseStamped

/human_velocity_command
geometry_msgs/msg/Twist

/human_body_height
std_msgs/msg/Float32

/spot/app_robot_mode
std_msgs/msg/String

/spot/app_control_source
std_msgs/msg/String
```

Status and evidence topics consumed by the bridge include:

```text
/current_subtask
/subtask_status
/task_planning
/subtask_prompt_evidance
/sim_control
/task_status
/spot/control_state
std_msgs/msg/String

/subtask_image_evidence
sensor_msgs/msg/CompressedImage
```

## Manual Tests

Test command publishing:

```bash
curl -X POST http://JETSON_IP:8080/command \
  -H "Content-Type: application/json" \
  -d '{"text":"search for the elevator","token":"2001","source":"iphone"}'
```

Test the battery endpoint:

```bash
curl -X POST http://JETSON_IP:8080/battery \
  -H "Content-Type: application/json" \
  -d '{"token":"2001","source":"manual-test"}'
```

Test an arm action and watch its ROS topic:

```bash
curl -X POST http://JETSON_IP:8080/command \
  -H "Content-Type: application/json" \
  -d '{"text":"ARM_RELAX","token":"2001","source":"manual-test"}'

ros2 topic echo /current_arm_subtask
```

Test manual-control routing without requesting motion:

```bash
ros2 topic echo /human_way_point

curl -X POST http://JETSON_IP:8080/manual_control \
  -H "Content-Type: application/json" \
  -d '{"x":0.0,"y":0.0,"yaw":0.0,"token":"2001","source":"manual-test"}'
```

Test robot-mode routing only while SBUS is unavailable:

```bash
ros2 topic echo /spot/app_robot_mode

curl -X POST http://JETSON_IP:8080/robot_mode \
  -H "Content-Type: application/json" \
  -d '{"mode":"stand","token":"2001","source":"manual-test"}'
```

Test control-source routing only while SBUS is unavailable:

```bash
ros2 topic echo /spot/app_control_source

curl -X POST http://JETSON_IP:8080/control_source \
  -H "Content-Type: application/json" \
  -d '{"source_mode":"hold","token":"2001","source":"manual-test"}'
```

Watch the ROS 2 normal task topic:

```bash
ros2 topic echo /scenario
```

Publish fake robot status:

```bash
ros2 topic pub /task_status std_msgs/msg/String \
  "{data: '{\"state\":\"running\",\"skill\":\"searching_navigation\",\"message\":\"Searching hallway\",\"progress\":0.42}'}"
```

## Test Without ROS 2

For laptop or network testing only:

```bash
cd jetson_bridge
export ROBOT_BRIDGE_ALLOW_NO_ROS=true
python3 robot_bridge.py
```

In this mode the bridge accepts `/command`, `/manual_control`, `/manual_velocity`, `/body_height`, `/robot_mode`, and `/control_source` requests and supports WebSocket status testing, but it does not publish to ROS 2.

You can push fake status updates with:

```bash
curl -X POST http://localhost:8080/mock_status \
  -H "Content-Type: application/json" \
  -d '{"state":"running","message":"Mock status from bridge","progress":0.5}'
```

## Troubleshooting

- **The iPhone cannot connect to the Jetson:** confirm both devices are on the same Wi-Fi network and the app is using the Jetson's actual IP address.
- **Invalid token:** make sure the iPhone token matches `ROBOT_BRIDGE_TOKEN`.
- **No speech recognition:** allow Speech Recognition and Microphone permissions in iOS Settings.
- **No local network access:** allow Local Network permission for the app in iOS Settings.
- **No ROS messages:** make sure ROS 2 is sourced before running `robot_bridge.py`.
- **HTTP or WebSocket blocked:** the app currently uses development HTTP/WS local-network traffic. For production, use HTTPS/WSS and narrow the App Transport Security settings.

## Safety Notes

This app is for high-level task commands, not emergency control.

Keep emergency stop, joystick override, and obstacle avoidance independent from this app. Add robot-side command validation before using it around people or valuable equipment.
