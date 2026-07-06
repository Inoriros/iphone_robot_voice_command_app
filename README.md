# iPhone Robot Voice Command App

SwiftUI iPhone app plus Jetson bridge for sending high-level robot task commands by voice.

The iPhone performs speech-to-text locally, lets the user edit/verify the recognized command, then sends the command to a Jetson AGX Orin over robot Wi-Fi. The Jetson bridge publishes commands into ROS 2 and streams robot task status back to the app.

## Architecture

```text
iPhone app
  - Apple Speech framework: microphone audio to recognized text
  - SwiftUI: editable command text, connection controls, status display
  - HTTP POST: sends verified command to Jetson
  - WebSocket: receives task status updates

Jetson bridge
  - FastAPI POST /command
  - FastAPI WebSocket /status
  - ROS 2 publisher: /scenario for normal spoken tasks
  - ROS 2 publisher: /task_control for stop/pause/resume controls
  - ROS 2 fallback publishers: /current_subtask and /start_exploration
  - ROS 2 status subscribers: /current_subtask, /subtask_status, /task_planning, /sim_control
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
4. Tap **Start Listening** and speak a high-level robot command.
5. Tap **Stop Listening**.
6. Edit or verify the recognized text.
7. Tap **Send**.

The app never auto-sends partial speech recognition results. Commands are only sent after the user taps **Send**.

The app also has fixed task-control buttons:

```text
Stop Task       sends STOP_CURRENT_TASK
Stop Subtask    sends STOP_CURRENT_SUBTASK
Pause Subtask   sends PAUSE_CURRENT_SUBTASK
```

The Jetson bridge publishes normal spoken tasks to `/scenario`. It publishes stop/pause controls to `/task_control`, and also publishes fallback preemption messages to `/current_subtask` and `/start_exploration=false` for currently deployed robot nodes.

## Network API

The iPhone sends commands to:

```text
POST http://JETSON_IP:8080/command
```

Request body:

```json
{
  "text": "start exploration and find the elevator",
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

The app receives status from:

```text
ws://JETSON_IP:8080/status
```

The bridge streams JSON-wrapped status messages from ROS 2. The `data` field can be a raw string or decoded JSON from the robot topic.

Example status WebSocket message from the Jetson bridge:

```json
{
  "type": "current_subtask",
  "topic": "/current_subtask",
  "timestamp": 123.0,
  "data": {
    "skill": "exploration"
  }
}
```

## ROS 2 Topics

Normal task topic published by the bridge:

```text
/scenario
std_msgs/msg/String
```

Control topic published by the bridge:

```text
/task_control
std_msgs/msg/String
```

Fallback preemption topics published by the bridge:

```text
/current_subtask
std_msgs/msg/String

/start_exploration
std_msgs/msg/Bool
```

Status topics consumed by the bridge:

```text
/current_subtask
/subtask_status
/task_planning
/sim_control
/task_status
std_msgs/msg/String
```

## Manual Tests

Test command publishing:

```bash
curl -X POST http://JETSON_IP:8080/command \
  -H "Content-Type: application/json" \
  -d '{"text":"start exploration and find the elevator","token":"2001","source":"iphone"}'
```

Watch the ROS 2 normal task topic:

```bash
ros2 topic echo /scenario
```

Publish fake robot status:

```bash
ros2 topic pub /task_status std_msgs/msg/String \
  "{data: '{\"state\":\"running\",\"skill\":\"exploration\",\"message\":\"Exploring hallway\",\"progress\":0.42}'}"
```

## Test Without ROS 2

For laptop or network testing only:

```bash
cd jetson_bridge
export ROBOT_BRIDGE_ALLOW_NO_ROS=true
python3 robot_bridge.py
```

In this mode the bridge accepts `/command` requests and supports WebSocket status testing, but it does not publish to ROS 2.

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
