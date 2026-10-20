class_name OptimizedCodec
extends RefCounted

## OPTIMIZED communication pipeline (lossless end-to-end):
##   select fields by priority -> delta vs full -> dedup repeat check
##   -> compress -> integrity hash -> transfer bytes
## Field tiers: HIGH every packet (pos/rot/hp/shooting/weapon/ammo),
## MEDIUM every 3rd packet or on change (vel/anim/stance/reload/cloak),
## STATIC full packets only (id/team/avatar/name).
## Delta compares EXACT values (no quantization: coordinates stay lossless).
## Dedup detects byte-identical payloads (countdowns/lulls) and sends a
## tiny repeat marker. Full state every 60 packets heals any delta loss.
## Compression falls back to raw when it would inflate. Integrity is MD5
## over final bytes, verified before decode; mismatch = drop packet.
## Session counters expose REAL measured savings (never estimates).

const FULL_EVERY := 60
const MEDIUM_EVERY := 3
const DEDUP_RING := 32
const HIGH_KEYS := ["p", "r", "h", "f", "w", "m", "rl"]
const MED_KEYS := ["v", "a", "st", "cl"]
# short wire key -> runtime snapshot key
const KEYMAP := {"p": "position", "r": "rotation", "h": "health",
	"f": "shooting", "w": "weapon_id", "m": "_magres", "rl": "reloading",
	"v": "velocity", "a": "animation_state", "st": "stance", "cl": "cloaked"}

static func _read(p: Dictionary, k: String) -> Variant:
	if k == "m":
		return [int(p.get("mag", 0)), int(p.get("reserve", 0))]
	var v = p.get(KEYMAP.get(k, k), _hv(k))
	return _norm(v)

var algorithm := FileAccess.COMPRESSION_ZSTD
var degraded := false
var tick := 0
# ---- runtime optimization controls (dashboard-driven) ----
# Every flag measurably changes encoder output; stats() exposes the proof.
var delta_enabled := true # off -> every snapshot is a full state
var dedup_enabled := true # off -> repeat markers never sent
var compression_enabled := true # off -> raw wrap (mode 0), hash still applied
var priority_enabled := true # off -> MEDIUM fields ride every packet
var partial_enabled := true # off -> unchanged players resend full records
var medium_every := 3 # MEDIUM field cadence divisor (>=1)
var full_every := 60 # scheduled full-state heal cadence (>=1)
## Duty-cycle priority scheduling (percentages the scheduler actually uses).
## medium_pct: share of players whose MEDIUM fields ride each packet
## (rotating window, so every player is covered over time).
## low_pct: share of players that receive STATIC fields on a full heal.
var medium_pct := 100
var low_pct := 100
var _rot := 0
var last_sent := {} # pid -> full player record
var last_full_seq := -1
var dedup: Array = [] # [{hash, seq}]
var c_deltas := 0
var c_fulls := 0
var c_repeats := 0
var c_fallbacks := 0 # scheduled full heals sent while delta on
var c_orig := 0
var c_sent := 0
var c_comp_us := 0
var c_dedup_saved := 0
# pipeline stage accounting (cumulative measured bytes, never estimates)
var c_select := 0 # normal-equivalent full-state size entering the pipeline
var c_delta_out := 0 # post-delta raw size (pre-dedup, pre-compress)
var c_dedup_out := 0 # post-dedup raw size (pre-compress)
var c_med_in := 0 # MEDIUM fields included
var c_med_out := 0 # MEDIUM fields elided by cadence
var c_stale_base := 0 # decoder-side invalid-base events (full fallback follows)

static func _h32(b: PackedByteArray) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(b)
	return h.finish().hex_encode()

func reset_stats() -> void:
	c_deltas = 0
	c_fulls = 0
	c_repeats = 0
	c_fallbacks = 0
	c_orig = 0
	c_sent = 0
	c_comp_us = 0
	c_dedup_saved = 0
	c_select = 0
	c_delta_out = 0
	c_dedup_out = 0
	c_med_in = 0
	c_med_out = 0
	c_stale_base = 0

