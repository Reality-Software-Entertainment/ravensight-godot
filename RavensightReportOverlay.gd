## Add this optional CanvasLayer beside RavensightReports. Bind report_action in Input Map.
## open_report() also supports a pause-menu button. It never changes SceneTree.paused.
extends CanvasLayer

signal opened
signal closed
@export var transport_path: NodePath = NodePath("../RavensightReports")
@export var report_action: StringName = &"ravensight_report"
@export var enabled: bool = true
@export var tester_mode: bool = false
## Supply a Callable returning a redacted Image to choose another viewport or hide sensitive HUD.
var capture_callback: Callable
## Explicit developer-selected fields only. Never include secrets or unrestricted logs.
var context_provider: Callable
var _context: Dictionary = {}
var _captured_at: int = 0
var _image: Image
var _panel: PanelContainer
var _preview: TextureRect
var _message: TextEdit
var _expected: LineEdit
var _steps: TextEdit
var _frequency: LineEdit
var _category: OptionButton
var _notice: Label
var _send: Button
var _cancel: Button
var _text_only: Button
var _retry: Button
var _hide: CheckButton
var _dragging: bool = false
var _start: Vector2
var _mark: ColorRect
var _capture_pending: bool = false
var _submitting: bool = false

func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	var transport := get_node(transport_path)
	transport.report_submitted.connect(_submitted)
	transport.report_failed.connect(_failed)
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	var available := get_viewport().get_visible_rect().size
	_panel.size = Vector2(minf(680, available.x - 32), minf(740, available.y - 32))
	_panel.position = (available - _panel.size) / 2.0
	add_child(_panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var title := Label.new()
	title.text = "Report this moment"
	box.add_child(title)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(0, 280)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.gui_input.connect(_preview_input)
	box.add_child(_preview)
	_mark = ColorRect.new()
	_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mark.color = Color(1, 0.65, 0, 0.45)
	_preview.add_child(_mark)
	_hide = CheckButton.new()
	_hide.text = "Hide area instead of highlighting"
	box.add_child(_hide)
	_message = TextEdit.new()
	_message.placeholder_text = "What happened? (up to 500 characters)"
	_message.custom_minimum_size.y = 70
	box.add_child(_message)
	_category = OptionButton.new()
	for label in ["Other", "Bug", "Confusing", "Suggestion"]:
		_category.add_item(label)
	box.add_child(_category)
	_expected = LineEdit.new()
	_expected.placeholder_text = "Expected behavior"
	box.add_child(_expected)
	_steps = TextEdit.new()
	_steps.placeholder_text = "Steps to reproduce (optional)"
	_steps.custom_minimum_size.y = 45
	box.add_child(_steps)
	_frequency = LineEdit.new()
	_frequency.placeholder_text = "How often does it happen?"
	box.add_child(_frequency)
	_notice = Label.new()
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_notice)
	var actions := HBoxContainer.new()
	box.add_child(actions)
	_send = _button(actions, "Submit", _submit)
	_text_only = _button(actions, "Send text only", _without_image)
	_retry = _button(actions, "Retry", _retry_report)
	_cancel = _button(actions, "Cancel", _close)
	_panel.hide()

