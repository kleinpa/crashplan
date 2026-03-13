class_name CityMap extends Node3D

## Self-contained city map generator.
## Populates a VoxelMap with floor tiles, buildings, walls, and ceiling voxels,
## then builds visual MeshInstance3D nodes and collision StaticBody3D nodes.
## All surfaces — including walls and ceiling — go through the voxel pipeline,
## so future maps (e.g. caves) work identically by filling different voxel shapes.
##
## Voxel grid convention (matches VoxelMap):
##   ORIGIN = (-126, 0, -126),  SIZE = 2.0
##   centre(i,j,k) = ORIGIN + (i+0.5, j+0.5, k+0.5) * 2
##
## 5 building blocks per axis separated by 4 streets (16 world-units each):
##   Blocks : voxels [0-19], [28-45], [54-71], [80-97], [106-125]
##   Streets: voxels [20-27], [46-53], [72-79], [98-105]
## Column grid: [5,10,15, 31,36,41, 57,62,67, 83,88,93, 109,114,119]
## Street voxels use FLOOR_CENTER (white emissive) as navigation guides.

## City block types — the single driver of per-block geometry, regions, and hoops.
## To rearrange the city, edit _block_layout in _ready(); everything follows automatically.
enum BlockType {
	STANDARD,      # random buildings (standard and cutout variants)
	PLAZA,         # open spawn zone, no buildings
	DEAD_PLAZA,    # NO_THRUST region + floating hoops, no buildings
	UPSIDE_DOWN,   # NEGATIVE_GRAVITY region + buildings hanging from ceiling
	COOLING_TOWER, # single hyperboloid tower filling the block exactly
}

const _VOX       := VoxelMap.SIZE            # 2.0
const _HALF_W    := 126.0
const _HALF_D    := 126.0
const _ARENA_H   := 75.0

# City-grid voxel indices (i-axis and k-axis) — building column anchors.
const _GRID_VI          := [5, 10, 15, 31, 36, 41, 57, 62, 67, 83, 88, 93, 109, 114, 119]

# Building half-width in voxels (columns span ±BLD_R around each grid point).
const _BLD_R_VI         := 2

# Street bands: each starts at _STREET_VI_STARTS[n] and is _STREET_W_VI wide.
const _STREET_VI_STARTS := [20, 46, 72, 98]
const _STREET_W_VI      := 8

# Arena extents in voxels: i,k in [0..125], j in [0..33]
const _VI_XZ     := 126
const _VI_Y      := 34   # 68 m total height

@export var city_seed: int = 42

var _voxel_map:       VoxelMap
var _rng:             RandomNumberGenerator
var _col_data:        Array             # Array of {vi_x, vi_z, base_vi, height_vi}
var _hoop_transforms: Array[Transform3D]
var _nav_graph:       NavGraph
var _block_layout:    Array             # [xi][zi] → BlockType  (5×5 grid)
var _inv:             bool = false      # when true, _fill_column mirrors columns to ceiling


## All map data in one object: voxel grid, hoop transforms, nav graph.
func get_map_data() -> MapData:
	var data := MapData.new()
	data.voxel_map       = _voxel_map
	data.hoop_transforms = _hoop_transforms
	data.nav_graph       = _nav_graph
	return data


func _ready() -> void:
	_rng             = RandomNumberGenerator.new()
	_rng.seed        = city_seed
	_voxel_map       = VoxelMap.new()
	_col_data        = []
	_hoop_transforms = []

	# ── Block layout — edit here to rearrange the city ─────────────────────────
	# Rows = xi (x-axis block index 0–4), cols = zi (z-axis block index 0–4).
	const S  := BlockType.STANDARD
	const P  := BlockType.PLAZA
	const DP := BlockType.DEAD_PLAZA
	const UD := BlockType.UPSIDE_DOWN
	const CT := BlockType.COOLING_TOWER
	_block_layout = [
		[S,  S,  S,  S,  S ],  # xi=0
		[S,  CT, S,  UD, S ],  # xi=1  upside-down (gravity reversed, buildings on ceiling)
		[S,  S,  P,  S,  S ],  # xi=2  plaza (spawn centre)
		[S,  DP, S,  S,  S ],  # xi=3  dead plaza (NO_THRUST + hoops)
		[S,  S,  S,  S,  S],  # xi=4  cooling tower
	]
	# ───────────────────────────────────────────────────────────────────────────

	_fill_floor()
	_fill_buildings()
	_fill_cooling_tower()
	_fill_walls()
	_build_visual_nodes()
	_build_collision_nodes()
	_spawn_special_regions()
	_spawn_hoops()
	_spawn_lights()
	_nav_graph = _build_nav_graph()


