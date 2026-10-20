class_name MetricsCollector
extends RefCounted

## Dedicated metrics sink. Gameplay/netcode push numbers in; this class
## only samples, aggregates, serializes. Everything stored is MEASURED:
## unavailable platform values are recorded as -1 (shown as N/A).
## CPU%: Linux /proc deltas (real); elsewhere N/A. RAM: VmRSS on Linux,
## else static-memory fallback... no — fallback would be a different
## quantity; record -1 with source noted.

const GAME_VERSION := "1.0"

var interval := 0.5
var samples: Array = []
var acc := 0.0
var elapsed := 0.0
var _cpu_prev := [-1, -1] # [total_jiffies, wall_msec]
var _last_net := {}
var cpu_source := "N/A"
var ram_source := "N/A"

static func read_cpu_percent() -> Array:
	# returns [jiffies_or_-1, source]; /proc files report size 0, so read
	# line-wise (get_as_text would return empty).
	var f := FileAccess.open("/proc/self/stat", FileAccess.READ)
	if f == null:
		return [-1.0, "N/A"]
	var line := f.get_line()
	f.close()
	if line == "":
		return [-1.0, "N/A"]
	var parts := line.split(" ", false)
	if parts.size() < 15:
		return [-1.0, "N/A"]
	var jt := float(parts[13]) + float(parts[14])
	return [jt, "proc"]

static func read_rss_mb() -> Array:
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if f == null:
		return [-1.0, "N/A"]
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("VmRSS:"):
			var kb := float(line.split(" ", false)[1])
			f.close()
			return [kb / 1024.0, "rss"]
	f.close()
	return [-1.0, "N/A"]

func reset(sample_interval: float) -> void:
	interval = sample_interval
	samples.clear()
	acc = 0.0
	elapsed = 0.0
	_cpu_prev = [-1, -1]
	_last_net = {}

func update(dt: float, ctx: Dictionary) -> void:
	elapsed += dt
	acc += dt
	if acc < interval:
		return
	acc = 0.0
	samples.append(_take(ctx))

func _take(ctx: Dictionary) -> Dictionary:
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / maxf(1.0, float(fps))
	var cpu := -1.0
	var now_ms := Time.get_ticks_msec()
	var cr := read_cpu_percent()
	if float(cr[0]) >= 0.0:
		cpu_source = str(cr[1])
		if _cpu_prev[0] >= 0.0 and now_ms > _cpu_prev[1]:
			var dj: float = float(cr[0]) - float(_cpu_prev[0])
			var dw: float = float(now_ms - _cpu_prev[1]) / 1000.0
			var ncpu := maxi(1, OS.get_processor_count())
			if dw > 0.0:
				cpu = dj / 100.0 / dw / float(ncpu) * 100.0
		_cpu_prev = [float(cr[0]), now_ms]
	var ram := -1.0
	var rr := read_rss_mb()
	if float(rr[0]) >= 0.0:
		ram = float(rr[0])
		ram_source = str(rr[1])
	var net: Dictionary = ctx.get("net", {})
	var bs: float = float(net.get("bytes_sent", 0))
	var br: float = float(net.get("bytes_received", 0))
	var up := 0.0
	var dn := 0.0
	if _last_net.has("bytes_sent"):
		up = maxf(0.0, (bs - float(_last_net["bytes_sent"])) / interval)
		dn = maxf(0.0, (br - float(_last_net["bytes_received"])) / interval)
	_last_net = {"bytes_sent": bs, "bytes_received": br}
	var opt: Dictionary = ctx.get("opt", {})
	return {
		"t": elapsed,
		"fps": fps, "frame_ms": frame_ms, "cpu": cpu, "ram": ram,
		"ping": float(net.get("ping", -1.0)), "rtt": float(net.get("rtt", -1.0)),
		"loss": float(net.get("loss", -1.0)),
		"up": up, "dn": dn,
		"bytes_sent": bs, "bytes_received": br,
		"pkts_sent": int(net.get("pkts_sent", 0)), "pkts_recv": int(net.get("pkts_recv", 0)),
		"orig": float(opt.get("orig", 0)), "comp": float(opt.get("comp", 0)),
		"ratio": float(opt.get("ratio", -1.0)),
		"comp_us": float(opt.get("comp_us", 0)), "decomp_us": float(opt.get("decomp_us", 0)),
		"deltas": int(opt.get("deltas", 0)), "fulls": int(opt.get("fulls", 0)),
		"saved": float(opt.get("saved", 0)),
		"kills": int(ctx.get("kills", 0)), "deaths": int(ctx.get("deaths", 0)),
	}

