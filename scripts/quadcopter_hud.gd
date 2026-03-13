class_name QuadcopterHUD extends CanvasLayer

## On-screen display for the player's drone.
## Reads a DroneInput to show connection/activation prompts.
## Future instruments (velocity vector, altitude, nav overlay) go here.

var _input     : DroneInput
var _prompt    : Label
var _fps_label : Label


## Call before adding to the scene tree.
func setup(drone_input: DroneInput) -> void:
	_input = drone_input


func _ready() -> void:
	_prompt = Label.new()
	_prompt.text = "connect controller"
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_prompt.anchors_preset       = Control.PRESET_CENTER
	_prompt.add_theme_font_size_override("font_size", 52)
	_prompt.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.75))
	add_child(_prompt)

	_fps_label = Label.new()
	_fps_label.anchor_left   = 1.0
	_fps_label.anchor_top    = 0.0
	_fps_label.anchor_right  = 1.0
	_fps_label.anchor_bottom = 0.0
	_fps_label.offset_left   = -80.0
	_fps_label.offset_top    = 8.0
	_fps_label.offset_right  = -8.0
	_fps_label.offset_bottom = 28.0
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_label.add_theme_font_size_override("font_size", 12)
	_fps_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.35))
	add_child(_fps_label)


func _process(_delta: float) -> void:
	_fps_label.text = "%d fps" % Engine.get_frames_per_second()

	if _input == null:
		return
	if not _input.has_input():
		_prompt.text    = "connect controller"
		_prompt.visible = true
	elif not _input.is_active():
		_prompt.text    = "move a stick to activate"
		_prompt.visible = true
	else:
		_prompt.visible = false