# ── block helpers ─────────────────────────────────────────────────────────────

## Voxel-index range [start, end] for block n (0–4) along one axis.
func _block_vi_range(n: int) -> Vector2i:
	var s : int = 0 if n == 0 else _STREET_VI_STARTS[n - 1] + _STREET_W_VI
	var e : int = _VI_XZ - 1 if n == 4 else _STREET_VI_STARTS[n] - 1
	return Vector2i(s, e)


## World-space centre coordinate for block n along one axis.
## (ORIGIN.x == ORIGIN.z == -126, so this formula works for both X and Z.)
func _block_world_center(n: int) -> float:
	var r := _block_vi_range(n)
	return VoxelMap.ORIGIN.x + (float(r.x + r.y) * 0.5 + 0.5) * VoxelMap.SIZE


## World-space width (m) of block n along one axis.
func _block_world_size(n: int) -> float:
	var r := _block_vi_range(n)
	return float(r.y - r.x + 1) * VoxelMap.SIZE


# ── voxel fill ────────────────────────────────────────────────────────────────

func _fill_floor() -> void:
	for vi_x: int in _VI_XZ:
		for vi_z: int in _VI_XZ:
			var in_bx := false
			var in_bz := false
			for g: int in _GRID_VI:
				if abs(vi_x - g) <= _BLD_R_VI: in_bx = true
				if abs(vi_z - g) <= _BLD_R_VI: in_bz = true

			var in_zone     := in_bx and in_bz
			var in_street_x := false
			var in_street_z := false
			for s: int in _STREET_VI_STARTS:
				if vi_x >= s and vi_x < s + _STREET_W_VI: in_street_x = true
				if vi_z >= s and vi_z < s + _STREET_W_VI: in_street_z = true
			var on_street := in_street_x or in_street_z

			var type: int
			if in_zone:
				type = VoxelMap.Type.FLOOR_DARK
			elif on_street:
				type = VoxelMap.Type.FLOOR_CENTER   # white emissive street guides
			else:
				type = VoxelMap.Type.FLOOR_STREET

			_voxel_map.set_voxel(Vector3i(vi_x, 0, vi_z), type)


## Fill WALL voxels along all four arena sides (full height) and a CEILING layer.
func _fill_walls() -> void:
	for j: int in _VI_Y:
		for k: int in range(-1, _VI_XZ + 1):
			_voxel_map.set_voxel(Vector3i(-1,     j, k), VoxelMap.Type.WALL)
			_voxel_map.set_voxel(Vector3i(_VI_XZ, j, k), VoxelMap.Type.WALL)
	for j: int in _VI_Y:
		for i: int in _VI_XZ:
			_voxel_map.set_voxel(Vector3i(i, j, -1),     VoxelMap.Type.WALL)
			_voxel_map.set_voxel(Vector3i(i, j, _VI_XZ), VoxelMap.Type.WALL)
	for i: int in range(-1, _VI_XZ + 1):
		for k: int in range(-1, _VI_XZ + 1):
			_voxel_map.set_voxel(Vector3i(i, _VI_Y, k), VoxelMap.Type.CEILING)