func stats() -> Dictionary:
	return {"deltas": c_deltas, "fulls": c_fulls, "repeats": c_repeats,
		"fallbacks": c_fallbacks, "full_heals": c_fallbacks,
		"original_bytes": c_orig,
		"transferred_bytes": c_sent, "dedup_saved": c_dedup_saved,
		"comp_us": c_comp_us, "select_bytes": c_select,
		"delta_bytes": c_delta_out, "dedup_out_bytes": c_dedup_out,
		"med_included": c_med_in, "med_elided": c_med_out,
		"stale_base": c_stale_base, "flags": get_config()}

## Validated runtime config from the dashboard. Unknown keys ignored;
## out-of-range values clamped. Returns the effective config.
func apply_config(d: Dictionary) -> Dictionary:
	if d.has("delta_enabled"):
		delta_enabled = bool(d["delta_enabled"])
	if d.has("dedup_enabled"):
		dedup_enabled = bool(d["dedup_enabled"])
		if not dedup_enabled:
			dedup.clear()
	if d.has("compression_enabled"):
		compression_enabled = bool(d["compression_enabled"])
	if d.has("priority_enabled"):
		priority_enabled = bool(d["priority_enabled"])
	if d.has("partial_enabled"):
		partial_enabled = bool(d["partial_enabled"])
	if d.has("medium_every"):
		medium_every = clampi(int(d["medium_every"]), 1, 60)
	if d.has("full_every"):
		full_every = clampi(int(d["full_every"]), 1, 600)
	if d.has("medium_pct"):
		medium_pct = clampi(int(d["medium_pct"]), 0, 100)
	if d.has("low_pct"):
		low_pct = clampi(int(d["low_every"] if "low_every" in d else d["low_pct"]), 0, 100)
	if d.has("algorithm"):
		var a := clampi(int(d["algorithm"]), 0, 3)
		algorithm = [FileAccess.COMPRESSION_FASTLZ, FileAccess.COMPRESSION_DEFLATE,
			FileAccess.COMPRESSION_ZSTD, FileAccess.COMPRESSION_GZIP][a]
	return get_config()

func get_config() -> Dictionary:
	var algos := ["fastlz", "deflate", "zstd", "gzip"]
	var ai := [FileAccess.COMPRESSION_FASTLZ, FileAccess.COMPRESSION_DEFLATE,
		FileAccess.COMPRESSION_ZSTD, FileAccess.COMPRESSION_GZIP].find(algorithm)
	return {"delta_enabled": delta_enabled, "dedup_enabled": dedup_enabled,
		"compression_enabled": compression_enabled,
		"priority_enabled": priority_enabled,
		"partial_enabled": partial_enabled,
		"medium_every": medium_every, "full_every": full_every,
		"medium_pct": medium_pct, "low_pct": low_pct,
		"algorithm": maxi(0, ai), "algorithm_name": algos[maxi(0, ai)] if ai >= 0 else "?"}

