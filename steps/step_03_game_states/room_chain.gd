extends RefCounted
## The chain as data: one plan per room, made one at a time from a seed.
## It never touches the scene tree, so the same seed always gives the same chain.
## The room at goal_index is the goal room, the end of the run.

enum Type { STRAIGHT, LONG, TURN_LEFT, TURN_RIGHT, WIDE, GOAL }

const SCENES: Array[PackedScene] = [
	preload("room_straight.tscn"),
	preload("room_long.tscn"),
	preload("room_turn_left.tscn"),
	preload("room_turn_right.tscn"),
	preload("room_wide.tscn"),
	preload("room_goal.tscn"),
]
const START_HEADING := Vector3.FORWARD
const BACK_LIMIT := 0.05 ## How far a heading may lean back (0 = side on, 1 = straight back).
const SHRINK := 0.05 ## Metres. Rooms that only touch are not overlapping.

## What a room type is: its connection points and its box, in the room's own space.
class Module:
	var entrance: Transform3D
	var exit: Transform3D
	var bounds: AABB

## One room of the chain.
class Plan:
	var index: int
	var type: int
	var transform: Transform3D
	var bounds: AABB ## In world space.

	func _init(plan_index: int, plan_type: int, plan_transform: Transform3D, plan_bounds: AABB) -> void:
		index = plan_index
		type = plan_type
		transform = plan_transform
		bounds = plan_bounds

var plans: Array[Plan] = [] ## Every room made so far, also the ones long removed.
var goal_index: int ## The plan that becomes the goal room. It moves on by one for every room the goal had to wait.

var _rng := RandomNumberGenerator.new()
var _modules: Array[Module] = []

func _init(chain_seed: int, goal_room: int) -> void:
	_rng.seed = chain_seed
	goal_index = goal_room
	for scene in SCENES:
		_modules.append(_read_module(scene))

## Makes the next room. Call it in order: the plan list is the history.
func next_plan() -> Plan:
	if plans.is_empty():
		return _add(Type.STRAIGHT, Transform3D.IDENTITY)

	var last := plans[-1]
	var exit_point := last.transform * _modules[last.type].exit

	# The goal room is a dead end, so it only has to fit: no heading to test.
	if plans.size() == goal_index:
		var goal := _modules[Type.GOAL]
		var goal_placed := exit_point * goal.entrance.affine_inverse()
		if not _hits_history(goal_placed * goal.bounds):
			return _add(Type.GOAL, goal_placed)
		goal_index += 1 # no room for it here: an ordinary room now, the goal after that

	for type: int in _shuffled_types():
		var module := _modules[type]
		# Snap: the new room's entrance lands on the last room's exit.
		var placed := exit_point * module.entrance.affine_inverse()
		if _turns_back(placed, module.exit):
			continue # no U-turns
		if _hits_history(placed * module.bounds):
			continue # the room would run into an earlier one
		return _add(type, placed)

	push_error("room chain: no room type fits after room %d" % last.index)
	return _add(Type.STRAIGHT, exit_point * _modules[Type.STRAIGHT].entrance.affine_inverse())

## True if the room's exit would send the chain back: against the start heading, or towards the start room.
func _turns_back(placed: Transform3D, exit_local: Transform3D) -> bool:
	var heading := -(placed * exit_local).basis.z
	var to_start := (plans[0].transform.origin - placed.origin).normalized()
	return heading.dot(START_HEADING) < -BACK_LIMIT or heading.dot(to_start) > BACK_LIMIT

func _add(type: int, placed: Transform3D) -> Plan:
	var plan := Plan.new(plans.size(), type, placed, placed * _modules[type].bounds)
	plans.append(plan)
	return plan

func _hits_history(box: AABB) -> bool:
	var inner := box.grow(-SHRINK)
	for plan in plans:
		if inner.intersects(plan.bounds):
			return true
	return false

## Fisher-Yates with our own generator. Array.shuffle() would use the global one.
## The goal room is never drawn: it is only placed at goal_index.
func _shuffled_types() -> Array[int]:
	var types: Array[int] = []
	for type in range(Type.GOAL):
		types.append(type)
	for i in range(types.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var kept := types[i]
		types[i] = types[j]
		types[j] = kept
	return types

## Instancing a scene outside the tree is enough to read its markers and its box.
func _read_module(scene: PackedScene) -> Module:
	var room := scene.instantiate()
	var module := Module.new()
	module.entrance = (room.get_node("Entrance") as Marker3D).transform
	var exit_marker := room.get_node_or_null("Exit") as Marker3D # the goal room has none
	if exit_marker != null:
		module.exit = exit_marker.transform
	var shape := room.get_node("Inside/CollisionShape3D") as CollisionShape3D
	var box_size := (shape.shape as BoxShape3D).size
	module.bounds = shape.transform * AABB(-box_size / 2.0, box_size)
	room.free()
	return module
