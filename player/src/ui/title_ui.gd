class_name TitleUI
extends CanvasLayer
## Asset-driven title screen replicating the original engine's main
## menu. pMenu.gax is the complete baked background (paper texture,
## key visual and logo in one image); pMenuButton.gax is a cell sheet
## holding every menu item in a normal (brown) and a hover (gold)
## state. The engine only places cells and swaps states - nothing is
## redrawn.
##
## Cell rects and screen positions were measured pixel-exact against
## the original running under Wine (template match on ink pixels,
## mean difference 0.0): cells sit on a 66 px row pitch in the sheet
## (gold = normal + 66 y), items on an 80 px pitch on screen.

signal start_story
signal load_save
signal open_extra
signal open_config
signal open_volume
signal open_flow

const GOLD_DY := 66
const ITEMS: Array = [
	# id, normal-state cell in pMenuButton sheet, screen position
	["new_game", Rect2i(2, 2, 328, 64), Vector2(40, 48)],
	["continue", Rect2i(332, 2, 328, 64), Vector2(40, 128)],
	["config", Rect2i(662, 2, 280, 64), Vector2(89, 208)],
	["volume", Rect2i(2, 134, 280, 64), Vector2(89, 288)],
	["extra", Rect2i(284, 134, 264, 64), Vector2(140, 368)],
	["flow", Rect2i(550, 134, 264, 64), Vector2(140, 448)],
	["exit", Rect2i(816, 134, 184, 64), Vector2(70, 608)],
]

var _root: Control
var _exit_holder: Control
var _built := false


func _ready() -> void:
	layer = 60
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)


func is_open() -> bool:
	return _root.visible


func hide_all() -> void:
	_root.visible = false
	if _exit_holder != null:
		_exit_holder.visible = false


func _load_cropped(pkg: GamePackage, image_name: String) -> Texture2D:
	var bytes := pkg.image_bytes(image_name)
	if bytes.is_empty():
		push_warning("TitleUI: image not found: " + image_name)
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK or img.is_empty():
		push_warning("TitleUI: image decode failed: " + image_name)
		return null
	var used: Rect2i = img.get_used_rect()
	if used.size.x > 0 and used.size.y > 0 and used.size != img.get_size():
		img = img.get_region(used)
	return ImageTexture.create_from_image(img)


func _load_raw(pkg: GamePackage, image_name: String) -> Texture2D:
	var bytes := pkg.image_bytes(image_name)
	if bytes.is_empty():
		push_warning("TitleUI: image not found: " + image_name)
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK or img.is_empty():
		push_warning("TitleUI: image decode failed: " + image_name)
		return null
	return ImageTexture.create_from_image(img)


func show_title(pkg: GamePackage) -> void:
	if pkg.is_web():
		await pkg.ensure_image("pMenu")
		await pkg.ensure_image("pMenuButton")
	if not _built:
		_build(pkg)
	_root.visible = true


func _build(pkg: GamePackage) -> void:
	_built = true
	var bg_tex := _load_cropped(pkg, "pMenu")
	if bg_tex != null:
		var bg := TextureRect.new()
		bg.texture = bg_tex
		bg.position = Vector2.ZERO
		bg.stretch_mode = TextureRect.STRETCH_KEEP
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(bg)
	# The button sheet must stay uncropped: cell regions are in full
	# sheet coordinates (cropping to the used rect would shift them).
	var sheet_tex := _load_raw(pkg, "pMenuButton")
	if sheet_tex == null:
		return
	for item in ITEMS:
		var cell: Rect2i = item[1]
		var normal := AtlasTexture.new()
		normal.atlas = sheet_tex
		normal.region = Rect2(cell)
		var gold_cell := cell
		gold_cell.position.y += GOLD_DY
		var gold := AtlasTexture.new()
		gold.atlas = sheet_tex
		gold.region = Rect2(gold_cell)
		var b := TextureButton.new()
		b.texture_normal = normal
		b.texture_hover = gold
		b.texture_pressed = gold
		b.position = item[2]
		b.size = Vector2(cell.size)
		b.stretch_mode = TextureButton.STRETCH_KEEP
		var id: String = item[0]
		b.pressed.connect(func() -> void: _on_item(id))
		_root.add_child(b)
	_build_exit_dialog()


func _on_item(id: String) -> void:
	match id:
		"new_game":
			start_story.emit()
		"continue":
			load_save.emit()
		"extra":
			open_extra.emit()
		"config":
			open_config.emit()
		"volume":
			open_volume.emit()
		"flow":
			open_flow.emit()
		"exit":
			_exit_holder.visible = true


## The original asks 「ゲームを終了します」 with はい / いいえ over the
## dimmed title art. The dialog's frame/flower decoration asset has
## not been identified yet; the panel uses the paper palette sampled
## from the sheets.
func _build_exit_dialog() -> void:
	_exit_holder = Control.new()
	_exit_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_exit_holder.visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_exit_holder.add_child(dim)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(500, 190)
	panel.position = Vector2(390, 265)
	panel.size = Vector2(500, 190)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.937, 0.906, 0.847)
	style.border_color = Color(0.36, 0.25, 0.16)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 30
	style.content_margin_right = 30
	style.content_margin_top = 28
	style.content_margin_bottom = 24
	panel.add_theme_stylebox_override("panel", style)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 26)
	panel.add_child(vbox)
	var label := Label.new()
	label.text = "ゲームを終了します"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	DialogueUI.apply_font(label, 26)
	label.add_theme_color_override("font_color", Color(0.36, 0.25, 0.16))
	vbox.add_child(label)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 60)
	vbox.add_child(row)
	var yes := Button.new()
	yes.text = "はい"
	yes.custom_minimum_size = Vector2(150, 52)
	DialogueUI.apply_font(yes, 22)
	yes.pressed.connect(func() -> void:
		if OS.has_feature("web"):
			_exit_holder.visible = false
		else:
			get_tree().quit())
	row.add_child(yes)
	var no := Button.new()
	no.text = "いいえ"
	no.custom_minimum_size = Vector2(150, 52)
	DialogueUI.apply_font(no, 22)
	no.pressed.connect(func() -> void: _exit_holder.visible = false)
	row.add_child(no)
	_exit_holder.add_child(panel)
	_root.add_child(_exit_holder)
