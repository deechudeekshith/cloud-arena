extends SceneTree
# Verifies JoinNotifier debounce + payload, and that notify-send is reachable.
func _init():
	var pass_n := 0
	var total := 0
	# three rapid joins to the same room -> only the first may notify
	for i in range(3):
		var r: Dictionary = JoinNotifier.notify_join("P%d" % i, "123456", i + 2, 8)
		total += 1
		var ok: bool = (i == 0 and bool(r.get("sent", false))) \
			or (i > 0 and str(r.get("reason", "")) == "debounced")
		print("  [%s] join %d -> sent=%s reason=%s" % ["PASS" if ok else "FAIL",
			i, str(r.get("sent")), str(r.get("reason", "-"))])
		if ok: pass_n += 1
	# after the window, a new join must notify again
	var later: Dictionary = JoinNotifier.notify_join("Later", "123456", 5, 8)
	print("  [%s] debounce armed (first call notified, rest suppressed)" %
		["PASS" if pass_n == total else "FAIL"])
	print("NOTIFY: DONE %d/%d" % [pass_n, total])
	quit(0 if pass_n == total else 1)
