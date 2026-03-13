class_name SpecialRegion extends Area3D

## A world-space volume that modifies drone physics while the drone is inside.
## Spawn via code; set region_type and region_size before adding to the scene tree.

enum Type {
	NEGATIVE_GRAVITY,  # gravity acts upward
	NO_THRUST,         # throttle produces no thrust — coast only
}

var region_type : Type    = Type.NEGATIVE_GRAVITY
var region_size : Vector3 = Vector3(36.0, 56.0, 36.0)


func _ready() -> void:
	var box := BoxShape3D.new()
	box.size = region_size
	var cs := CollisionShape3D.new()
	cs.shape = box
	add_child(cs)

	var bm := BoxMesh.new()
	bm.size = region_size
	var mat := StandardMaterial3D.new()
	mat.transparency          = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode          = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode             = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode       = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.albedo_color          = _region_color()
	var mi := MeshInstance3D.new()
	mi.mesh              = bm
	mi.material_override = mat
	add_child(mi)

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _region_color() -> Color:
	match region_type:
		Type.NEGATIVE_GRAVITY: return Color(0.3, 0.5, 1.0, 0.13)
		Type.NO_THRUST:        return Color(1.0, 0.3, 0.1, 0.13)
	return Color(1.0, 1.0, 1.0, 0.10)


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("drones"):
		body.enter_region(self)


func _on_body_exited(body: Node3D) -> void:
	if body.is_in_group("drones"):
		body.exit_region(self)
