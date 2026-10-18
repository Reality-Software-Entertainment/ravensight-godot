## Optional Player Reports transport. Add as a child of the Ravensight autoload.
## The publishable SDK session is used; no dashboard or storage secret belongs here.
extends Node

signal report_submitted(report_id: String)
signal report_failed(reason: String)

@export var sdk_path: NodePath = NodePath("..")
signal _transport_response(response: Array)
var _bound_session := ""
var _bound_device := ""
var _bound_endpoint := ""
var _busy: bool = false
var _retry_payload: Dictionary = {}
var _retry_image: PackedByteArray = PackedByteArray()
var _submission_id: String = ""

func _sdk() -> Node:
	return get_node_or_null(sdk_path)

## Longest a report waits for the SDK to open or refresh its session.
const SESSION_WAIT_SECONDS: float = 10.0

func _allowed() -> bool:
	var sdk: Node = _sdk()
	return sdk != null and sdk._is_active()

## True once the SDK holds an unexpired session. An expired or missing one is
## refreshed through the SDK's own session start (the same path track_event()
## uses), then waited on for up to SESSION_WAIT_SECONDS, so an expired token
## is never sent.
func _ensure_session() -> bool:
	var sdk: Node = _sdk()
	if sdk == null or not sdk._is_active():
		return false
	if sdk._is_session_valid():
		return true
	sdk._start_session()
	var waited := 0.0
	while waited < SESSION_WAIT_SECONDS:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if not sdk._is_active():
			return false
		if sdk._is_session_valid():
			return true
	return false

func _scope_ok() -> bool:
	var sdk := _sdk()
	return _allowed() and sdk.session_token == _bound_session and sdk.device_id == _bound_device and sdk.api_base() == _bound_endpoint

func _wire(method: String, path: String, headers: Array, body: Variant) -> Array:
	_sdk()._send(method, path, headers, body, func(code: int, response_headers: PackedStringArray, response_body: PackedByteArray) -> void:
		_transport_response.emit([code, response_headers, response_body]))
	return await _transport_response

func _request(method: HTTPClient.Method, path: String, data: Dictionary = {}) -> Dictionary:
	if not _scope_ok():
		return {"error": "Report session changed or tracking disabled. No new submission was made."}
	var method_name := "GET" if method == HTTPClient.METHOD_GET else ("DELETE" if method == HTTPClient.METHOD_DELETE else "POST")
	var response: Array = await _wire(method_name, "/reports" + path, _sdk()._session_headers(), JSON.stringify(data))
	if not _scope_ok():
		return {"error": "Report session changed or tracking disabled."}
	var parsed = JSON.parse_string(response[2].get_string_from_utf8())
	if not parsed is Dictionary:
		return {"error": "The report server could not be reached."}
	if response[0] < 200 or response[0] >= 300:
		return {"error": parsed.get("error", "Could not submit report.")}
	return parsed

func _upload(form: Dictionary, bytes: PackedByteArray) -> bool:
	if not _scope_ok() or not str(form.get("url", "")).begins_with("https://") or not form.get("fields") is Dictionary:
		return false
	var boundary := "ravensight" + Crypto.new().generate_random_bytes(12).hex_encode()
	var body := PackedByteArray()
	for field in form.fields:
		if not field is String or not form.fields[field] is String or field.contains("\r") or field.contains("\n") or field.contains('"'):
			return false
		body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % [boundary, field, form.fields[field]]).to_utf8_buffer())
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"screenshot\"\r\nContent-Type: application/octet-stream\r\n\r\n" % boundary).to_utf8_buffer())
	body.append_array(bytes)
	body.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())
	var response: Array = await _wire("POST", form.url, ["Content-Type: multipart/form-data; boundary=" + boundary], body)
	return _scope_ok() and response[0] >= 200 and response[0] < 300

