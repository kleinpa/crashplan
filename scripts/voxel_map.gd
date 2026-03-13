class_name VoxelMap

## Sparse 3D grid of voxel types.
## Voxel (i, j, k) occupies world-space box:
##   [ORIGIN + (i,j,k)*SIZE  …  ORIGIN + (i+1,j+1,k+1)*SIZE]
## Centre = ORIGIN + (i+0.5, j+0.5, k+0.5) * SIZE

enum Type {
	EMPTY        = 0,
	FLOOR_DARK   = 1,  # beneath building footprints
	FLOOR_STREET = 2,  # open street
	FLOOR_CENTER = 3,  # centre-cross navigation guide (emissive)
	BLDG         = 4,  # building column, plain dark
	BLDG_CYAN    = 5,  # building column, lit cyan
	BLDG_ORANGE  = 6,  # building column, lit orange
	BLDG_WHITE   = 7,  # building column, lit white
	BOUNDARY     = 8,  # solid for face-culling only — produces no visual mesh
	WALL         = 9,  # arena boundary wall (visible)
	CEILING      = 10, # arena ceiling (visible, emissive)
}

## Size of one voxel in world units (cube: SIZE × SIZE × SIZE).
const SIZE   := 2.0
## World-space position of the corner of voxel (0, 0, 0).
const ORIGIN := Vector3(-126.0, 0.0, -126.0)

var _data: Dictionary = {}   # Vector3i -> int (Type)


func set_voxel(pos: Vector3i, type: int) -> void:
	if type == Type.EMPTY:
		_data.erase(pos)
	else:
		_data[pos] = type


func get_voxel(pos: Vector3i) -> int:
	return _data.get(pos, Type.EMPTY)


## World-space centre of voxel at integer coords pos.
func world_center(pos: Vector3i) -> Vector3:
	return ORIGIN + (Vector3(pos) + Vector3(0.5, 0.5, 0.5)) * SIZE


## Raw dictionary for iteration (do not mutate directly).
func all_voxels() -> Dictionary:
	return _data
