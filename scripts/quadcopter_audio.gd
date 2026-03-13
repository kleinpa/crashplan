class_name QuadcopterAudio extends Node

## Real-time generative audio for the quadcopter.
##
## Five AudioStreamGenerator streams pushed every _process frame:
##   MOTORS  — four detuned sawtooth oscillators, LP-filtered to tame harshness.
##   WASH    — band-pass filtered noise with blade-pass AM.
##   SUB     — low sine wave (55-95 Hz) that gives the soundscape physical weight.
##   COL     — one-shot collision thud: pitch-dropped sine + LP noise transient.
##   HOOP    — two detuned sines, rising pitch+amplitude as hoop-field influence grows.
##
## All five route to a "Quadcopter" bus: reverb → compressor → Master.

# ── constants ────────────────────────────────────────────────────────────────

const MIX_RATE := 44100
const BUF_LEN  := 0.10     # seconds — 2× worst-case frame time at 20 fps
const BUS_NAME := "Quadcopter"

# Motor oscillators
const PITCH_MIN  := 700.0    # Hz — idle
const PITCH_MAX  := 3800.0   # Hz — full throttle (down from 4600 to reduce shrillness)
const SPEED_COEF := 0.45     # world-speed contribution (Hz per m/s)
const DETUNE     := [1.0000, 1.0130, 0.9875, 1.0215]

# Motor low-pass — rolls off harsh sawtooth harmonics above the cutoff.
# Rises slightly with throttle so power feels present without becoming shrill.
const MOTOR_LP_LO := 1200.0  # Hz at idle
const MOTOR_LP_HI := 1900.0  # Hz at full throttle

# Prop wash
const WASH_LP_LO := 140.0
const WASH_LP_HI := 800.0
const WASH_HP    := 70.0
const CHOP_LO    := 32.0
const CHOP_HI    := 72.0

# Sub-bass sine — not physically accurate, just gives the soundscape weight
const SUB_FREQ_LO := 55.0    # Hz at idle
const SUB_FREQ_HI := 95.0    # Hz at full throttle

# Collision thud
const COL_DUR       := 0.18   # seconds
const COL_THRESHOLD := 1.5    # m/s — ignore tiny nudges

# Hoop-field tone — two detuned sines, rising pitch + amplitude with influence
const HOOP_FREQ_LO  := 180.0  # Hz at field edge
const HOOP_FREQ_HI  := 580.0  # Hz at field centre (full influence)
const HOOP_LFO_RATE := 3.2    # Hz — slow shimmer wobble

# ── state ────────────────────────────────────────────────────────────────────

var _motor_phase    := [0.0, 0.0, 0.0, 0.0]
var _motor_lp       := 0.0                         # one-pole LP on summed motor output
var _motor_spd      := [0.0, 0.0, 0.0, 0.0]       # smoothed per-motor speed (0-1)
var _motor_spd_prev := [0.0, 0.0, 0.0, 0.0]       # previous frame, for intra-buffer lerp

var _wash_lp  := 0.0
var _wash_hp  := 0.0
var _chop_ph  := 0.0

var _sub_phase := 0.0

var _thr := 0.0
var _smooth_speed := 0.0   # low-pass filtered linear speed to avoid pitch spikes

var _audio_retry_t := 0.0   # cooldown so we don't spam play() every frame

var _motor_player : AudioStreamPlayer
var _wash_player  : AudioStreamPlayer
var _sub_player   : AudioStreamPlayer
var _col_player   : AudioStreamPlayer
var _hoop_player  : AudioStreamPlayer
var _motor_pb     : AudioStreamGeneratorPlayback
var _wash_pb      : AudioStreamGeneratorPlayback
var _sub_pb       : AudioStreamGeneratorPlayback
var _col_pb       : AudioStreamGeneratorPlayback
var _hoop_pb      : AudioStreamGeneratorPlayback

var _col_t   := -1.0   # seconds since collision trigger; -1 = inactive
var _col_amp := 0.0    # amplitude scaled from impact speed
var _col_ph  := 0.0    # thud sine phase
var _col_lp  := 0.0    # LP filter state for impact transient

var _hoop_inf    := 0.0   # smoothed hoop_influence (0-1)
var _hoop_phase  := 0.0   # fundamental oscillator phase
var _hoop_phase2 := 0.0   # detuned octave phase
var _hoop_lfo_ph := 0.0   # shimmer LFO phase


# ── setup ────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_ensure_bus()
	_motor_player = _make_player(-4.0)
	_wash_player  = _make_player(-11.0)
	_sub_player   = _make_player(-9.0)    # sub sits below the other layers
	_col_player   = _make_player(-14.0)   # collision thud — subtle
	_hoop_player  = _make_player(-16.0)   # hoop-field tone — quiet at field edge, swells to centre
	# Playback objects are obtained in _process so that browsers (which block
	# the AudioContext until the first user gesture) get a chance to unlock
	# audio before we call play() and grab the stream playback handles.


