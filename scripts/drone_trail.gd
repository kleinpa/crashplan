class_name DroneTrail extends MeshInstance3D

## Ribbon trail showing the drone's path through the world.
## Fades to nothing over TRAIL_DURATION seconds.
## Uses additive blending so it glows against dark surfaces.

const TRAIL_DURATION  := 60.0   # seconds until a sample fully fades
const FADE_IN_DELAY   :=  1.0   # seconds before a new sample starts becoming visible
const FADE_IN_TIME    :=  1.2   # seconds to ramp from invisible to full brightness
const SAMPLE_DIST     :=  0.3   # minimum metres between samples
const RIBBON_WIDTH    :=  0.45  # half-width of the ribbon in metres (0.9 m total)
const TRAIL_COLOR    := Color(0.45, 0.90, 1.0)   # bright cyan-white

var _points   : Array = []   # Array of {pos:Vector3, right:Vector3, age:float}
var _imesh    : ImmediateMesh
var _last_pos : Vector3
var _ready_ok := false


func _ready() -> void:
	top_level = true                          # stay in world space, ignore drone transform
	global_transform = Transform3D.IDENTITY

	_imesh = ImmediateMesh.new()
	mesh   = _imesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := StandardMaterial3D.new()
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode                  = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode            = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.blend_mode                 = BaseMaterial3D.BLEND_MODE_ADD
	material_override = mat


func _process(delta: float) -> void:
	var quad  : Node3D = get_parent()
	var pos   : Vector3 = quad.global_position
	var right : Vector3 = quad.global_basis.x

	# Skip first frame so _last_pos is valid
	if not _ready_ok:
		_last_pos = pos
		_ready_ok = true
		return

	# Record a new sample whenever the drone has moved far enough
	if pos.distance_squared_to(_last_pos) >= SAMPLE_DIST * SAMPLE_DIST:
		_points.append({ "pos": pos, "right": right, "age": 0.0 })
		_last_pos = pos

	# Age all samples; drop expired ones
	var i := 0
	while i < _points.size():
		_points[i].age += delta
		if _points[i].age >= TRAIL_DURATION:
			_points.remove_at(i)
		else:
			i += 1

	_rebuild()


func _rebuild() -> void:
	_imesh.clear_surfaces()
	if _points.size() < 2:
		return

	_imesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for pt in _points:
		# Delay, then fade in; quadratic fall-off toward the tail end
		var fade_in  : float = clampf((pt.age - FADE_IN_DELAY) / FADE_IN_TIME, 0.0, 1.0)
		var fade_out : float = pow(1.0 - pt.age / TRAIL_DURATION, 2.0)
		var fade     : float = fade_in * fade_out
		var col   : Color = Color(
			TRAIL_COLOR.r * fade,
			TRAIL_COLOR.g * fade,
			TRAIL_COLOR.b * fade,
			1.0   # alpha unused with additive blend — brightness drives visibility
		)
		_imesh.surface_set_color(col)
		_imesh.surface_add_vertex(pt.pos + pt.right * RIBBON_WIDTH)
		_imesh.surface_set_color(col)
		_imesh.surface_add_vertex(pt.pos - pt.right * RIBBON_WIDTH)
	_imesh.surface_end()
