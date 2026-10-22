extends Node3D
## A hinged door. It swings away from the player who walks up to it.

signal opened ## Emitted as the door starts to swing open.

const OPEN_ANGLE := -PI / 2.0 ## Away from the player, into the next room.
const SWING_TIME := 0.5 ## Seconds.

var is_open := false

var _tween: Tween
var _sleep_steps := 2 ## Counts down before each physics step. At 0 the trigger wakes up.
var _close_pending := false

@onready var hinge: AnimatableBody3D = $Hinge
@onready var trigger: Area3D = $Trigger
@onready var swing: Area3D = $Swing ## Where the door sweeps through when it moves.

func _ready() -> void:
	trigger.body_entered.connect(_on_trigger_body_entered)

func _physics_process(_delta: float) -> void:
	# The trigger sleeps (monitoring is off in the scene) through the first physics step: Jolt moves a
	# player the level has just teleported during that step, so it still finds the player at the old
	# place. The count is 2 because it runs before each step: the trigger wakes up before the second.
	if _sleep_steps > 0:
		_sleep_steps -= 1
		if _sleep_steps == 0:
			trigger.monitoring = true
	# Never close on somebody: wait until nobody stands in the swing.
	if _close_pending and not swing.has_overlapping_bodies():
		_close_pending = false
		is_open = false
		_swing_to(0.0)

func open() -> void:
	_close_pending = false
	if is_open:
		return
	is_open = true
	_swing_to(OPEN_ANGLE)
	opened.emit()

## Closes as soon as the swing is free.
func close() -> void:
	_close_pending = true

func _swing_to(angle: float) -> void:
	if _tween != null:
		_tween.kill()
	# Physics process mode: the door's collider moves in step with the physics.
	_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_tween.tween_property(hinge, "rotation:y", angle, SWING_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _on_trigger_body_entered(_body: Node3D) -> void:
	open()
