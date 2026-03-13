class_name ControllerInput extends DroneInput

## Reads a physical gamepad and returns a normalised stick Vector4(roll, pitch, yaw, throttle).
## Applies per-controller axis mapping, deadzone, and expo.
## Add as a child node; call get_stick() each physics frame.

const EXPO     := 0.35
const DEADZONE := 0.05

# ── profiles ──────────────────────────────────────────────────────────────────
# Keys: thr_axis, thr_scale, yaw_axis, yaw_scale, pit_axis, pit_scale,
#       rol_axis, rol_scale
# Axes: LEFT_X=0  LEFT_Y=1  RIGHT_X=2  RIGHT_Y=3
# Throttle is always remapped [-1..+1] → [0..1] after scaling.

const _PROFILE_DEFAULT := {
	name     = "default",
	thr_axis = 1, thr_scale = -1.0,   # LEFT_Y  — Xbox: up=-1, negate so throttle-up=+1
	yaw_axis = 0, yaw_scale = -1.0,   # LEFT_X
	pit_axis = 3, pit_scale = -1.0,   # RIGHT_Y
	rol_axis = 2, rol_scale =  1.0,   # RIGHT_X
}

const _PROFILE_RADIOMASTER_USB := {
	name     = "radiomaster_usb",
	thr_axis = 2, thr_scale =  1.0,
	yaw_axis = 3, yaw_scale = -1.0,
	pit_axis = 1, pit_scale =  1.0,
	rol_axis = 0, rol_scale =  1.0,
}

const _PROFILE_RADIOMASTER_BT := {
	name     = "radiomaster_bt",
	thr_axis = 3, thr_scale =  1.0,
	yaw_axis = 4, yaw_scale = -1.0,
	pit_axis = 1, pit_scale =  1.0,
	rol_axis = 0, rol_scale =  1.0,
}

# Maps "vid:pid" → profile.  VID and PID are lowercase hex, no leading zeros trimmed.
# To identify a new controller: connect it and read the printed "vid:pid" line.
const _PROFILES_BY_VIDPID := {
	"1209:4f54": _PROFILE_RADIOMASTER_USB,   # Radiomaster Pocket USB  (vendor 1209, product 4f54)
	"e502:bbab": _PROFILE_RADIOMASTER_BT,    # Radiomaster Pocket ELRS BT (vendor e502, product bbab)
}

var _profile      := _PROFILE_DEFAULT
var _active       := false   # true once any axis exceeds deadzone (browser requires user gesture)
var _focus_timer  := 0.0     # seconds until next canvas focus retry


func _ready() -> void:
	Input.joy_connection_changed.connect(_on_connected)


func _process(delta: float) -> void:
	# While waiting for browser to grant gamepad axis access, re-request canvas
	# focus every second.  A single focus() call in _on_connected can arrive
	# before the canvas is ready, or the user may have clicked away since then.
	if not _active and has_input() and OS.get_name() == "Web":
		_focus_timer -= delta
		if _focus_timer <= 0.0:
			_focus_timer = 1.0
			JavaScriptBridge.eval("document.querySelector('canvas').focus()")


func get_stick() -> Vector4:
	if Input.get_connected_joypads().is_empty():
		return Vector4.ZERO

	var p              := _profile
	var t_raw  : float = Input.get_joy_axis(0, p.thr_axis) * float(p.thr_scale)
	var throttle:float = clamp((t_raw + 1.0) * 0.5, 0.0, 1.0)
	var yaw   : float  = _expo(_dz(Input.get_joy_axis(0, p.yaw_axis) * float(p.yaw_scale)))
	var pitch : float  = _expo(_dz(Input.get_joy_axis(0, p.pit_axis) * float(p.pit_scale)))
	var roll  : float  = _expo(_dz(Input.get_joy_axis(0, p.rol_axis) * float(p.rol_scale)))

	# Any non-zero axis value confirms the browser has granted gamepad access.
	# Use a tiny epsilon rather than deadzone — we just need proof data is flowing.
	if not _active and (abs(throttle - 0.5) > 0.005 or abs(yaw) > 0.005 or abs(pitch) > 0.005 or abs(roll) > 0.005):
		_active = true

	return Vector4(roll, pitch, yaw, throttle)


func has_input() -> bool:
	return not Input.get_connected_joypads().is_empty()


func is_active() -> bool:
	return _active


# ── private ───────────────────────────────────────────────────────────────────

func _dz(v: float) -> float:
	if abs(v) < DEADZONE:
		return 0.0
	return sign(v) * (abs(v) - DEADZONE) / (1.0 - DEADZONE)


func _expo(v: float) -> float:
	return v * (1.0 - EXPO) + v * abs(v) * EXPO


# SDL2 GUID is 32 hex chars.  VID at bytes 4-5 (LE u16), PID at bytes 8-9 (LE u16).
# e.g. "030000005e040000a102000000010000" → vid="045e" pid="02a1" (Xbox 360)
static func _vid_pid_from_guid(guid: String) -> String:
	if guid.length() < 20:
		return ""
	var vid := (guid.substr(10, 2) + guid.substr(8,  2)).to_lower()
	var pid := (guid.substr(18, 2) + guid.substr(16, 2)).to_lower()
	return "%s:%s" % [vid, pid]


# Browser gamepad names embed the IDs: "Unknown Gamepad (Vendor: e502 Product: bbab)"
static func _vid_pid_from_name(name: String) -> String:
	var re := RegEx.new()
	re.compile(r"Vendor:\s*([0-9a-fA-F]+)\s+Product:\s*([0-9a-fA-F]+)")
	var m := re.search(name)
	if not m:
		return ""
	return "%s:%s" % [m.get_string(1).to_lower(), m.get_string(2).to_lower()]


func _on_connected(device: int, connected: bool) -> void:
	if not connected:
		if Input.get_connected_joypads().is_empty():
			_active = false
		return
	var name    := Input.get_joy_name(device)
	var key     := _vid_pid_from_guid(Input.get_joy_guid(device))
	if key.is_empty() or key == "0000:0000":
		key = _vid_pid_from_name(name)
	_profile = _PROFILES_BY_VIDPID.get(key, _PROFILE_DEFAULT)
	print("CONTROLLER  device=%d  id=%s  profile=%s  name=%s" % [
		device, key, _profile.name, name,
	])
	# Browsers require canvas focus before gamepad axes pass through.
	if OS.get_name() == "Web":
		JavaScriptBridge.eval("document.querySelector('canvas').focus()")
