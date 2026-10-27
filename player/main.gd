extends Control
## Player entry point (skeleton).
##
## For now it only shows a status line. The boot sequence will become:
## pick a game directory -> GamePackage scans/validates it -> ScriptVM starts
## at the sce entry label -> Stage/EmoteRenderer/Audio present the records.

@onready var _status: Label = $StatusLabel


func _ready() -> void:
	_status.text = "ANIM2rGodot player — skeleton\nEngine formats: see docs/ in the repository."
