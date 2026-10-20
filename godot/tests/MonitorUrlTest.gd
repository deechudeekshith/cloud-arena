extends SceneTree
# Verifies MonitorLink monitor-URL resolution: a LAN client must report to the
# host PC, not to its own loopback.
var m: MonitorLink

func _init():
	m = MonitorLink.new()
	var cases := [
		["explicit override wins", "http://10.0.0.9:9000", "192.168.1.50", "http://10.0.0.9:9000"],
		["lan ip from join", "", "192.168.1.50", "http://192.168.1.50:8901"],
		["ws url is stripped", "", "ws://192.168.1.77:7777", "http://192.168.1.77:8901"],
		["loopback stays local", "", "127.0.0.1", "http://127.0.0.1:8901"],
		["no host falls back", "", "", "http://127.0.0.1:8901"],
	]
	var pass_n := 0
	for c in cases:
		m.port = 8901
		var got: String = m.resolve_base_url(c[1], c[2])
		var ok: bool = got == c[3]
		print("  [%s] %-26s %s -> %s" % ["PASS" if ok else "FAIL", c[0], c[2], got])
		if ok: pass_n += 1
	print("MONURL: DONE %d/%d passed" % [pass_n, cases.size()])
	quit(0 if pass_n == cases.size() else 1)