func encode_snapshot(players: Array, scores: Array, time_left: float, seq: int) -> Dictionary:
	tick += 1
	_rot += 1
	var np := maxi(1, players.size())
	var fe := maxi(1, full_every)
	var want_full := tick % fe == 1 or last_full_seq < 0
	if not delta_enabled:
		want_full = true # delta off -> full-state pipeline, still compressed
	var records: Array = []
	for idx in np:
		var p: Dictionary = players[idx]
		# duty-cycle: a rotating window of players receives MEDIUM fields,
		# sized by medium_pct, so every player is refreshed over time
		var med_share := 0
		if medium_pct >= 100:
			med_share = np
		elif medium_pct <= 0:
			med_share = 0
		else:
			var take := maxi(1, (np * medium_pct) / 100)
			var start := (_rot * maxi(1, take)) % np
			med_share = take
			if (idx - start + np) % np < med_share:
				med_share = 1 # this player is inside the rotating window
			else:
				med_share = 0
		# STATIC (low tier) on full heals: low_pct share of players
		var static_share := 1
		if low_pct >= 100:
			static_share = 1
		elif low_pct <= 0:
			static_share = 0
		else:
			static_share = 1 if ((idx * 100) / np) < low_pct else 0
		records.append(_player_record(p, want_full, med_share > 0, static_share > 0))
	var payload := {"proto": 1, "codec": "opt",
		"kind": "full" if want_full else "delta", "seq": seq,
		"t": Time.get_ticks_msec() / 1000.0, "players": records,
		"scores": scores.duplicate(), "time_left": time_left}
	if not want_full:
		payload["base"] = last_full_seq
	var raw := var_to_bytes(payload)
	c_orig += raw.size()
	c_delta_out += raw.size()
	# SELECT stage: exact normal-equivalent full-state size (separate cheap
	# serialize of the unoptimized shape). This is the pipeline entry volume.
	c_select += var_to_bytes({"proto": 1, "kind": "full", "seq": seq,
		"t": payload["t"], "players": players,
		"scores": scores.duplicate(), "time_left": time_left}).size()
	# dedup: identical payload seen recently -> repeat marker
	if not dedup_enabled:
		dedup.clear()
	# dedup: byte-identical state -> tiny repeat marker. The wall-clock "t"
	# stamp is EXCLUDED from the fingerprint, otherwise every packet would
	# look unique and the dedup stage could never fire. Scheduled FULL heals
	# are never suppressed: they must land so the receiver's delta base
	# advances, otherwise the next delta would look stale to the decoder.
	var dh := ""
	if not want_full:
		dh = _h32(var_to_bytes(_fingerprint(payload)))
	if dedup_enabled and not want_full:
		for e in dedup:
			if str(e["hash"]) == dh:
				c_repeats += 1
				c_dedup_saved += raw.size()
				var tiny := var_to_bytes({"proto": 1, "codec": "opt",
					"kind": "repeat", "seq": seq, "base": int(e["seq"]),
					"t": payload["t"], "scores": scores.duplicate(), "time_left": time_left})
				var fin := _pack(tiny)
				c_sent += fin.size()
				c_dedup_out += tiny.size()
				if want_full:
					c_fulls += 1
					last_full_seq = seq
				else:
					c_deltas += 1
				return {"bytes": fin, "kind": "repeat",
					"original_bytes": raw.size(), "transferred_bytes": fin.size(),
					"full_fallback": false, "error": ""}
		dedup.append({"hash": dh, "seq": seq})
		while dedup.size() > DEDUP_RING:
			dedup.pop_front()
	c_dedup_out += raw.size()
	var fin2 := _pack(raw)
	c_sent += fin2.size()
	if want_full:
		c_fulls += 1
		last_full_seq = seq
		if delta_enabled:
			c_fallbacks += 1 # scheduled full heal inside a delta stream
	else:
		c_deltas += 1
	return {"bytes": fin2, "kind": payload["kind"],
		"original_bytes": raw.size(), "transferred_bytes": fin2.size(),
		"full_fallback": want_full and not delta_enabled, "error": ""}

static func _fingerprint(payload: Dictionary) -> Dictionary:
	var fp := payload.duplicate()
	fp.erase("t")
	fp.erase("seq")
	return fp

func _player_record(p: Dictionary, want_full: bool, med_ok := true, static_ok := true) -> Dictionary:
	var pid := int(p.get("player_id", -1))
	var prev: Dictionary = last_sent.get(pid, {})
	var rec := {"i": pid}
	var changed := want_full or prev.is_empty()
	# HIGH: exact compare, always included when changed
	for k in HIGH_KEYS:
		var v = _read(p, k)
		var pv = prev.get(k, null)
		if want_full or not _eq(v, pv):
			rec[k] = v
			if not want_full and pv != null:
				changed = true
	# MEDIUM: cadence or change (priority off -> rides every packet)
	var med_due := true
	if priority_enabled and not med_ok:
		med_due = false
	elif priority_enabled:
		var me := maxi(1, medium_every)
		med_due = tick % (me * (2 if degraded else 1)) == 0
	for k in MED_KEYS:
		var v2 = _read(p, k)
		var pv2 = prev.get(k, null)
		if want_full or med_due or not _eq(v2, pv2):
			rec[k] = v2
			c_med_in += 1
			if not want_full and pv2 != null and not _eq(v2, pv2):
				changed = true
		else:
			c_med_out += 1
	# STATIC: full packets only (also forced for never-sent players)
	if want_full and static_ok or prev.is_empty():
		rec["s"] = [int(p.get("team_id", 0)), int(p.get("avatar_id", 0))]
		rec["n"] = str(p.get("name", "?"))
		changed = true
	if not changed and not want_full:
		if partial_enabled:
			return {"i": pid, "same": true}
		# partial off -> unchanged players resend their full merged record
		var resend := {"i": pid}
		for k in prev:
			resend[k] = prev[k]
		return resend
	# refresh last-sent with merged full record
	var full := (prev.duplicate() if not prev.is_empty() else {})
	for k in rec:
		if k != "i" and k != "same":
			full[k] = rec[k]
	if rec.has("s"):
		full["s"] = rec["s"]
	if rec.has("n"):
		full["n"] = rec["n"]
	last_sent[pid] = full
	return rec