func _ensure_bus() -> void:
	if AudioServer.get_bus_index(BUS_NAME) != -1:
		return

	AudioServer.add_bus()
	var idx := AudioServer.get_bus_count() - 1
	AudioServer.set_bus_name(idx, BUS_NAME)
	AudioServer.set_bus_send(idx, "Master")

	var rev := AudioEffectReverb.new()
	rev.room_size = 0.28
	rev.damping   = 0.68
	rev.spread    = 0.90
	rev.dry       = 0.82
	rev.wet       = 0.18
	rev.hipass    = 0.05   # lowered so sub-bass gets a little room bloom
	AudioServer.add_bus_effect(idx, rev)

	var cmp := AudioEffectCompressor.new()
	cmp.threshold  = -12.0
	cmp.ratio      = 4.0
	cmp.attack_us  = 1500.0
	cmp.release_ms = 120.0
	AudioServer.add_bus_effect(idx, cmp)


func _make_player(db: float) -> AudioStreamPlayer:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate      = float(MIX_RATE)
	gen.buffer_length = BUF_LEN
	var p := AudioStreamPlayer.new()
	p.stream    = gen
	p.bus       = BUS_NAME
	p.volume_db = db
	add_child(p)
	return p


# ── per-frame update ─────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	# On browsers the AudioContext is locked until the first user gesture, so
	# play() called from _ready() silently fails. Retry each frame until all
	# four playback handles are valid.
	if not _motor_pb or not _wash_pb or not _sub_pb or not _col_pb or not _hoop_pb:
		_audio_retry_t -= delta
		if _audio_retry_t > 0.0:
			return
		_motor_player.play()
		_wash_player.play()
		_sub_player.play()
		_col_player.play()
		_hoop_player.play()
		_motor_pb = _motor_player.get_stream_playback() as AudioStreamGeneratorPlayback
		_wash_pb  = _wash_player.get_stream_playback()  as AudioStreamGeneratorPlayback
		_sub_pb   = _sub_player.get_stream_playback()   as AudioStreamGeneratorPlayback
		_col_pb   = _col_player.get_stream_playback()   as AudioStreamGeneratorPlayback
		_hoop_pb  = _hoop_player.get_stream_playback()  as AudioStreamGeneratorPlayback
		_audio_retry_t = 0.5   # wait 500 ms before next attempt
		return

	var quad      = get_parent()
	var speed     : float = (quad.linear_velocity  as Vector3).length()
	var ang_speed : float = (quad.angular_velocity as Vector3).length()
	_smooth_speed = lerpf(_smooth_speed, speed, 1.0 - exp(-delta / 0.05))
	_hoop_inf     = lerpf(_hoop_inf, float(quad.hoop_influence), 1.0 - exp(-delta / 0.08))

	# Smooth each motor speed independently
	for m in 4:
		var raw : float = float(quad.motor_speeds[m])
		var tc  : float = 0.020 if raw > _motor_spd[m] else 0.04   # fast attack, slow decay
		_motor_spd[m] = lerpf(_motor_spd[m], raw, 1.0 - exp(-delta / tc))

	# Average speed drives sub-bass, wash, and LP cutoff (they don't need per-motor detail)
	_thr = (_motor_spd[0] + _motor_spd[1] + _motor_spd[2] + _motor_spd[3]) * 0.25

	# Trigger collision sound when a wall hit is detected
	var impulse : float = quad.collision_impulse
	if impulse >= COL_THRESHOLD and _col_t < 0.0:
		_col_t   = 0.0
		_col_amp = clampf(impulse / 20.0, 0.15, 1.0)
		_col_ph  = 0.0
		_col_lp  = 0.0

	_fill_motors(_smooth_speed)
	_fill_wash(ang_speed)
	_fill_sub()
	_fill_collision()
	_fill_hoop()


# ── motor synthesis ───────────────────────────────────────────────────────────

func _fill_motors(speed: float) -> void:
	var n := _motor_pb.get_frames_available()
	if n == 0:
		return

	var step  := TAU / float(MIX_RATE)
	var lp_a  := 1.0 - exp(-TAU * lerpf(MOTOR_LP_LO, MOTOR_LP_HI, _thr) / float(MIX_RATE))
	var inv_n := 1.0 / float(max(n, 1))

	for i in n:
		var t := float(i) * inv_n
		var s := 0.0
		for m in 4:
			# Interpolate this motor's speed across the buffer to avoid scratchiness
			var spd  : float = lerpf(float(_motor_spd_prev[m]), float(_motor_spd[m]), t)
			var freq : float = (lerpf(PITCH_MIN, PITCH_MAX, sqrt(maxf(spd, 0.0))) + speed * SPEED_COEF) * float(DETUNE[m])
			var amp  : float = sqrt(maxf(spd, 0.0)) * 0.27
			s += (2.0 * (_motor_phase[m] / TAU) - 1.0) * amp   # sawtooth × per-motor amp
			_motor_phase[m] = fmod(_motor_phase[m] + freq * step, TAU)
		s *= 0.25   # average 4 motors

		_motor_lp = _motor_lp + lp_a * (s - _motor_lp)
		_motor_pb.push_frame(Vector2(_motor_lp, _motor_lp))

	for m in 4:
		_motor_spd_prev[m] = _motor_spd[m]


