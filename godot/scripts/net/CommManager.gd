class_name CommManager
extends RefCounted

## Communication pipeline seam. NORMAL sends full-state payloads with no
## optimization (experimental baseline). OPTIMIZED (Phase 8) plugs in here
## behind the same encode/decode shape. Gameplay never sees the difference.
##
## encode_snapshot() returns:
##   {bytes, kind ("full"/"delta"), original_bytes, transferred_bytes,
##    full_fallback (bool), error}
## decode_snapshot() returns: {ok, snap, error}
## Byte counts are measured payload sizes (var_to_bytes / compressed),
## never estimates. ENet framing overhead is excluded (documented).

const PROTO := 1

var mode := "NORMAL"
var normal := NormalCodec.new()
var opt: RefCounted # OptimizedCodec (Phase 8); null until implemented

static func make(mode_in: String) -> CommManager:
	var c := CommManager.new()
	c.mode = mode_in
	c.opt = OptimizedCodec.new()
	return c

func encode_snapshot(players: Array, scores: Array, time_left: float, seq: int) -> Dictionary:
	if mode == "OPTIMIZED" and opt != null and opt.has_method("encode_snapshot"):
		return opt.encode_snapshot(players, scores, time_left, seq)
	return normal.encode_snapshot(players, scores, time_left, seq)

func decode_snapshot(payload: PackedByteArray) -> Dictionary:
	# optimized payloads self-describe; normal decode validates shape
	var res: Dictionary = normal.decode_snapshot(payload)
	if res.get("ok", false):
		return res
	if opt != null and opt.has_method("decode_snapshot"):
		return opt.decode_snapshot(payload)
	return res

class NormalCodec extends RefCounted:
	func encode_snapshot(players: Array, scores: Array, time_left: float, seq: int) -> Dictionary:
		var snap := {"proto": 1, "kind": "full", "seq": seq,
			"t": Time.get_ticks_msec() / 1000.0, "players": players,
			"scores": scores.duplicate(), "time_left": time_left}
		var b := var_to_bytes(snap)
		return {"bytes": b, "kind": "full", "original_bytes": b.size(),
			"transferred_bytes": b.size(), "full_fallback": false, "error": ""}

	func decode_snapshot(payload: PackedByteArray) -> Dictionary:
		if payload.is_empty() or payload.size() > 65536:
			return {"ok": false, "error": "bad size"}
		var v = bytes_to_var(payload)
		if not (v is Dictionary):
			return {"ok": false, "error": "not a dict"}
		var snap: Dictionary = v
		if int(snap.get("proto", 0)) != 1:
			return {"ok": false, "error": "proto mismatch"}
		if str(snap.get("codec", "")) == "opt":
			return {"ok": false, "error": "opt payload"}
		if not (snap.get("players") is Array) or not (snap.get("scores") is Array):
			return {"ok": false, "error": "bad shape"}
		return {"ok": true, "snap": snap, "error": ""}
