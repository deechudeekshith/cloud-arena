class_name NetSim
extends RefCounted

## Configurable network-condition conditioner for research. Delays, jitters,
## drops, and bandwidth-shapes packets that pass through it. Used by the
## loopback test shuttle and future simulated-link experiments. Labels its
## output honestly: delivery here is SIMULATED (metadata network_mode
## must read "simulated", never "real"). Real-LAN conditioning needs
## OS-level tools (e.g. tc/netem) and is out of scope.

var enabled := false
var latency_ms := 0.0
var jitter_ms := 0.0
var loss_pct := 0.0
var bw_kbps := 0.0 # 0 = unlimited
var rng := RandomNumberGenerator.new()

var _queue: Array = [] # {due, kind, payload, deliver: Callable}
var n_dropped := 0
var n_sent := 0

func configure(lat_ms: float, jit_ms: float, loss: float, bw: float = 0.0) -> void:
	latency_ms = lat_ms
	jitter_ms = jit_ms
	loss_pct = loss
	bw_kbps = bw
	enabled = lat_ms > 0.0 or jit_ms > 0.0 or loss > 0.0 or bw > 0.0
	rng.randomize()

func describe() -> String:
	if not enabled:
		return "off"
	return "%dms+%dms loss %0.1f%% %s" % [int(latency_ms), int(jitter_ms),
		loss_pct, ("bw %dkbps" % int(bw_kbps)) if bw_kbps > 0.0 else "unlimited"]

func send(kind: String, payload: Variant, size_bytes: int, deliver: Callable) -> void:
	n_sent += 1
	if not enabled:
		deliver.call(kind, payload)
		return
	if rng.randf() * 100.0 < loss_pct:
		n_dropped += 1
		return
	var delay := latency_ms + rng.randf_range(-jitter_ms, jitter_ms)
	if bw_kbps > 0.0:
		delay += float(size_bytes) * 8.0 / bw_kbps
	delay = maxf(0.0, delay)
	if delay <= 0.0:
		deliver.call(kind, payload)
		return
	_queue.append({"due": Time.get_ticks_msec() + delay, "kind": kind,
		"payload": payload, "deliver": deliver})

func update() -> void:
	if _queue.is_empty():
		return
	var now := Time.get_ticks_msec()
	var i := 0
	while i < _queue.size():
		if float(_queue[i]["due"]) <= float(now):
			var e: Dictionary = _queue[i]
			_queue.remove_at(i)
			(e["deliver"] as Callable).call(e["kind"], e["payload"])
		else:
			i += 1

func stats() -> Dictionary:
	return {"sent": n_sent, "dropped": n_dropped,
		"drop_rate": float(n_dropped) / float(maxi(1, n_sent))}