static func _avg(rows: Array, key: String) -> float:
	var s := 0.0
	var n := 0
	for r in rows:
		var v := float((r as Dictionary).get(key, -1.0))
		if v >= 0.0:
			s += v
			n += 1
	return s / float(maxi(1, n)) if n > 0 else -1.0

func summary(meta: Dictionary) -> Dictionary:
	var last: Dictionary = samples.back() if not samples.is_empty() else {}
	var dh: Array = []
	for r in samples:
		dh.append(float((r as Dictionary).get("loss", -1.0)))
	var loss_vals := dh.filter(func(v: float) -> bool: return v >= 0.0)
	var avg_loss := -1.0
	if not loss_vals.is_empty():
		var s := 0.0
		for v in loss_vals:
			s += v
		avg_loss = s / loss_vals.size()
	var comp_bytes := float(last.get("comp", 0.0))
	var orig_bytes := float(last.get("orig", 0.0))
	return {
		"match_id": str(meta.get("match_id", "?")),
		"mode": str(meta.get("mode", "?")),
		"samples": samples.size(), "duration": elapsed,
		"avg_fps": _avg(samples, "fps"),
		"avg_frame_ms": _avg(samples, "frame_ms"),
		"avg_cpu": _avg(samples, "cpu"), "cpu_source": cpu_source,
		"avg_ram": _avg(samples, "ram"), "ram_source": ram_source,
		"avg_rtt": _avg(samples, "rtt"), "avg_ping": _avg(samples, "ping"),
		"avg_loss": avg_loss,
		"bytes_sent": float(last.get("bytes_sent", 0.0)),
		"bytes_received": float(last.get("bytes_received", 0.0)),
		"pkts_sent": int(last.get("pkts_sent", 0)),
		"pkts_recv": int(last.get("pkts_recv", 0)),
		"original_bytes": orig_bytes, "compressed_bytes": comp_bytes,
		"compression_ratio": (comp_bytes / maxf(1.0, orig_bytes)) if orig_bytes > 0.0 else -1.0,
		"reduction_pct": (100.0 * (1.0 - comp_bytes / orig_bytes)) if orig_bytes > 0.0 else -1.0,
		"bytes_saved": float(last.get("saved", 0.0)),
		"comp_us_total": float(last.get("comp_us", 0.0)),
		"decomp_us_total": float(last.get("decomp_us", 0.0)),
		"deltas": int(last.get("deltas", 0)), "fulls": int(last.get("fulls", 0)),
		"kills": int(last.get("kills", 0)), "deaths": int(last.get("deaths", 0)),
	}

static func csv_header() -> String:
	return "t,fps,frame_ms,cpu,ram,ping,rtt,loss,up_Bps,dn_Bps,bytes_sent,bytes_received,pkts_sent,pkts_recv,orig_bytes,comp_bytes,ratio,comp_us,decomp_us,deltas,fulls,saved,kills,deaths"

func to_csv() -> String:
	var lines := [csv_header()]
	for r in samples:
		var d: Dictionary = r
		var vals: Array = []
		for k in ["t", "fps", "frame_ms", "cpu", "ram", "ping", "rtt", "loss",
				"up", "dn", "bytes_sent", "bytes_received", "pkts_sent", "pkts_recv",
				"orig", "comp", "ratio", "comp_us", "decomp_us", "deltas", "fulls",
				"saved", "kills", "deaths"]:
			var v = d.get(k, -1)
			vals.append(("%0.3f" % float(v)) if v is float else str(v))
		lines.append(",".join(vals))
	return "\n".join(lines) + "\n"
