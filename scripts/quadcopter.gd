extends CharacterBody3D

# --- Tuning ---
const MAX_RATE        := deg_to_rad(360.0)
const YAW_RATE_SCALE  := 0.5
const MOTOR_AUTHORITY    := 8.0
const K_ANGULAR          := 0.18
const PROP_GYRO          := 0.0005
const HOOP_YAW_STRENGTH  := 3.0   # rad/s² — gentle yaw toward velocity when in hoop field

const THRUST_MAX      := 42.0
const MASS            := 1.0
const GRAVITY         := Vector3(0.0, -9.81, 0.0)
const K_DRAG_XZ       := 0.07
const K_DRAG_Y        := 0.04
const K_QUAD          := 0.009

var linear_velocity   := Vector3.ZERO
var angular_velocity  := Vector3.ZERO
var throttle          := 0.0               # raw stick value 0-1, read by QuadcopterAudio
var motor_speeds      := [0.0, 0.0, 0.0, 0.0]  # per-motor 0-1, X-frame mix, read by QuadcopterAudio
var is_grounded       := false             # true while in contact with floor (with grace period)
var collision_impulse := 0.0               # pre-bounce speed (m/s) on wall hit; zeroed each physics frame
var hoop_influence    := 0.0               # 0-1 strength from active HoopField; zeroed each physics frame, read by audio
var hoop_strength     := 0.0               # highest strength claimed this frame; HoopField uses to ensure only strongest wins

var _ground_timer    := 0.0   # seconds remaining in ground grace period
const _GROUND_GRACE  := 0.15  # stay grounded 150 ms after last floor contact

var _input          : DroneInput
var _active_regions : Array  # Array[SpecialRegion]


func enter_region(region: SpecialRegion) -> void:
	_active_regions.append(region)


func exit_region(region: SpecialRegion) -> void:
	_active_regions.erase(region)


func _ready() -> void:
	add_to_group("drones")
	_input = ControllerInput.new()
	add_child(_input)
	add_child(QuadcopterAudio.new())
	add_child(DroneTrail.new())

	var hud := QuadcopterHUD.new()
	hud.name = "hud"
	hud.setup(_input)
	add_child(hud)


func _physics_process(delta: float) -> void:
	var stick := _input.get_stick()
	# When grounded, remap throttle so the spring-loaded centre (50%) = 0.
	# The stick must be pushed above 50% to generate any thrust, making
	# spring-centre controllers silent at rest without special audio muting.
	if is_grounded:
		# Remap throttle: values below GROUND_THR_FLOOR → 0, full stick → 1.
		# Floor is 0.60 so the Xbox spring-centre (~0.50 ± 0.05 drift) stays silent.
		const GROUND_THR_FLOOR := 0.60
		stick.w = clampf((stick.w - GROUND_THR_FLOOR) / (1.0 - GROUND_THR_FLOOR), 0.0, 1.0)
	_integrate_rotation(stick, delta)
	_integrate_position(stick, delta)


# ── rotation integration ───────────────────────────────────────────────────────

func _integrate_rotation(stick: Vector4, delta: float) -> void:
	var control_scale := 1.0
	for region: SpecialRegion in _active_regions:
		if region.region_type == SpecialRegion.Type.NO_THRUST:
			control_scale = 0.0

	var target_rate := Vector3(
		-stick.y * MAX_RATE,                  # pitch → X  (UP = nose down)
		 stick.z * MAX_RATE * YAW_RATE_SCALE, # yaw   → Y  (A  = yaw left)
		-stick.x * MAX_RATE                   # roll  → Z  (RIGHT = bank right)
	) * control_scale

	var torque := (target_rate - angular_velocity) * MOTOR_AUTHORITY
	torque += angular_velocity.cross(basis.y * PROP_GYRO)
	torque -= angular_velocity * K_ANGULAR
	angular_velocity += torque * delta

	# Hoop field: yaw toward velocity direction, scaled by field influence.
	# Uses the velocity XZ component so vertical passes don't spin the drone.
	if hoop_influence > 0.01:
		var vel_xz_sq := linear_velocity.x * linear_velocity.x + linear_velocity.z * linear_velocity.z
		if vel_xz_sq > 0.5:
			var vel_xz := Vector3(linear_velocity.x, 0.0, linear_velocity.z) / sqrt(vel_xz_sq)
			var fwd    := Vector3(-basis.z.x, 0.0, -basis.z.z)
			if fwd.length_squared() > 0.001:
				var yaw_err := fwd.normalized().cross(vel_xz).y   # sin of angle to target heading
				angular_velocity.y += yaw_err * hoop_influence * HOOP_YAW_STRENGTH * delta

	# Body-frame integration: dq/dt = ½ q ω_body  (rot * spin, not spin * rot)
	var rot  := Quaternion(basis)
	var spin := Quaternion(angular_velocity.x, angular_velocity.y, angular_velocity.z, 0.0)
	rot = (rot + rot * spin * 0.5 * delta).normalized()
	basis = Basis(rot)


