extends CanvasLayer
## The on-screen display. It listens to the level's signals and never touches the game.

const Level := preload("level.gd")

@export var level: Level

@onready var room_label: Label = $Stats/RoomLabel

func _ready() -> void:
	level.room_entered.connect(_on_room_entered)
	_on_room_entered(level.current) # the level started before the HUD was ready

func _on_room_entered(index: int) -> void:
	room_label.text = "Room %d / %d" % [index, level.goal_room]
