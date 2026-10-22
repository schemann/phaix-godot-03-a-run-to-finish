extends Node3D

const Chain := preload("room_chain.gd")
const PlayerScene := preload("player.tscn")
const Room := preload("room.gd")

const SPAWN_DEPTH := 1.5 ## Metres inside room 0, so the capsule starts clear of the wall.

@export var chain_seed := 42

var chain: Chain
var rooms: Dictionary[int, Room] = {} ## The rooms that exist right now, by plan index.
var current := 0 ## Index of the room the player is in.
var player: CharacterBody3D

func _ready() -> void:
	player = PlayerScene.instantiate() as CharacterBody3D
	add_child(player)
	start()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("regenerate"):
		chain_seed += 1
		start()

## Room 0 only, its door closed, the player just inside.
func start() -> void:
	for room: Room in rooms.values():
		room.queue_free()
	rooms.clear()

	chain = Chain.new(chain_seed)
	current = 0
	_spawn_room(chain.next_plan())
	rooms[0].seal_entrance()
	player.global_transform = rooms[0].entrance.global_transform.translated_local(Vector3(0.0, 0.0, -SPAWN_DEPTH))
	player.velocity = Vector3.ZERO

func _spawn_room(plan: Chain.Plan) -> void:
	var room := Chain.SCENES[plan.type].instantiate() as Room
	room.transform = plan.transform
	add_child(room)
	rooms[plan.index] = room
	room.door.opened.connect(_on_door_opened.bind(plan.index))
	room.inside.body_entered.connect(_on_room_entered.bind(plan.index))

## A door starts to open: build what is behind it. Only the newest room's door asks for
## a new room, so walking back builds nothing.
func _on_door_opened(index: int) -> void:
	if index == chain.plans.size() - 1:
		_spawn_room(chain.next_plan())

## The player stepped into a room: close the door behind the player and forget the old rooms.
func _on_room_entered(_body: Node3D, index: int) -> void:
	if index <= current:
		return
	current = index
	rooms[current - 1].door.close()
	for old: int in rooms.keys():
		if old < current - 1:
			rooms[old].queue_free()
			rooms.erase(old)
