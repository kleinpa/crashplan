class_name MapData

## All data produced by a map generator.
## Consumed by autopilots, HUD, and any other system that needs map knowledge.

## Sparse voxel grid — geometry, types, world coordinates.
var voxel_map: VoxelMap

## World-space transform of every hoop: position + facing (local -Z = approach direction).
var hoop_transforms: Array[Transform3D]

## Waypoint graph for nav-mesh / autopilot path planning.
var nav_graph: NavGraph
