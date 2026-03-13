# crashplan

An arcade FPV quadcopter simulator set in an abstract neon cityscape. Fly through glowing hoops, weave between buildings, and push into the ceiling — all inside an enclosed 252×252m arena with a dark cyberpunk atmosphere.

## Controls

Requires a gamepad (Mode 2) — left stick throttle/yaw, right stick pitch/roll.

Hover throttle is around 62% stick. Stick center (50%) is not enough to ascend.

In a browser, press any button on the controller first to let the browser detect it.

### Controller support

Axis mapping is automatic based on USB vendor/product ID. Radiomaster Pocket (USB and Bluetooth ELRS) are pre-mapped. To add a new controller, connect it and read the `CONTROLLER  device=… id=…` line printed to the console — add the `vid:pid` to `_PROFILES_BY_VIDPID` in `scripts/controller_input.gd`.

## Running

Open the project in Godot 4.4+ and press F5, or play the web build directly in a browser.

Audio starts on first user interaction in the browser (AudioContext policy).

## Flight model

The quadcopter is a `CharacterBody3D` driven entirely by custom physics — no Godot RigidBody.

| Constant          | Value   | Description                             |
| ----------------- | ------- | --------------------------------------- |
| `THRUST_MAX`      | 42 N    | Peak thrust (~4.3× gravity)             |
| `MASS`            | 1 kg    | Quadcopter mass                         |
| `MAX_RATE`        | 360 °/s | Maximum rotation rate                   |
| `YAW_RATE_SCALE`  | 0.5     | Yaw is slower than roll/pitch           |
| `MOTOR_AUTHORITY` | 8       | Rate-tracking stiffness                 |
| `EXPO`            | 0.35    | Stick expo (0 = linear, 1 = full cubic) |

Thrust follows a cubic stick curve so the hover point sits at ~62% rather than center. Angular velocity is integrated in **body frame** (`dq/dt = ½ q ω`), matching real FC firmware (Betaflight etc.).

Wall collisions bounce with 35% energy retention and trigger a synthesized thud sound.

## Audio

All sound is synthesized in real time — no audio samples.

| Layer     | Description                                            |
| --------- | ------------------------------------------------------ |
| Motors    | Four sawtooth oscillators driven by per-motor X-frame mix — frequencies split apart on roll/pitch/yaw |
| Wash      | Band-pass filtered noise with blade-pass amplitude mod |
| Sub       | Low sine (55–95 Hz) that gives the soundscape weight   |
| Collision | One-shot pitch-dropped sine + LP noise transient       |
| Hoop ding | Three-harmonic bell (880/1320/1760 Hz) + woosh on pass |

All layers route to a "Quadcopter" bus: reverb → compressor → Master.

## World

All surfaces — floor, buildings, walls, and ceiling — are voxelised and share the same rendering and collision pipeline.

Hoop positions are generated procedurally from the street layout.
