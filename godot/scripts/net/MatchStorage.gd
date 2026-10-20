class_name MatchStorage
extends RefCounted

## Storage abstraction. LocalStorageProvider writes
## user://matches/<match_id>/{metadata.json,metrics.csv,summary.json}
## and is the primary reliable copy. CloudStorageProvider is an explicit
## NOT-CONFIGURED stub: it never pretends to upload.

const BASE := "user://matches"

class Provider extends RefCounted:
	func save_match(_match_id: String, _meta: Dictionary, _csv: String, _summary: Dictionary) -> Dictionary:
		return {"ok": false, "error": "not implemented"}
	func list_matches() -> Array:
		return []
	func load_summary(_match_id: String) -> Dictionary:
		return {}
	func load_rows(_match_id: String) -> Array:
		return []

class LocalProvider extends Provider:
	func _dir(match_id: String) -> String:
		return "%s/%s" % [MatchStorage.BASE, match_id]

	func save_match(match_id: String, meta: Dictionary, csv: String, summary: Dictionary) -> Dictionary:
		var dir := _dir(match_id)
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			return {"ok": false, "error": "mkdir failed"}
		var ok := true
		ok = _write(dir + "/metadata.json", JSON.stringify(meta, "\t")) and ok
		ok = _write(dir + "/metrics.csv", csv) and ok
		ok = _write(dir + "/summary.json", JSON.stringify(summary, "\t")) and ok
		if not ok:
			return {"ok": false, "error": "write failed"}
		return {"ok": true, "path": ProjectSettings.globalize_path(dir)}

	func _write(path: String, text: String) -> bool:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return false
		f.store_string(text)
		f.close()
		return true

	func list_matches() -> Array:
		var out: Array = []
		var da := DirAccess.open(MatchStorage.BASE)
		if da == null:
			return out
		for d in da.get_directories():
			var s := load_summary(d)
			if not s.is_empty():
				out.append({"id": d, "summary": s})
		# newest first (ids embed timestamp)
		out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) > str(b["id"]))
		return out

	func load_summary(match_id: String) -> Dictionary:
		var f := FileAccess.open(_dir(match_id) + "/summary.json", FileAccess.READ)
		if f == null:
			return {}
		var v = JSON.parse_string(f.get_as_text())
		return v if v is Dictionary else {}

	func load_rows(match_id: String) -> Array:
		var f := FileAccess.open(_dir(match_id) + "/metrics.csv", FileAccess.READ)
		if f == null:
			return []
		var header := f.get_line().split(",")
		var rows: Array = []
		while not f.eof_reached():
			var line := f.get_line().strip_edges()
			if line == "":
				continue
			var cells := line.split(",")
			var r := {}
			for i in mini(header.size(), cells.size()):
				r[header[i]] = float(cells[i]) if cells[i].is_valid_float() else 0.0
			rows.append(r)
		return rows

	static func load_meta(match_id: String) -> Dictionary:
		var f := FileAccess.open("%s/%s/metadata.json" % [MatchStorage.BASE, match_id], FileAccess.READ)
		if f == null:
			return {}
		var v = JSON.parse_string(f.get_as_text())
		return v if v is Dictionary else {}

class CloudProvider extends Provider:
	# No backend configured. Never fake an upload.
	func save_match(_match_id: String, _meta: Dictionary, _csv: String, _summary: Dictionary) -> Dictionary:
		return {"ok": false, "error": "CLOUD NOT CONFIGURED (local copy kept)"}