## No image analysis runs here. The image must already contain any desired redactions.
## Context is developer-selected scalar data; never pass secrets, arbitrary logs or chat.
func submit_report(message: String, screenshot: Image = null, options: Dictionary = {}) -> void:
	if _busy:
		return
	_bound_session = ""
	_retry_payload = {"clientId": Crypto.new().generate_random_bytes(16).hex_encode(), "message": message,
		"category": options.get("category", "other"), "level": options.get("level", ""),
		"context": options.get("context", {}), "capturedAt": options.get("capturedAt", int(Time.get_unix_time_from_system())), "source": options.get("source", "player"),
		"expected": options.get("expected", ""), "steps": options.get("steps", ""), "frequency": options.get("frequency", "")}
	_retry_image = PackedByteArray()
	_submission_id = ""
	if screenshot != null and screenshot.is_empty():
		report_failed.emit("Screenshot is empty. No report was sent.")
		_retry_payload = {}
		return
	if screenshot != null:
		var image := screenshot.duplicate()
		image.convert(Image.FORMAT_RGB8)
		var scale := minf(1.0, 1600.0 / maxf(image.get_width(), image.get_height()))
		image.resize(maxi(1, int(image.get_width() * scale)), maxi(1, int(image.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
		_retry_image = image.save_jpg_to_buffer(0.78)
		if _retry_image.size() > 1000000:
			image.resize(maxi(1, image.get_width() / 2), maxi(1, image.get_height() / 2))
			_retry_image = image.save_jpg_to_buffer(0.65)
		if _retry_image.is_empty() or _retry_image.size() > 1000000:
			_retry_payload = {}
			report_failed.emit("Screenshot is too large. Send text only.")
			return
	if not _retry_image.is_empty():
		var hashing := HashingContext.new()
		hashing.start(HashingContext.HASH_SHA256)
		hashing.update(_retry_image)
		_retry_payload.merge({"image": true, "bytes": _retry_image.size(), "sha256": hashing.finish().hex_encode()})
	await retry_report()

## Same ID and payload are retained across retries. Never automatically create another paid upload.
func retry_report() -> void:
	if _busy or _retry_payload.is_empty():
		return
	_busy = true
	if _bound_session.is_empty():
		if not await _ensure_session():
			_finish_error("No session available.")
			return
		_bound_session = _sdk().session_token
		_bound_device = _sdk().device_id
		_bound_endpoint = _sdk().api_base()
	var result: Dictionary = await _request(HTTPClient.METHOD_POST, "", _retry_payload)
	if result.has("error"):
		_finish_error(result.error)
		return
	if not result.get("id") is String or not result.get("status") is String:
		_finish_error("Invalid report response.")
		return
	_submission_id = result.id
	if result.status == "pending":
		var form: Dictionary = await _request(HTTPClient.METHOD_POST, "/" + _submission_id + "/upload")
		if form.has("error") or not await _upload(form, _retry_image):
			_finish_error(form.get("error", "Screenshot upload failed. Retry or send text only."))
			return
		result = await _request(HTTPClient.METHOD_POST, "/" + _submission_id + "/finalize")
	for attempt in range(35):
		if result.has("error") or result.get("status") == "canceled":
			_finish_error(result.get("error", "Screenshot could not be saved. Send text only."))
			return
		if result.get("status") == "complete":
			_busy = false
			_retry_payload = {}
			_retry_image = PackedByteArray()
			report_submitted.emit(str(result.get("reportId", "")))
			return
		await get_tree().create_timer(2.0).timeout
		result = await _request(HTTPClient.METHOD_GET, "/" + _submission_id)
	_finish_error("Report is still processing. Retry to check its status.")

func _finish_error(reason: String) -> void:
	_busy = false
	report_failed.emit(reason)

## Cancel an incomplete upload before making the text-only submission, avoiding duplicate reports.
func send_text_only() -> void:
	if _busy or _retry_payload.is_empty():
		return
	if not _submission_id.is_empty():
		var result: Dictionary = await _request(HTTPClient.METHOD_DELETE, "/" + _submission_id)
		if result.has("error"):
			_finish_error(result.error)
			return
		if not result.get("canceled", false):
			var state: Dictionary = await _request(HTTPClient.METHOD_GET, "/" + _submission_id)
			if state.get("status") == "canceled":
				var text_data := _retry_payload.duplicate(true)
				await submit_report(text_data.message, null, text_data)
				return
			_finish_error(result.get("error", "Report may already be saved. Retry to check its status."))
			return
	var data := _retry_payload.duplicate(true)
	await submit_report(data.message, null, data)

func discard_local() -> void:
	if not _busy:
		_retry_payload = {}
		_retry_image = PackedByteArray()
