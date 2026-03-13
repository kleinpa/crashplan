class_name VoxelMesher

## Builds one face-culled ArrayMesh per renderable voxel type.
## A face is emitted only when the neighbouring voxel in that direction is EMPTY.
## BOUNDARY voxels count as solid for culling purposes but produce no mesh.

## Emit one quad to st if the face is exposed.
## dir:  neighbour offset to check.
## n:    outward face normal.
## p0-p3: quad corners in half-size (±1) units.
## Godot 4 (Vulkan) determines the front face via cross(v2-v0, v1-v0), so
## triangles are wound as (v0,v3,v2) then (v0,v2,v1) — giving the outward
## normal the correct sign for back-face culling.
static func _emit_face(
		st:         SurfaceTool,
		voxel_map:  VoxelMap,
		pos:        Vector3i,
		center:     Vector3,
		h:          float,
		dir:        Vector3i,
		n:          Vector3,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:

	if voxel_map.get_voxel(pos + dir) != VoxelMap.Type.EMPTY:
		return   # face hidden by solid neighbour

	var v0 := center + p0 * h
	var v1 := center + p1 * h
	var v2 := center + p2 * h
	var v3 := center + p3 * h

	# tri 1: v0, v3, v2
	st.set_normal(n); st.set_uv(Vector2(0.0, 0.0)); st.add_vertex(v0)
	st.set_normal(n); st.set_uv(Vector2(1.0, 0.0)); st.add_vertex(v3)
	st.set_normal(n); st.set_uv(Vector2(1.0, 1.0)); st.add_vertex(v2)

	# tri 2: v0, v2, v1
	st.set_normal(n); st.set_uv(Vector2(0.0, 0.0)); st.add_vertex(v0)
	st.set_normal(n); st.set_uv(Vector2(1.0, 1.0)); st.add_vertex(v2)
	st.set_normal(n); st.set_uv(Vector2(0.0, 1.0)); st.add_vertex(v1)


## Returns Dictionary[int type -> ArrayMesh], one mesh per renderable voxel type.
static func build(voxel_map: VoxelMap) -> Dictionary:
	var tools: Dictionary = {}   # int type -> SurfaceTool
	var h: float = VoxelMap.SIZE * 0.5

	for raw_pos in voxel_map.all_voxels():
		var pos    := Vector3i(raw_pos)          # explicit cast from Variant key
		var type   := voxel_map.get_voxel(pos)

		# BOUNDARY voxels are solid for culling but never produce geometry
		if type == VoxelMap.Type.EMPTY or type == VoxelMap.Type.BOUNDARY:
			continue

		if not tools.has(type):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			tools[type] = st

		var st:     SurfaceTool = tools[type]
		var center: Vector3     = voxel_map.world_center(pos)

		# Top    (+Y)  cross(p1-p0, p2-p0) = +Y ✓
		_emit_face(st, voxel_map, pos, center, h,
			Vector3i(0, 1, 0), Vector3(0.0, 1.0, 0.0),
			Vector3(-1.0, 1.0,-1.0), Vector3(-1.0, 1.0, 1.0),
			Vector3( 1.0, 1.0, 1.0), Vector3( 1.0, 1.0,-1.0))

		# Bottom (-Y)  cross = -Y ✓
		_emit_face(st, voxel_map, pos, center, h,
			Vector3i(0,-1, 0), Vector3(0.0,-1.0, 0.0),
			Vector3( 1.0,-1.0,-1.0), Vector3( 1.0,-1.0, 1.0),
			Vector3(-1.0,-1.0, 1.0), Vector3(-1.0,-1.0,-1.0))

		# Left   (-X)  cross = -X ✓
		_emit_face(st, voxel_map, pos, center, h,
			Vector3i(-1, 0, 0), Vector3(-1.0, 0.0, 0.0),
			Vector3(-1.0,-1.0, 1.0), Vector3(-1.0, 1.0, 1.0),
			Vector3(-1.0, 1.0,-1.0), Vector3(-1.0,-1.0,-1.0))

		# Right  (+X)  cross = +X ✓
		_emit_face(st, voxel_map, pos, center, h,
			Vector3i( 1, 0, 0), Vector3( 1.0, 0.0, 0.0),
			Vector3( 1.0,-1.0,-1.0), Vector3( 1.0, 1.0,-1.0),
			Vector3( 1.0, 1.0, 1.0), Vector3( 1.0,-1.0, 1.0))

		# Front  (-Z)  cross = -Z ✓
		_emit_face(st, voxel_map, pos, center, h,
			Vector3i(0, 0,-1), Vector3(0.0, 0.0,-1.0),
			Vector3(-1.0,-1.0,-1.0), Vector3(-1.0, 1.0,-1.0),
			Vector3( 1.0, 1.0,-1.0), Vector3( 1.0,-1.0,-1.0))

		# Back   (+Z)  cross = +Z ✓
		_emit_face(st, voxel_map, pos, center, h,
			Vector3i(0, 0, 1), Vector3(0.0, 0.0, 1.0),
			Vector3( 1.0,-1.0, 1.0), Vector3( 1.0, 1.0, 1.0),
			Vector3(-1.0, 1.0, 1.0), Vector3(-1.0,-1.0, 1.0))

	var result: Dictionary = {}
	for type in tools:
		var st: SurfaceTool = tools[type]
		st.index()
		result[type] = st.commit()
	return result
