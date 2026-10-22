extends CanvasLayer
## The on-screen display. It listens to the level's signals and never touches the game.

const Level := preload("level.gd")

@export var level: Level

@onready var room_label: Label = $Stats/RoomLabel
@onready var finish_panel: PanelContainer = $FinishPanel

func _ready() -> void:
	level.room_entered.connect(_on_room_entered)
	level.state_changed.connect(_on_state_changed)
	_on_room_entered(level.current) # the level started before the HUD was ready
	_on_state_changed(level.state)

func _on_room_entered(index: int) -> void:
	room_label.text = "Room %d / %d" % [index, level.chain.goal_index]

func _on_state_changed(state: Level.State) -> void:
	finish_panel.visible = state == Level.State.FINISHED
