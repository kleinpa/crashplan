class_name DroneInput extends Node

## Abstract base class for drone control input.
## Subclass this to feed control commands from any source:
##   - ControllerInput  (physical gamepad — player-controlled drone)
##   - AutopilotInput   (AI / nav-mesh guided — NPC drone, same full physics)
##
## get_stick() returns Vector4(roll, pitch, yaw, throttle).
## roll/pitch/yaw are in [-1..1]; throttle is in [0..1].
## The Quadcopter physics model is identical regardless of input source.


## Current control commands. roll/pitch/yaw in [-1..1], throttle in [0..1].
func get_stick() -> Vector4:
	return Vector4.ZERO


## Whether this input source is available/connected.
## Gamepads: true when a controller is plugged in.
## Autopilots: always true.
func has_input() -> bool:
	return true


## Whether this input source has been activated and is producing data.
## Needed for the browser gamepad unlock flow; autopilots are always active.
func is_active() -> bool:
	return true
