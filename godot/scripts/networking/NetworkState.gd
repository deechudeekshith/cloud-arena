class_name NetworkState
extends RefCounted

## Network-ready player/match state. Rendering-independent plain Dictionaries.
## Offline now: snapshot() / serialize() / measure() are real and used by the
## metrics HUD; transport stays in this module only (stubbed, honest N/A).

const PROTO_VERSION := 1

static func snapshot_combatant(c: Node) -> Dictionary:
	if c.has_method("snapshot"):
		var s: Dictionary = c.snapshot()
		s["proto"] = PROTO_VERSION
		return s
	return {}

static func snapshot_match(combatants: Array, scores: Array, time_left: float) -> Dictionary:
	var list: Array = []
	for c in combatants:
		if is_instance_valid(c):
			list.append(snapshot_combatant(c))
	return {"proto": PROTO_VERSION, "t": Time.get_ticks_msec() / 1000.0,
		"players": list, "scores": scores.duplicate(),
		"time_left": time_left}

## Canonical serialization used for future transport + metrics.
static func serialize(state: Dictionary) -> PackedByteArray:
	return var_to_bytes(state)

static func deserialize(b: PackedByteArray) -> Dictionary:
	var v = bytes_to_var(b)
	return v if v is Dictionary else {}

## Size estimate for HUD "bytes saved" metrics (no fake savings: ratio = 1.0
## until real compression/transport lands).
static func measure(state: Dictionary) -> Dictionary:
	var raw := serialize(state)
	return {"bytes": raw.size(), "ratio": 1.0, "note": "offline: no transport"}

# ---- future transport stubs (NOT implemented; kept separate by design) ----
class TransportStub:
	var connected := false
	func connect_to(_addr: String) -> bool:
		return false
	func send(_b: PackedByteArray) -> int:
		return 0
	func poll() -> Array:
		return []