## Place voxels for a single building column and record its collision entry.
## When _inv is true the column is mirrored to hang from the ceiling:
##   normal  →  j = base_vi … base_vi + height_vi − 1   (from floor)
##   inverted → j = _VI_Y − base_vi − height_vi … _VI_Y − base_vi − 1  (from ceiling)
func _fill_column(vi_x: int, vi_z: int, base_vi: int, height_vi: int, vtype: int) -> void:
	var bv := (_VI_Y - base_vi - height_vi) if _inv else base_vi
	for vj: int in range(bv, bv + height_vi):
		_voxel_map.set_voxel(Vector3i(vi_x, vj, vi_z), vtype)
	_col_data.append({vi_x = vi_x, vi_z = vi_z, base_vi = bv, height_vi = height_vi})


func _fill_buildings() -> void:
	for xi: int in 5:
		for zi: int in 5:
			match _block_layout[xi][zi]:
				BlockType.STANDARD:
					_fill_standard_block(xi, zi, false)
				BlockType.UPSIDE_DOWN:
					_fill_standard_block(xi, zi, true)


func _fill_standard_block(xi: int, zi: int, inverted: bool) -> void:
	var xr := _block_vi_range(xi)
	var zr := _block_vi_range(zi)
	var accent_types: Array[int] = [
		VoxelMap.Type.BLDG_CYAN,
		VoxelMap.Type.BLDG_ORANGE,
		VoxelMap.Type.BLDG_WHITE,
	]
	_inv = inverted
	for gx: int in _GRID_VI:
		if gx < xr.x or gx > xr.y:
			continue
		for gz: int in _GRID_VI:
			if gz < zr.x or gz > zr.y:
				continue
			if _rng.randf() < 0.25:
				continue   # 25 % vacancy
			var accent : int = accent_types[_rng.randi() % accent_types.size()]
			if _rng.randf() < 0.20:
				_fill_cutout_building(gx, gz, accent)
			else:
				_fill_standard_building(gx, gz, accent)
	_inv = false


# ── cooling tower ─────────────────────────────────────────────────────────────
# Hyperboloid shell placed in every COOLING_TOWER block in _block_layout.
# r(j) = r_waist * sqrt(1 + ((j − J_MID) / hyp_c)²)
# r_base fills the block (half-width − 0.5 margin). Lit BLDG_CYAN rings mark base, mid, and rim.

func _fill_cooling_tower() -> void:
	for xi: int in 5:
		for zi: int in 5:
			if _block_layout[xi][zi] == BlockType.COOLING_TOWER:
				_fill_cooling_tower_block(xi, zi)


func _fill_cooling_tower_block(xi: int, zi: int) -> void:
	var xr := _block_vi_range(xi)
	var zr := _block_vi_range(zi)
	var cx : float = (float(xr.x) + float(xr.y)) * 0.5
	var cz : float = (float(zr.x) + float(zr.y)) * 0.5

	# Scale tower to fill the block: r_base uses the full half-width
	var block_half := mini(xr.y - xr.x, zr.y - zr.x) / 2
	var r_base     : float = float(block_half) - 0.5
	var r_waist    : float = r_base * 0.70            # wider waist (70% of base)

	const TOWER_H : int   = 22    # voxel height (~44 m)
	const J_MID   : int   = 12    # waist at mid-height
	const WALL_T  : float = 1.0   # wall thickness (voxels)
	const EXIT_H  : int   = 4     # ground-exit height (voxels)

	# Lit ring heights: just above the ground exits, middle, rim
	var ring_js := [EXIT_H + 1, J_MID, TOWER_H]

	var hyp_c         := float(J_MID) / sqrt((r_base / r_waist) * (r_base / r_waist) - 1.0)
	var exit_half_ang := atan2(3.0, r_base)

	var col_ext : Dictionary = {}   # Vector2i → [j_min, j_max]

	for vi_x in range(xr.x, xr.y + 1):
		for vi_z in range(zr.x, zr.y + 1):
			var dx   : float = float(vi_x) - cx
			var dz   : float = float(vi_z) - cz
			var dist : float = sqrt(dx * dx + dz * dz)
			var ang  : float = fposmod(atan2(dz, dx), TAU)

			for j in range(1, TOWER_H + 1):
				var r_out : float = r_waist * sqrt(1.0 + pow(float(j - J_MID) / hyp_c, 2.0))
				var r_in  : float = r_out - WALL_T
				if dist < r_in or dist > r_out:
					continue

				if j <= EXIT_H:
					var is_exit := false
					for dir_a: float in [0.0, PI * 0.5, PI, PI * 1.5]:
						if absf(fposmod(ang - dir_a + PI, TAU) - PI) <= exit_half_ang:
							is_exit = true
							break
					if is_exit:
						continue

				var vtype : int = VoxelMap.Type.BLDG_CYAN if j in ring_js else VoxelMap.Type.BLDG
				_voxel_map.set_voxel(Vector3i(vi_x, j, vi_z), vtype)

				var key := Vector2i(vi_x, vi_z)
				if not col_ext.has(key):
					col_ext[key] = [j, j]
				else:
					if j < col_ext[key][0]: col_ext[key][0] = j
					if j > col_ext[key][1]: col_ext[key][1] = j

	for key: Vector2i in col_ext:
		var ext : Array = col_ext[key]
		_col_data.append({
			vi_x = key.x, vi_z = key.y,
			base_vi = ext[0], height_vi = ext[1] - ext[0] + 1
		})