# ── prop-wash synthesis ───────────────────────────────────────────────────────

func _fill_wash(ang_speed: float) -> void:
	var n := _wash_pb.get_frames_available()
	if n == 0:
		return

	var amp := clampf(
		_thr * 0.50 + ang_speed * 0.020,
		0.0, 1.0
	) * 0.40

	var lp_cut   := lerpf(WASH_LP_LO, WASH_LP_HI, _thr)
	var lp_a     := 1.0 - exp(-TAU * lp_cut / float(MIX_RATE))
	var hp_a     := exp(-TAU * WASH_HP / float(MIX_RATE))
	var chop_frq := lerpf(CHOP_LO, CHOP_HI, _thr) + ang_speed * 1.5
	var chop_stp := chop_frq * TAU / float(MIX_RATE)

	for _i in n:
		_wash_lp   = _wash_lp + lp_a * ((randf() * 2.0 - 1.0) - _wash_lp)
		var hp_out := _wash_lp - _wash_hp
		_wash_hp   = _wash_lp - hp_out * hp_a

		var chop := 0.62 + 0.38 * sin(_chop_ph)
		_chop_ph  = fmod(_chop_ph + chop_stp, TAU)

		_wash_pb.push_frame(Vector2(hp_out * amp * chop, hp_out * amp * chop))


# ── sub-bass synthesis ────────────────────────────────────────────────────────

func _fill_sub() -> void:
	var n := _sub_pb.get_frames_available()
	if n == 0:
		return

	# Frequency tracks throttle; amplitude uses a slower swell so the sub
	# doesn't punch as hard as the motors on fast inputs — it blooms instead.
	var freq := lerpf(SUB_FREQ_LO, SUB_FREQ_HI, _thr)
	var amp  := pow(maxf(_thr, 0.0), 0.6) * 0.55   # softer curve than motors
	var step := freq * TAU / float(MIX_RATE)

	for _i in n:
		var s := sin(_sub_phase) * amp
		_sub_phase = fmod(_sub_phase + step, TAU)
		_sub_pb.push_frame(Vector2(s, s))


# ── collision thud synthesis ──────────────────────────────────────────────────

func _fill_collision() -> void:
	var n := _col_pb.get_frames_available()
	if n == 0:
		return

	var step  := TAU / float(MIX_RATE)
	var dt    := 1.0 / float(MIX_RATE)
	# LP coefficient for impact transient noise (constant per call)
	var lp_a  := 1.0 - exp(-TAU * 280.0 / float(MIX_RATE))

	for _i in n:
		var s := 0.0

		if _col_t >= 0.0 and _col_t < COL_DUR:
			var t := _col_t

			# Thud: sine with pitch bend 130→90 Hz over first 30 ms (gives weight)
			var freq := 90.0 + 40.0 * maxf(1.0 - t / 0.030, 0.0)
			s += sin(_col_ph) * exp(-t / 0.060) * 0.55
			_col_ph = fmod(_col_ph + freq * step, TAU)

			# Impact transient: LP-filtered noise, vanishes in ~18 ms
			_col_lp = _col_lp + lp_a * ((randf() * 2.0 - 1.0) - _col_lp)
			s += _col_lp * exp(-t / 0.018) * 0.40

			s = clampf(s * _col_amp, -1.0, 1.0)
			_col_t += dt
			if _col_t >= COL_DUR:
				_col_t = -1.0

		_col_pb.push_frame(Vector2(s, s))


# ── hoop-field tone synthesis ─────────────────────────────────────────────────

func _fill_hoop() -> void:
	var n := _hoop_pb.get_frames_available()
	if n == 0:
		return

	# Frequency and amplitude both rise with influence — pitch focuses the pull,
	# amplitude tells the pilot how strong it is.
	var freq  := lerpf(HOOP_FREQ_LO, HOOP_FREQ_HI, _hoop_inf)
	var amp   := _hoop_inf * 0.55

	var step  := freq * TAU / float(MIX_RATE)
	var step2 := freq * 2.007 * TAU / float(MIX_RATE)   # detuned octave for shimmer
	var lfo_s := HOOP_LFO_RATE * TAU / float(MIX_RATE)

	for _i in n:
		# Slow LFO adds a gentle wobble so the tone feels alive rather than static.
		var lfo := 0.72 + 0.28 * sin(_hoop_lfo_ph)
		_hoop_lfo_ph = fmod(_hoop_lfo_ph + lfo_s, TAU)

		var s := (sin(_hoop_phase) * 0.65 + sin(_hoop_phase2) * 0.35) * amp * lfo
		_hoop_phase  = fmod(_hoop_phase  + step,  TAU)
		_hoop_phase2 = fmod(_hoop_phase2 + step2, TAU)
		_hoop_pb.push_frame(Vector2(s, s))
