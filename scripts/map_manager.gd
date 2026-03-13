class_name MapManager extends Node3D

## Owns the currently loaded map and provides load/unload operations.
## Future: portal transitions between multiple maps.

signal map_loaded(map_node: Node3D)
signal map_unloaded

var _current_map : Node3D = null


## Load a pre-instantiated map node as the active map.
## Unloads the previous map first if one is active.
func load_map(map: Node3D) -> void:
	if _current_map != null:
		unload_map()
	_current_map = map
	add_child(map)
	map_loaded.emit(map)


## Remove and free the current map.
func unload_map() -> void:
	if _current_map == null:
		return
	remove_child(_current_map)
	_current_map.queue_free()
	_current_map = null
	map_unloaded.emit()


## The currently loaded map node, or null if none is active.
func get_current_map() -> Node3D:
	return _current_map
