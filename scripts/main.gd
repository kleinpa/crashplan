extends Node3D


func _ready() -> void:
	var map_manager := MapManager.new()
	map_manager.name = "MapManager"
	$World.add_child(map_manager)
	map_manager.load_map(CityMap.new())