# ── position integration ───────────────────────────────────────────────────────

func _integrate_position(stick: Vector4, delta: float) -> void:
	collision_impulse = 0.0
	hoop_influence    = 0.0
	hoop_strength     = 0.0

	var gravity      := GRAVITY
	var thrust_scale := 1.0
	for region: SpecialRegion in _active_regions:
		match region.region_type:
			SpecialRegion.Type.NEGATIVE_GRAVITY: gravity      = -GRAVITY
			SpecialRegion.Type.NO_THRUST:        thrust_scale = 0.0

	throttle    = stick.w * thrust_scale        # expose to audio (0 when coasting)
	var t       := stick.w * stick.w * stick.w * thrust_scale
	var thrust  := basis.y * t * THRUST_MAX

	# X-frame motor mix: FL, FR, RR, RL — differential drives per-motor audio pitch
	# pitch(+fwd), roll(+right), yaw(+left) each contribute ±MIX to individual motors
	const MIX := 0.25
	motor_speeds[0] = clampf(t + MIX * thrust_scale * ( stick.y - stick.x - stick.z), 0.0, 1.0)  # FL
	motor_speeds[1] = clampf(t + MIX * thrust_scale * ( stick.y + stick.x + stick.z), 0.0, 1.0)  # FR
	motor_speeds[2] = clampf(t + MIX * thrust_scale * (-stick.y + stick.x - stick.z), 0.0, 1.0)  # RR
	motor_speeds[3] = clampf(t + MIX * thrust_scale * (-stick.y - stick.x + stick.z), 0.0, 1.0)  # RL

	var vel_body  := basis.inverse() * linear_velocity
	var drag_body := Vector3(
		-vel_body.x * K_DRAG_XZ,
		-vel_body.y * K_DRAG_Y,
		-vel_body.z * K_DRAG_XZ
	)
	if vel_body.length_squared() > 0.001:
		drag_body -= vel_body.normalized() * vel_body.length_squared() * K_QUAD
	var drag := basis * drag_body

	linear_velocity += ((thrust + drag) / MASS + gravity) * delta

	_ground_timer = maxf(_ground_timer - delta, 0.0)
	var col := move_and_collide(linear_velocity * delta)
	if col:
		var n := col.get_normal()
		if n.y > 0.7:
			_ground_timer = _GROUND_GRACE
			# Floor contact: kill downward velocity, friction
			if linear_velocity.y < 0.0:
				collision_impulse = absf(linear_velocity.y)   # landing thud
				linear_velocity.y = 0.0
			linear_velocity.x *= 0.8
			linear_velocity.z *= 0.8
		else:
			# Wall / block: bounce
			collision_impulse = linear_velocity.length()   # capture speed before bounce
			linear_velocity = linear_velocity.bounce(n) * 0.35
			angular_velocity *= 0.6
	is_grounded = _ground_timer > 0.0
	if is_grounded:
		angular_velocity = angular_velocity.lerp(Vector3.ZERO, delta * 10.0)
		_upright(delta)


func _upright(delta: float) -> void:
	# Slerp toward level, preserving current yaw heading
	var back_xz := Vector3(basis.z.x, 0.0, basis.z.z)
	if back_xz.length_squared() < 0.001:
		back_xz = Vector3(0.0, 0.0, 1.0)
	back_xz = back_xz.normalized()
	var right_xz := Vector3.UP.cross(back_xz).normalized()
	var upright  := Basis(right_xz, Vector3.UP, back_xz)
	basis = basis.slerp(upright, delta * 10.0)