# Irregular cluster of columns with height variation; 2 accent-coloured columns.
func _fill_standard_building(gx: int, gz: int, accent: int) -> void:
	var ncols  := _rng.randi_range(2, 5)
	var nrows  := _rng.randi_range(2, 5)
	var base_h := _rng.randi_range(2, int(_VI_Y * 0.78))
	var total  := ncols * nrows
	var lit_a  := _rng.randi() % total
	var lit_b  := (lit_a + 1 + _rng.randi() % (total - 1)) % total

	for vc: int in ncols:
		for vr: int in nrows:
			var idx   := vc * nrows + vr
			var col_h := _rng.randi_range(max(1, int(base_h * 0.35)), base_h)
			var vi_x  := gx + vc - (ncols - 1) / 2
			var vi_z  := gz + vr - (nrows - 1) / 2
			var vtype := accent if (idx == lit_a or idx == lit_b) else VoxelMap.Type.BLDG
			_fill_column(vi_x, vi_z, 1, col_h, vtype)


# Solid building with a flyable cutout zone.
# Base and cap are dark BLDG; the gap has 4 accent corner pillars, open air elsewhere.
func _fill_cutout_building(gx: int, gz: int, accent: int) -> void:
	const SIZE   := 2
	var cutout_h := _rng.randi_range(3, 5)
	var total_h  := _rng.randi_range(maxi(10, cutout_h + 6), int(_VI_Y * 0.90))
	var base_h   := _rng.randi_range(1, maxi(1, total_h - cutout_h - 3))

	var floor_j : int = base_h + 1
	var open_j0 : int = base_h + 2
	var open_j1 : int = base_h + cutout_h + 1
	var ceil_j  : int = base_h + cutout_h + 2
	var cap_j0  : int = base_h + cutout_h + 3

	for dx: int in range(-SIZE, SIZE + 1):
		for dz: int in range(-SIZE, SIZE + 1):
			var vi_x      := gx + dx
			var vi_z      := gz + dz
			var is_corner : bool = abs(dx) == SIZE and abs(dz) == SIZE

			_fill_column(vi_x, vi_z, 1,       base_h,                    VoxelMap.Type.BLDG)
			_fill_column(vi_x, vi_z, floor_j, 1,                          VoxelMap.Type.BLDG)
			if is_corner:
				_fill_column(vi_x, vi_z, open_j0, open_j1 - open_j0 + 1, accent)
			_fill_column(vi_x, vi_z, ceil_j,  1,                          VoxelMap.Type.BLDG)
			var cap_max := total_h - ceil_j
			if cap_max > 0:
				var col_cap := _rng.randi_range(maxi(1, cap_max / 2), cap_max)
				_fill_column(vi_x, vi_z, cap_j0, col_cap, VoxelMap.Type.BLDG)


