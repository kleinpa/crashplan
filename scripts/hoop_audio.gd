class_name HoopAudio extends Node

## Generative audio triggered when a body passes through a hoop.
## Add as a child node; call trigger() from a hoop's body_entered signal.
##
## Sound layers:
##   DING  — three-harmonic A5/E6/A6 tone, exponential decay τ = 110 ms
##   WOOSH — LP-filtered noise with sweeping cutoff 900→0 Hz, τ = 55 ms

const _RATE := 44100
const _DUR  := 0.45   # seconds — sound is essentially gone by then anyway

var _t    := -1.0             # seconds since last trigger; -1 = inactive
var _ph   := [0.0, 0.0, 0.0] # phases for three ding harmonics
var _lp   := 0.0              # one-pole LP state for woosh noise
var _pb   : AudioStreamGeneratorPlayback
var _player : AudioStreamPlayer


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate      = float(_RATE)
	gen.buffer_length = 0.10
	_player = AudioStreamPlayer.new()
	_player.stream    = gen
	_player.bus       = "Quadcopter"   # shares reverb/compressor with quadcopter audio
	_player.volume_db = 3.0
	add_child(_player)
	# play() and get_stream_playback() are deferred to _process so browsers
	# can unlock the AudioContext via a user gesture first.


## Call (or connect body_entered) to start the ding/woosh sound.
func trigger(_body: Node3D = null) -> void:
	_t  = 0.0
	_ph = [0.0, 0.0, 0.0]
	_lp = 0.0


func _process(_delta: float) -> void:
	if not _pb:
		_player.play()
		_pb = _player.get_stream_playback() as AudioStreamGeneratorPlayback
		return
	var n := _pb.get_frames_available()
	if n == 0:
		return

	var step := TAU / float(_RATE)
	var dt   := 1.0 / float(_RATE)

	for _i in n:
		var s := 0.0

		if _t >= 0.0 and _t < _DUR:
			var t := _t

			# Ding — three harmonics: A5 (880 Hz), E6 (1320), A6 (1760)
			# Fast attack (implicit at t=0), exponential decay τ = 110 ms
			var da := exp(-t / 0.11) * 0.45
			s += (sin(_ph[0]) + 0.45 * sin(_ph[1]) + 0.20 * sin(_ph[2])) * da / 1.65
			_ph[0] = fmod(_ph[0] +  880.0 * step, TAU)
			_ph[1] = fmod(_ph[1] + 1320.0 * step, TAU)
			_ph[2] = fmod(_ph[2] + 1760.0 * step, TAU)

			# Woosh — LP-filtered white noise; cutoff sweeps 900→0 Hz, τ = 55 ms
			var cut := 900.0 * exp(-t / 0.055)
			var a   := 1.0 - exp(-TAU * cut / float(_RATE))
			_lp     = _lp + a * ((randf() * 2.0 - 1.0) - _lp)
			s += _lp * exp(-t / 0.055) * 0.32

			s = clampf(s, -1.0, 1.0)
			_t += dt
			if _t >= _DUR:
				_t = -1.0

		_pb.push_frame(Vector2(s, s))