static func _hv(k: String) -> Variant:
	match k:
		"p", "v":
			return [0.0, 0.0, 0.0]
		"r":
			return [0.0, 0.0]
		"m":
			return [0, 0]
		"h":
			return 100.0
		"f", "rl", "cl":
			return false
		"w":
			return 0
		"a":
			return "IDLE"
		"st":
			return "STANDING"
	return 0

static func _norm(v: Variant) -> Variant:
	if v is Vector3:
		return [(v as Vector3).x, (v as Vector3).y, (v as Vector3).z]
	if v is Vector2:
		return [(v as Vector2).x, (v as Vector2).y]
	if v is bool or v is float or v is int or v is String or v is Array:
		return v
	return str(v)

static func _eq(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return false
	return str(a) == str(b)

func _pack(raw: PackedByteArray) -> PackedByteArray:
	if not compression_enabled:
		var fg0 := FallbackGrower.new()
		return fg0.wrap(0, raw.size(), raw)
	var t0 := Time.get_ticks_usec()
	var comp := raw.compress(algorithm)
	var dt := Time.get_ticks_usec() - t0
	c_comp_us += dt
	var body := raw
	var mode := 0 # 0 = raw, else FileAccess compression mode + 1
	if not comp.is_empty() and comp.size() < raw.size():
		body = comp
		mode = int(algorithm) + 1
	var fg := FallbackGrower.new()
	return fg.wrap(mode, raw.size(), body)

func decode_snapshot(payload: PackedByteArray) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	if payload.size() < 24:
		return {"ok": false, "error": "too small"}
	var body: PackedByteArray = payload.slice(0, payload.size() - 16)
	var want: PackedByteArray = payload.slice(payload.size() - 16)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(body)
	if h.finish() != want:
		return {"ok": false, "error": "integrity"}
	var t1 := Time.get_ticks_usec()
	var inner: Dictionary = FallbackGrower.unwrap(body)
	if inner.is_empty():
		return {"ok": false, "error": "decompress"}
	var v = bytes_to_var(inner["raw"])
	var dt := Time.get_ticks_usec() - t0
	if not (v is Dictionary):
		return {"ok": false, "error": "not a dict"}
	var snap: Dictionary = v
	if int(snap.get("proto", 0)) != 1 or str(snap.get("codec", "")) != "opt":
		return {"ok": false, "error": "shape"}
	var out := {"ok": true, "snap": {}, "error": "", "decomp_us": dt,
		"kind": str(snap.get("kind", "?"))}
	if str(snap.get("kind", "")) == "repeat":
		out["repeat"] = true
		out["scores"] = (snap.get("scores", []) as Array).duplicate()
		out["time_left"] = float(snap.get("time_left", 0.0))
		out["seq"] = int(snap.get("seq", 0))
		return out
	if str(snap.get("kind", "")) == "full":
		decoder_full(int(snap.get("seq", 0)), snap)
		out["snap"] = _to_runtime(snap)
		return out
	# delta
	if int(snap.get("base", -999)) != decoder_base_seq:
		c_stale_base += 1 # invalid base: full-state fallback follows
		return {"ok": false, "error": "stale-base", "need_full": true}
	out["snap"] = _apply_delta(snap)
	return out

# ---- decoder state ----
var decoder_base_seq := -1
var decoder_base := {} # pid -> full record

func decoder_full(seq: int, snap: Dictionary) -> void:
	decoder_base_seq = seq
	decoder_base.clear()
	for rec in snap.get("players", []):
		var r: Dictionary = rec
		var full := {}
		for k in r:
			if k != "i":
				full[k] = r[k]
		decoder_base[int(r.get("i", -1))] = full

func _apply_delta(snap: Dictionary) -> Dictionary:
	var players: Array = []
	for rec in snap.get("players", []):
		var r: Dictionary = rec
		var pid := int(r.get("i", -1))
		if bool(r.get("same", false)) and decoder_base.has(pid):
			players.append(_to_player(pid, decoder_base[pid]))
			continue
		var full: Dictionary = (decoder_base.get(pid, {}) as Dictionary).duplicate()
		for k in r:
			if k != "i" and k != "same":
				full[k] = r[k]
		decoder_base[pid] = full
		players.append(_to_player(pid, full))
	return {"proto": 1, "kind": "delta", "seq": int(snap.get("seq", 0)),
		"t": float(snap.get("t", 0.0)), "players": players,
		"scores": (snap.get("scores", []) as Array).duplicate(),
		"time_left": float(snap.get("time_left", 0.0))}

func _to_runtime(snap: Dictionary) -> Dictionary:
	var players: Array = []
	for rec in snap.get("players", []):
		var r: Dictionary = rec
		players.append(_to_player(int(r.get("i", -1)), r))
	return {"proto": 1, "kind": "full", "seq": int(snap.get("seq", 0)),
		"t": float(snap.get("t", 0.0)), "players": players,
		"scores": (snap.get("scores", []) as Array).duplicate(),
		"time_left": float(snap.get("time_left", 0.0))}

static func _to_player(pid: int, r: Dictionary) -> Dictionary:
	var s: Array = r.get("s", [0, 0])
	var p: Array = r.get("p", [0.0, 0.0, 0.0])
	var rr: Array = r.get("r", [0.0, 0.0])
	var vv: Array = r.get("v", [0.0, 0.0, 0.0])
	var mm: Array = r.get("m", [0, 0])
	return {"player_id": pid, "team_id": int(s[0]), "avatar_id": int(s[1]),
		"name": str(r.get("n", "?")), "position": Vector3(p[0], p[1], p[2]),
		"rotation": Vector2(rr[0], rr[1]), "velocity": Vector3(vv[0], vv[1], vv[2]),
		"health": float(r.get("h", 100.0)), "animation_state": str(r.get("a", "IDLE")),
		"stance": str(r.get("st", "STANDING")), "weapon_id": int(r.get("w", 0)),
		"mag": int(mm[0]), "reserve": int(mm[1]),
		"shooting": bool(r.get("f", false)), "reloading": bool(r.get("rl", false)),
		"cloaked": bool(r.get("cl", false))}

class FallbackGrower extends RefCounted:
	# header: [mode(1B)][raw LE size(4B)][reserved(3B)] + body, MD5 appended
	# by the packer. mode 0 = raw, else FileAccess compression mode + 1.
	func wrap(mode: int, raw_size: int, body: PackedByteArray) -> PackedByteArray:
		var head := PackedByteArray([mode & 0xff, raw_size & 0xff,
			(raw_size >> 8) & 0xff, (raw_size >> 16) & 0xff,
			(raw_size >> 24) & 0xff, 0, 0, 0])
		var raw := head + body
		var h := HashingContext.new()
		h.start(HashingContext.HASH_MD5)
		h.update(raw)
		return raw + h.finish()

	static func unwrap(payload: PackedByteArray) -> Dictionary:
		# payload here excludes the trailing hash (caller split it)
		if payload.size() < 8:
			return {}
		var mode := int(payload[0])
		var raw_size := int(payload[1]) | (int(payload[2]) << 8) | (int(payload[3]) << 16) | (int(payload[4]) << 24)
		var body := payload.slice(8)
		if mode == 0:
			return {"raw": body}
		if raw_size <= 0 or raw_size > 1048576:
			return {}
		var raw := body.decompress(raw_size, mode - 1)
		if raw.is_empty():
			return {}
		return {"raw": raw}
