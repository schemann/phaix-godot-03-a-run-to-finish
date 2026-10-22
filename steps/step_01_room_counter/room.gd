extends Node3D
## A room module: a CSG shell with two connection points and a door at the exit.

const Door := preload("door.gd")
const DoorScene := preload("door.tscn")

var door: Door

@onready var entrance: Marker3D = $Entrance
@onready var exit: Marker3D = $Exit
@onready var inside: Area3D = $Inside

func _ready() -> void:
	door = DoorScene.instantiate() as Door
	door.transform = exit.transform
	add_child(door)

## Room 0 has nothing behind it, so its entrance becomes a plain wall.
## A hidden cutter is ignored by the CSG shape, which closes the hole.
func seal_entrance() -> void:
	$Shell/WallEntrance/Opening.visible = false
