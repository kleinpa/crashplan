class_name NavGraph

## Navigable waypoint graph for autopilot path planning.
## nodes: world-space positions of each waypoint.
## edges: pairs of node indices (undirected).

var nodes: Array[Vector3] = []
var edges: Array[Vector2i] = []


## Build a MeshInstance3D that draws edges as glowing lines.
## Add it to the scene tree to visualise the graph in-world.
func create_debug_mesh() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	for edge: Vector2i in edges:
		st.add_vertex(nodes[edge.x])
		st.add_vertex(nodes[edge.y])

	var mat := StandardMaterial3D.new()
	mat.shading_mode             = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color             = Color(0.0, 1.0, 0.5)
	mat.emission_enabled         = true
	mat.emission                 = Color(0.0, 1.0, 0.5)
	mat.emission_energy_multiplier = 2.0

	var mi := MeshInstance3D.new()
	mi.name              = "NavGraphDebug"
	mi.mesh              = st.commit()
	mi.material_override = mat
	return mi