# ── visual nodes ──────────────────────────────────────────────────────────────

func _make_material(type: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.roughness = 1.0
	match type:
		VoxelMap.Type.FLOOR_DARK:
			m.albedo_color = Color(0.09, 0.09, 0.12)
		VoxelMap.Type.FLOOR_STREET:
			m.albedo_color = Color(0.16, 0.17, 0.22)
		VoxelMap.Type.FLOOR_CENTER:
			m.albedo_color = Color(1.0, 1.0, 1.0)
			m.emission_enabled = true
			m.emission = Color(1.0, 1.0, 1.0)
			m.emission_energy_multiplier = 2.2
			m.roughness = 0.4
		VoxelMap.Type.BLDG:
			m.albedo_color = Color(0.07, 0.07, 0.10)
		VoxelMap.Type.BLDG_CYAN:
			m.albedo_color = Color(0.4, 0.92, 1.0) * 0.3
			m.emission_enabled = true
			m.emission = Color(0.4, 0.92, 1.0)
			m.emission_energy_multiplier = 2.5
			m.roughness = 0.4
		VoxelMap.Type.BLDG_ORANGE:
			m.albedo_color = Color(1.0, 0.42, 0.0) * 0.3
			m.emission_enabled = true
			m.emission = Color(1.0, 0.42, 0.0)
			m.emission_energy_multiplier = 2.5
			m.roughness = 0.4
		VoxelMap.Type.BLDG_WHITE:
			m.albedo_color = Color(1.0, 1.0, 1.0) * 0.3
			m.emission_enabled = true
			m.emission = Color(1.0, 1.0, 1.0)
			m.emission_energy_multiplier = 2.5
			m.roughness = 0.4
		VoxelMap.Type.WALL:
			m.albedo_color = Color(0.15, 0.16, 0.22)
		VoxelMap.Type.CEILING:
			m.albedo_color = Color(0.52, 0.58, 0.68)
			m.emission_enabled = true
			m.emission = Color(0.52, 0.58, 0.68)
			m.emission_energy_multiplier = 1.8
			m.roughness = 0.4
	return m


func _build_visual_nodes() -> void:
	var meshes: Dictionary = VoxelMesher.build(_voxel_map)
	for type: int in meshes:
		var mi := MeshInstance3D.new()
		mi.name = "VoxelMesh_%d" % type
		mi.mesh = meshes[type]
		mi.material_override = _make_material(type)
		add_child(mi)


# ── collision nodes ───────────────────────────────────────────────────────────

func _build_collision_nodes() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "FloorBody"
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(_HALF_W * 2.0, _VOX, _HALF_D * 2.0)
	var floor_cs := CollisionShape3D.new()
	floor_cs.shape    = floor_shape
	floor_cs.position = Vector3(0.0, _VOX * 0.5, 0.0)
	floor_body.add_child(floor_cs)
	add_child(floor_body)

	var bldg_body := StaticBody3D.new()
	bldg_body.name = "BuildingBody"
	for col in _col_data:
		var base_vi  : int   = col.base_vi
		var h_world  : float = float(col.height_vi) * _VOX
		var col_orig : Vector3 = _voxel_map.world_center(Vector3i(col.vi_x, 0, col.vi_z))
		var shape := BoxShape3D.new()
		shape.size = Vector3(_VOX, h_world, _VOX)
		var cs := CollisionShape3D.new()
		cs.shape    = shape
		cs.position = Vector3(col_orig.x, _VOX * float(base_vi) + h_world * 0.5, col_orig.z)
		bldg_body.add_child(cs)
	add_child(bldg_body)

	var wall_h    : float = float(_VI_Y) * _VOX
	var wall_span : float = _HALF_W * 2.0 + _VOX * 2.0
	var wall_cy   : float = wall_h * 0.5

	var boundary_body := StaticBody3D.new()
	boundary_body.name = "BoundaryBody"
	for desc in [
		[Vector3(_VOX, wall_h, wall_span), Vector3(-_HALF_W - _VOX * 0.5, wall_cy, 0.0)],
		[Vector3(_VOX, wall_h, wall_span), Vector3( _HALF_W + _VOX * 0.5, wall_cy, 0.0)],
		[Vector3(wall_span, wall_h, _VOX), Vector3(0.0, wall_cy, -_HALF_D - _VOX * 0.5)],
		[Vector3(wall_span, wall_h, _VOX), Vector3(0.0, wall_cy,  _HALF_D + _VOX * 0.5)],
		[Vector3(wall_span, _VOX, wall_span), Vector3(0.0, wall_h + _VOX * 0.5, 0.0)],
	]:
		var shape := BoxShape3D.new()
		shape.size = desc[0]
		var cs := CollisionShape3D.new()
		cs.shape    = shape
		cs.position = desc[1]
		boundary_body.add_child(cs)
	add_child(boundary_body)


# ── special regions ───────────────────────────────────────────────────────────

func _spawn_special_regions() -> void:
	for xi: int in 5:
		for zi: int in 5:
			match _block_layout[xi][zi]:
				BlockType.DEAD_PLAZA:
					_spawn_region(xi, zi, SpecialRegion.Type.NO_THRUST, 8.0)
				BlockType.UPSIDE_DOWN:
					_spawn_region(xi, zi, SpecialRegion.Type.NEGATIVE_GRAVITY, 0.0)


func _spawn_region(xi: int, zi: int, region_type: int, floor_y: float) -> void:
	var arena_h := float(_VI_Y) * _VOX
	var wy      := arena_h - floor_y
	var r       := SpecialRegion.new()
	r.region_type = region_type
	r.region_size = Vector3(_block_world_size(xi), wy, _block_world_size(zi))
	r.position    = Vector3(_block_world_center(xi), floor_y + wy * 0.5, _block_world_center(zi))
	add_child(r)


# ── hoops ─────────────────────────────────────────────────────────────────────

func _street_centers() -> Array[float]:
	var centers: Array[float] = []
	for s: int in _STREET_VI_STARTS:
		var vi_center := s + _STREET_W_VI / 2
		centers.append(VoxelMap.ORIGIN.x + (float(vi_center) + 0.5) * VoxelMap.SIZE)
	return centers


func _spawn_hoops() -> void:
	var hoop_audio := HoopAudio.new()
	add_child(hoop_audio)

	var rng := RandomNumberGenerator.new()
	rng.seed = city_seed ^ 0xBEEFCAFE

	var street_centers := _street_centers()

	var torus := TorusMesh.new()
	torus.inner_radius  = 1.8
	torus.outer_radius  = 2.2
	torus.rings         = 64
	torus.ring_segments = 32

	var hoop_mat := StandardMaterial3D.new()
	hoop_mat.albedo_color              = Color(0.4, 0.17, 0.0)
	hoop_mat.emission_enabled          = true
	hoop_mat.emission                  = Color(1.0, 0.42, 0.0)
	hoop_mat.emission_energy_multiplier = 3.0
	hoop_mat.roughness                 = 0.5

	var cyl := CylinderShape3D.new()
	cyl.height = 1.5
	cyl.radius = 1.6

	const CORRIDOR_MIN       := -100.0
	const CORRIDOR_MAX       :=  100.0
	const HEIGHT_LO          :=  4.5
	const HEIGHT_HI          := 24.0
	const HOOPS_PER_CORRIDOR := 3

	for sx: float in street_centers:
		for _i in HOOPS_PER_CORRIDOR:
			_add_hoop(Vector3(sx, rng.randf_range(HEIGHT_LO, HEIGHT_HI),
					rng.randf_range(CORRIDOR_MIN, CORRIDOR_MAX)),
					0.0, torus, hoop_mat, cyl, hoop_audio)

	for sz: float in street_centers:
		for _i in HOOPS_PER_CORRIDOR:
			_add_hoop(Vector3(rng.randf_range(CORRIDOR_MIN, CORRIDOR_MAX),
					rng.randf_range(HEIGHT_LO, HEIGHT_HI), sz),
					90.0, torus, hoop_mat, cyl, hoop_audio)

	for sx: float in street_centers:
		for sz: float in street_centers:
			if rng.randf() < 0.5:
				_add_hoop(Vector3(sx, rng.randf_range(HEIGHT_LO, HEIGHT_HI), sz),
						0.0 if rng.randf() < 0.5 else 90.0,
						torus, hoop_mat, cyl, hoop_audio)

	# Dead-plaza hoops: 3 road-aligned rings inside each DEAD_PLAZA block.
	for xi: int in 5:
		for zi: int in 5:
			if _block_layout[xi][zi] != BlockType.DEAD_PLAZA:
				continue
			var bx := _block_world_center(xi)
			var bz := _block_world_center(zi)
			_add_hoop(Vector3(bx,        14.0, bz - 8.0),  0.0, torus, hoop_mat, cyl, hoop_audio)
			_add_hoop(Vector3(bx + 8.0,  24.0, bz       ), 90.0, torus, hoop_mat, cyl, hoop_audio)
			_add_hoop(Vector3(bx - 6.0,  36.0, bz + 6.0),  0.0, torus, hoop_mat, cyl, hoop_audio)


func _add_hoop(pos: Vector3, y_rot_deg: float,
		torus: TorusMesh, mat: StandardMaterial3D,
		cyl: CylinderShape3D, audio: HoopAudio) -> void:
	_hoop_transforms.append(Transform3D(
		Basis.from_euler(Vector3(0.0, deg_to_rad(y_rot_deg), 0.0)), pos))

	var inst := MeshInstance3D.new()
	inst.mesh = torus
	inst.set_surface_override_material(0, mat.duplicate())
	inst.rotation_degrees.x = 90.0

	var cs := CollisionShape3D.new()
	cs.shape = cyl
	cs.rotation_degrees.x = 90.0
	var area := Area3D.new()
	area.add_child(cs)
	area.body_entered.connect(audio.trigger)

	var field := HoopField.new()
	field.set_mesh_instance(inst)
	area.body_entered.connect(field.apply_alignment)

	var node := Node3D.new()
	node.position = pos
	node.rotation_degrees.y = y_rot_deg
	node.add_child(inst)
	node.add_child(area)
	node.add_child(field)
	add_child(node)


# ── nav graph ─────────────────────────────────────────────────────────────────

func _build_nav_graph() -> NavGraph:
	var graph   := NavGraph.new()
	var centers := _street_centers()
	var n       := centers.size()
	var height  := _ARENA_H * 0.3

	for xi: int in n:
		for zi: int in n:
			graph.nodes.append(Vector3(centers[xi], height, centers[zi]))

	for xi: int in n:
		for zi: int in n - 1:
			graph.edges.append(Vector2i(xi * n + zi, xi * n + zi + 1))

	for xi: int in n - 1:
		for zi: int in n:
			graph.edges.append(Vector2i(xi * n + zi, (xi + 1) * n + zi))

	return graph


# ── atmosphere lights ─────────────────────────────────────────────────────────

func _spawn_lights() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = city_seed ^ 0xDEAD1337

	var colors: Array[Color] = [
		Color(0.0, 0.85, 1.0),
		Color(0.0, 0.85, 1.0),
		Color(1.0, 0.42, 0.0),
		Color(1.0, 1.0,  1.0),
	]

	for i: int in 16:
		var light := OmniLight3D.new()
		light.light_color    = colors[i % colors.size()]
		light.light_energy   = 1.8
		light.omni_range     = 22.0
		light.shadow_enabled = false
		light.position = Vector3(
			rng.randf_range(-110.0, 110.0),
			rng.randf_range(  3.0,  20.0),
			rng.randf_range(-110.0, 110.0)
		)
		add_child(light)
