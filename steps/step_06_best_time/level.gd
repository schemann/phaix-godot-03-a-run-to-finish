extends Node3D

enum State {
	READY, ## In room 0, the first door is closed.
	RUNNING, ## From the moment the first door opens.
	FINISHED, ## The player stands on the goal pad.
}

signal room_entered(index: int) ## The player is in this room. Also sent for room 0 when a run starts.
signal state_changed(state: State)

const BestTimes := preload("best_times.gd")
const Chain := preload("room_chain.gd")
const PlayerScene := preload("player.tscn")
const Room := preload("room.gd")

const SPAWN_DEPTH := 1.5 ## Metres inside room 0, so the capsule starts clear of the wall.

@export var chain_seed := 42
@export_range(1, 500) var goal_room := 20 ## The room the run ends in.
@export var save_path := "user://best_times.json" ## Tests and recordings point it at a temporary file.

var chain: Chain
var rooms: Dictionary[int, Room] = {} ## The rooms that exist right now, by plan index.
var current := 0 ## Index of the room the player is in.
var state := State.READY
var run_time := 0.0 ## Seconds of the run. Added up from the physics delta, never read from a clock.
var best_times: BestTimes
var new_best := false ## The run that just finished beat the best time of its seed.
var player: CharacterBody3D

func _ready() -> void:
	best_times = BestTimes.new(save_path)
	player = PlayerScene.instantiate() as CharacterBody3D
	add_child(player)
	start()

## R and N only pick the seed. Everything a run changes is reset in start(), nowhere else.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("regenerate"):
		start()
	elif event.is_action_pressed("next_seed"):
		chain_seed += 1
		start()

func _physics_process(delta: float) -> void:
	if state == State.RUNNING:
		run_time += delta

## A new run: the state, the clock, the counter, room 0 only with its door closed, the player just inside.
func start() -> void:
	for room: Room in rooms.values():
		room.queue_free()
	rooms.clear()

	chain = Chain.new(chain_seed, goal_room)
	current = 0
	run_time = 0.0
	new_best = false
	_spawn_room(chain.next_plan())
	rooms[0].seal_entrance()
	player.global_transform = rooms[0].entrance.global_transform.translated_local(Vector3(0.0, 0.0, -SPAWN_DEPTH))
	player.velocity = Vector3.ZERO
	room_entered.emit(current)
	_set_state(State.READY)

func _spawn_room(plan: Chain.Plan) -> void:
	var room := Chain.SCENES[plan.type].instantiate() as Room
	room.transform = plan.transform
	add_child(room)
	rooms[plan.index] = room
	if room.door != null: # the goal room has no door
		room.door.opened.connect(_on_door_opened.bind(plan.index))
	room.inside.body_entered.connect(_on_room_entered.bind(plan.index))
	if room.goal_pad != null:
		room.goal_pad.body_entered.connect(_on_goal_reached)

## A door starts to open: build what is behind it. Only the newest room's door asks for
## a new room, so walking back builds nothing.
func _on_door_opened(index: int) -> void:
	if state == State.READY:
		_set_state(State.RUNNING)
	if index == chain.plans.size() - 1:
		_spawn_room(chain.next_plan())

## The player stepped into a room: close the door behind the player and forget the old rooms.
func _on_room_entered(_body: Node3D, index: int) -> void:
	if index <= current:
		return
	current = index
	room_entered.emit(current)
	rooms[current - 1].door.close()
	for old: int in rooms.keys():
		if old < current - 1:
			rooms[old].queue_free()
			rooms.erase(old)

func _on_goal_reached(_body: Node3D) -> void:
	if state == State.RUNNING:
		new_best = best_times.submit(chain_seed, run_time)
		_set_state(State.FINISHED)

## The only place the state changes. What a state means for the player happens here.
func _set_state(new_state: State) -> void:
	state = new_state
	match state:
		State.READY:
			player.set_frozen(false)
		State.FINISHED:
			player.set_frozen(true)
	state_changed.emit(state)