func _button(parent: Node, label: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _unhandled_input(event: InputEvent) -> void:
	if not enabled or _capture_pending or (event is InputEventKey and event.echo):
		return
	if InputMap.has_action(report_action) and event.is_action_pressed(report_action):
		var focus := get_viewport().gui_get_focus_owner()
		if focus is TextEdit or focus is LineEdit:
			return
		get_viewport().set_input_as_handled()
		open_report()

func open_report() -> void:
	if not enabled or _panel.visible or _capture_pending:
		return
	_capture_pending = true
	_captured_at = int(Time.get_unix_time_from_system())
	_context = context_provider.call() if context_provider.is_valid() else {}
	# The report UI is hidden until the gameplay frame has been copied.
	await RenderingServer.frame_post_draw
	_image = await capture_callback.call() if capture_callback.is_valid() else get_viewport().get_texture().get_image()
	_capture_pending = false
	_preview.texture = ImageTexture.create_from_image(_image) if _image != null and not _image.is_empty() else null
	_mark.hide()
	_message.text = ""
	_expected.text = ""
	_steps.text = ""
	_frequency.text = ""
	_expected.visible = tester_mode
	_steps.visible = tester_mode
	_frequency.visible = tester_mode
	_retry.hide()
	_set_busy(false)
	_notice.text = "Sends your message, optional screenshot, build, session and developer-selected context. No desktop capture."
	_panel.show()
	_message.grab_focus()
	opened.emit()

func _image_rect() -> Rect2:
	var dimensions := Vector2(_image.get_size())
	var scale := minf(_preview.size.x / dimensions.x, _preview.size.y / dimensions.y)
	var drawn := dimensions * scale
	return Rect2((_preview.size - drawn) / 2.0, drawn)

func _preview_input(event: InputEvent) -> void:
	if _image == null or _submitting:
		return
	var rect := _image_rect()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and rect.has_point(event.position):
			_start = event.position
			_dragging = true
		elif not event.pressed and _dragging:
			_dragging = false
			var end: Vector2 = event.position.clamp(rect.position, rect.end)
			var selection := Rect2(_start, end - _start).abs().intersection(rect)
			var scale: float = _image.get_width() / rect.size.x
			var pixels := Rect2i((selection.position - rect.position) * scale, selection.size * scale)
			if pixels.size.x > 0 and pixels.size.y > 0:
				if _hide.button_pressed:
					_image.fill_rect(pixels, Color.BLACK)
				else:
					_image.fill_rect(Rect2i(pixels.position, Vector2i(pixels.size.x, mini(4, pixels.size.y))), Color.ORANGE)
					_image.fill_rect(Rect2i(pixels.position, Vector2i(mini(4, pixels.size.x), pixels.size.y)), Color.ORANGE)
					_image.fill_rect(Rect2i(pixels.position + Vector2i(0, maxi(0, pixels.size.y - 4)), Vector2i(pixels.size.x, mini(4, pixels.size.y))), Color.ORANGE)
					_image.fill_rect(Rect2i(pixels.position + Vector2i(maxi(0, pixels.size.x - 4), 0), Vector2i(mini(4, pixels.size.x), pixels.size.y)), Color.ORANGE)
				_preview.texture = ImageTexture.create_from_image(_image)
			_mark.hide()
	if event is InputEventMouseMotion and _dragging:
		var selection := Rect2(_start, event.position.clamp(rect.position, rect.end) - _start).abs()
		_mark.position = selection.position
		_mark.size = selection.size
		_mark.show()

func _set_busy(value: bool) -> void:
	_submitting = value
	_send.disabled = value
	_cancel.disabled = value
	_text_only.disabled = value
	_retry.disabled = value

func _submit() -> void:
	if _message.text.strip_edges().is_empty() or _message.text.length() > 500:
		_notice.text = "Write a message between 1 and 500 characters."
		return
	_set_busy(true)
	_notice.text = "Submitting report..."
	var options := {"category": ["other", "bug", "complaint", "suggestion"][_category.selected], "context": _context, "capturedAt": _captured_at,
		"source": "tester" if tester_mode else "player", "expected": _expected.text, "steps": _steps.text, "frequency": _frequency.text}
	await get_node(transport_path).submit_report(_message.text, _image, options)

func _without_image() -> void:
	if _retry.visible:
		_set_busy(true)
		await get_node(transport_path).send_text_only()
	else:
		_image = null
		_preview.texture = null
		await _submit()

func _retry_report() -> void:
	_set_busy(true)
	await get_node(transport_path).retry_report()

func _failed(reason: String) -> void:
	_set_busy(false)
	_notice.text = reason
	_retry.show()
	# Editing the report after an uncertain network result could duplicate a paid submission.
	_send.disabled = true

func _submitted(_report_id: String) -> void:
	_set_busy(false)
	_close()

func _close() -> void:
	if _submitting:
		return
	get_node(transport_path).discard_local()
	_image = null
	_preview.texture = null
	_panel.hide()
	closed.emit()
