class_name HoopField extends Area3D

## Magnetic approach funnel for a single hoop.
## Place as a child of the hoop Node3D — inherits the hoop's transform so
## global_basis.z is the through-axis.
##
## Forces applied each physics frame while a drone is in the funnel:
##   Radial  — spring force towards the through-axis line (corrects lateral offset).
##   Lateral — damps velocity perpendicular to through-axis (prevents spring oscillation).
##   Axial   — pushes drone along the through-axis towards and through the hoop.
##
## Only one hoop field affects a drone at a time (_active_claims mutex).
## Only applies while the drone is approaching the hoop plane from one side.

const HOOP_DIAMETER := 4.4
const FUNNEL_RADIUS := 30.0    # bounding sphere — effective range scales with speed below

const RANGE_SLOW      :=  8.0  # effective pull radius at low speed
const RANGE_FAST      := 28.0  # effective pull radius at high speed
const RANGE_SPEED_REF := 22.0  # m/s at which full range is reached

const CONE_DOT     := 0.643    # cos 50° — fixed half-angle
const APPROACH_MIN := 0.40     # min fraction of speed that must point toward hoop

const RADIAL_RATE  := 4.5   # target approach speed per meter of lateral offset (m/s per m)
const RADIAL_BLEND := 14.0  # how fast lateral velocity converges to target (per second, at full strength)
const AXIAL_STRENGTH  := 18.0  # base axial push through the hoop
const AXIAL_SPEED_REF :=  8.0  # m/s reference — slower drones get proportionally more push

const EMIT_IDLE   := 3.0
const EMIT_ACTIVE := 8.0

var _bodies: Array[Node3D] = []
var _mesh: MeshInstance3D


func set_mesh_instance(mi: MeshInstance3D) -> void:
	_mesh = mi


func _ready() -> void:
	var sphere := SphereShape3D.new()
	sphere.radius = FUNNEL_RADIUS
	var cs := CollisionShape3D.new()
	cs.shape = sphere
	add_child(cs)
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _physics_process(delta: float) -> void:
	var through     := global_basis.z
	var any_active  := false
	for body: Node3D in _bodies:
		if _apply_funnel(body, through, delta):
			any_active = true
	_set_highlight(any_active)


func _apply_funnel(body: Node3D, through: Vector3, delta: float) -> bool:
	var to_hoop    := global_position - body.global_position
	var axial_dist : float  = to_hoop.dot(through)

	# Don't act when the drone is right at the hoop plane.
	if absf(axial_dist) < 0.05:
		return false

	# Axial direction: from drone towards the hoop plane on its current side.
	var axial_dir : Vector3 = through * signf(axial_dist)

	# Radial: vector from drone to the nearest point on the through-axis line.
	var radial : Vector3 = to_hoop - through * axial_dist

	var dist := to_hoop.length()
	if dist < 0.01:
		return false

	# Speed-dependent range: fast drones are caught from much farther out.
	var speed      : float = body.linear_velocity.length()
	var eff_radius : float = lerpf(RANGE_SLOW, RANGE_FAST, clampf(speed / RANGE_SPEED_REF, 0.0, 1.0))
	if dist > eff_radius:
		return false

	# Fixed cone gate (~50°): approach must be mostly along the through-axis.
	if absf(axial_dist) / dist < CONE_DOT:
		return false

	# Approach gate: must be heading substantially toward the hoop, not just grazing.
	var vel_toward : float = body.linear_velocity.dot(axial_dir)
	if vel_toward <= 0.0:
		return false
	if speed > 0.5 and vel_toward / speed < APPROACH_MIN:
		return false

	var t        := 1.0 - clampf(dist / eff_radius, 0.0, 1.0)
	var strength := t * t

	# Yield to a closer/stronger hoop field that already acted this frame.
	if strength <= body.hoop_strength:
		return false
	body.hoop_strength  = strength
	body.hoop_influence = strength

	# Lateral correction: steer lateral velocity toward a target that shrinks
	# with remaining offset, so the drone decelerates naturally as it aligns.
	# No separate spring + damp → no oscillation.
	var vel_axial   : Vector3 = through * body.linear_velocity.dot(through)
	var vel_lateral : Vector3 = body.linear_velocity - vel_axial
	var radial_dist : float   = radial.length()
	var desired_lat : Vector3 = (radial / maxf(radial_dist, 0.001)) * radial_dist * RADIAL_RATE * strength
	var alpha       : float   = clampf(RADIAL_BLEND * strength * delta, 0.0, 1.0)
	body.linear_velocity += (desired_lat - vel_lateral) * alpha

	# Axial push: slower drones get more help getting through.
	var axial_boost : float = clampf(AXIAL_SPEED_REF / maxf(speed, 1.0), 0.5, 4.0)
	body.linear_velocity += axial_dir * AXIAL_STRENGTH * axial_boost * strength * delta
	return true


## Connect to the hoop's pass-through Area3D body_entered signal.
## Redirects the drone's velocity fully along the through-axis, preserving speed.
func apply_alignment(body: Node3D) -> void:
	if not body.is_in_group("drones"):
		return
	var through := global_basis.z
	var speed   : float = body.linear_velocity.length()
	if speed < 0.01:
		return
	var sign := signf(body.linear_velocity.dot(through))
	if sign == 0.0:
		sign = 1.0
	body.linear_velocity = through * sign * speed


func _set_highlight(active: bool) -> void:
	if _mesh == null:
		return
	var mat := _mesh.get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		return
	mat.emission_energy_multiplier = EMIT_ACTIVE if active else EMIT_IDLE


func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("drones"):
		return
	_bodies.append(body)


func _on_body_exited(body: Node3D) -> void:
	_bodies.erase(body)
