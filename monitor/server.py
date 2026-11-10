#!/usr/bin/env python3
"""Cloud Arena research monitor: FastAPI + SQLite + WebSocket dashboard backend.

Local-only, offline-first, zero paid services. Launches with:
    python3 server.py [--port 8901] [--db cloud_arena_monitor.db]
    [--game-path /path/to/thin_client/godot] [--no-auto-launch]

Responsibilities: ingest game telemetry, track live connection state,
store samples/events/matches/experiments, serve comparison + export,
queue validated commands for the game, and optionally auto-launch
headless experiment runs locally.
"""
import argparse
import asyncio
import csv
import io
import json
import queue
import sqlite3
import subprocess
import threading
import traceback
import time
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles

HERE = Path(__file__).resolve().parent

# Browser clients (the Web build) post telemetry from whatever page served
# them, so the monitor must answer cross-origin requests. A blanket
# allow_origins=["*"] would let any website on the internet queue commands
# (start/stop match, rewrite network config) for a live session, so origins
# are restricted to loopback and RFC1918 private ranges -- i.e. the user's own
# machine and LAN, which is exactly where the game and its clients live.
LOCAL_ORIGIN_RE = (
    r"^https?://("
    r"localhost|127\.0\.0\.1|\[::1\]"
    r"|10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
    r"|192\.168\.\d{1,3}\.\d{1,3}"
    r"|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}"
    r")(:\d{1,5})?$"
)

# --------------------------------------------------------------------------
# database
# --------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS experiments(
  id TEXT PRIMARY KEY, name TEXT, created_at TEXT, status TEXT,
  baseline_match_id TEXT, optimized_match_id TEXT, notes TEXT,
  config_json TEXT);
CREATE TABLE IF NOT EXISTS matches(
  match_id TEXT PRIMARY KEY, experiment_id TEXT, room_id TEXT,
  mode TEXT, map TEXT, map_seed INTEGER, player_count INTEGER,
  humans INTEGER, bots INTEGER, duration REAL, network_mode TEXT,
  source TEXT, started_at TEXT, ended_at TEXT, summary_json TEXT);
CREATE TABLE IF NOT EXISTS metric_samples(
  id INTEGER PRIMARY KEY AUTOINCREMENT, match_id TEXT, t REAL,
  timestamp TEXT, mode TEXT, fps REAL, frame_ms REAL, cpu REAL,
  ram REAL, ping REAL, rtt REAL, loss REAL, up_bps REAL, dn_bps REAL,
  bytes_sent REAL, bytes_recv REAL, pkts_sent INTEGER, pkts_recv INTEGER,
  orig REAL, comp REAL, ratio REAL, comp_us REAL, decomp_us REAL,
  deltas INTEGER, fulls INTEGER, saved REAL, kills INTEGER, deaths INTEGER,
  codec_json TEXT);
CREATE INDEX IF NOT EXISTS idx_samples_match ON metric_samples(match_id, t);
CREATE TABLE IF NOT EXISTS optimization_configs(
  id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT, name TEXT,
  delta_enabled INTEGER, dedup_enabled INTEGER, compression_enabled INTEGER,
  priority_enabled INTEGER, partial_enabled INTEGER, algorithm INTEGER,
  medium_every INTEGER, full_every INTEGER, update_hz REAL,
  budget_kbps REAL, max_packet_size INTEGER);
CREATE TABLE IF NOT EXISTS network_configs(
  id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT, name TEXT,
  bandwidth_kbps REAL, latency_ms REAL, jitter_ms REAL, loss_pct REAL);
CREATE TABLE IF NOT EXISTS events(
  id INTEGER PRIMARY KEY AUTOINCREMENT, match_id TEXT, t REAL,
  timestamp TEXT, type TEXT, detail TEXT);
CREATE TABLE IF NOT EXISTS commands(
  id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT, target TEXT,
  cmd TEXT, params_json TEXT, status TEXT, result TEXT);
CREATE TABLE IF NOT EXISTS pending_joins(
  id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT, peer INTEGER, name TEXT,
  avatar INTEGER, device TEXT, device_name TEXT, platform TEXT,
  players INTEGER, max_players INTEGER, approver TEXT,
  created_at TEXT, status TEXT, decided_at TEXT);

-- ── room / session model (spec: recording starts at first join) ──
CREATE TABLE IF NOT EXISTS rooms(
  code TEXT PRIMARY KEY, room_id TEXT, host_device TEXT, host_name TEXT,
  max_players INTEGER, mode TEXT, created_at TEXT, updated_at TEXT,
  state TEXT, last_phase TEXT, match_started_at TEXT, match_ended_at TEXT,
  empty_at TEXT);
CREATE TABLE IF NOT EXISTS sessions(
  id TEXT PRIMARY KEY, session_no INTEGER, room_code TEXT, created_at TEXT,
  ended_at TEXT, host_device TEXT, player_count INTEGER, device_count INTEGER,
  peak_players INTEGER, peak_devices INTEGER,
  match_start_time TEXT, match_end_time TEXT, optimization_mode TEXT,
  optimization_config TEXT, network_config TEXT, status TEXT,
  experiment_id TEXT, match_id TEXT);
CREATE TABLE IF NOT EXISTS devices(
  session_id TEXT, device_id TEXT, name TEXT, platform TEXT, role TEXT,
  joined_at TEXT, left_at TEXT, status TEXT, last_seen TEXT,
  PRIMARY KEY(session_id, device_id));
CREATE TABLE IF NOT EXISTS session_samples(
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, device_id TEXT,
  t REAL, timestamp TEXT, phase TEXT, fps REAL, cpu REAL, ram REAL,
  up_bps REAL, dn_bps REAL, rtt REAL, ping REAL, loss REAL,
  bytes_sent REAL, bytes_recv REAL, orig REAL, comp REAL, ratio REAL,
  deltas INTEGER, fulls INTEGER, peers INTEGER);
CREATE INDEX IF NOT EXISTS idx_sess_samples ON session_samples(session_id, t);
CREATE TABLE IF NOT EXISTS config_history(
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, timestamp TEXT,
  kind TEXT, field TEXT, old_value TEXT, new_value TEXT);
"""


class DB:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()
        con = sqlite3.connect(str(path))
        con.executescript(SCHEMA)
        self._migrate(con)
        con.commit()
        con.close()

    def _migrate(self, con):
        """Additive column migrations for databases created by older builds."""
        want = {
            "sessions": {
                "peak_players": "INTEGER",
                "peak_devices": "INTEGER",
            },
        }
        for table, cols in want.items():
            have = {r[1] for r in con.execute("PRAGMA table_info(%s)" % table)}
            for col, typ in cols.items():
                if col not in have:
                    con.execute("ALTER TABLE %s ADD COLUMN %s %s"
                                % (table, col, typ))

    def con(self):
        c = sqlite3.connect(str(self.path))
        c.row_factory = sqlite3.Row
        return c

    def insert_samples(self, rows):
        if not rows:
            return
        with self.lock:
            con = self.con()
            con.executemany(
                """INSERT INTO metric_samples(match_id,t,timestamp,mode,fps,
                frame_ms,cpu,ram,ping,rtt,loss,up_bps,dn_bps,bytes_sent,
                bytes_recv,pkts_sent,pkts_recv,orig,comp,ratio,comp_us,
                decomp_us,deltas,fulls,saved,kills,deaths,codec_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                rows)
            con.commit()
            con.close()

    def q(self, sql, args=()):
        with self.lock:
            con = self.con()
            out = [dict(r) for r in con.execute(sql, args).fetchall()]
            con.close()
        return out

    def run(self, sql, args=()):
        with self.lock:
            con = self.con()
            cur = con.execute(sql, args)
            con.commit()
            lid = cur.lastrowid
            con.close()
        return lid


# --------------------------------------------------------------------------
# app state
# --------------------------------------------------------------------------

class State:
    def __init__(self, db: DB, args):
        self.db = db
        self.args = args
        self.live = {}          # latest telemetry per client
        self.last_seen = {}     # client -> epoch seconds
        self.ring = {}          # match_id -> deque-ish list of recent samples
        self.cmd_seq = 0
        self.ws_clients = set()
        self.pending_runs = {}  # run_key -> {experiment_id, side}
        self.bench = {"running": False, "stop": False, "log": []}
        self.loop = None

    # -- connection -----------------------------------------------------
    def conn_state(self):
        """Newest heartbeat across all game roles (solo/host/client)."""
        now = time.time()
        best = 0.0
        for k, ts in self.last_seen.items():
            if k.startswith("godot"):
                best = max(best, ts)
        if best == 0.0:
            return "DISCONNECTED", -1.0
        age = now - best
        if age < 3.0:
            return "CONNECTED", age
        if age < 15.0:
            return "RECONNECTING", age
        return "DISCONNECTED", age

    def live_tel(self, prefer=("host", "client", "solo")):
        """Telemetry for the requested role.

        Slots are device scoped, so keys look like "godot:host:<device_id>".
        Matching is by role prefix and the FRESHEST usable slot wins, so two
        devices on the same role can never shadow each other by dictionary
        order. Roles absent from `prefer` are never returned unless nothing
        else has a match.
        """
        for role in prefer:
            best = None
            for key, t in self.live.items():
                if not (t and t.get("match_id")):
                    continue
                if key == "godot:" + role or key.startswith("godot:" + role + ":"):
                    if best is None or float(t.get("t", 0.0)) > float(best.get("t", 0.0)):
                        best = t
            if best is not None:
                return best
        for t in self.live.values():
            if t and t.get("match_id"):
                return t
        return {}

    # -- live ------------------------------------------------------------
    def live_payload(self):
        st, age = self.conn_state()
        tel = self.live_tel()
        stale = st != "CONNECTED"
        return {"type": "LIVE", "connection": st, "age_s": age, "stale": stale,
                "telemetry": tel, "server_time": time.time()}


state: State = None
app = FastAPI(title="Cloud Arena Research Monitor")
app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=LOCAL_ORIGIN_RE,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def now_ts():
    return time.time()


# --------------------------------------------------------------------------
# ingest
# --------------------------------------------------------------------------

def _f(v, d=-1.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


def _i(v, d=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return d


def ensure_match(meta: dict, experiment_id: str):
    """Create the match row on first sight (MATCH_STARTED or first sample).
    A later MATCH_STARTED (real roster known at countdown end) updates the
    counts instead of being ignored."""
    mid = str(meta.get("match_id", "?"))
    if not mid or mid == "?":
        return None
    db = state.db
    if db.q("SELECT match_id FROM matches WHERE match_id=?", (mid,)):
        if experiment_id:
            db.run("UPDATE matches SET experiment_id=? WHERE match_id=?",
                   (experiment_id, mid))
        db.run("""UPDATE matches SET player_count=?, humans=?, bots=?,
                 duration=?, map=?, map_seed=? WHERE match_id=?""",
               (_i(meta.get("player_count", 0)), _i(meta.get("humans", 0)),
                _i(meta.get("bots", 0)), _f(meta.get("duration", 0), 0.0),
                str(meta.get("map", "arena")), _i(meta.get("map_seed", 0)),
                mid))
        return mid
    db.run(
        """INSERT INTO matches(match_id,experiment_id,room_id,mode,map,
        map_seed,player_count,humans,bots,duration,network_mode,source,
        started_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (mid, experiment_id or None, str(meta.get("room_id", "")),
         str(meta.get("mode", "?")), str(meta.get("map", "arena")),
         _i(meta.get("map_seed", 0)), _i(meta.get("player_count", 0)),
         _i(meta.get("humans", 0)), _i(meta.get("bots", 0)),
         _f(meta.get("duration", 0), 0.0), str(meta.get("net", "?")),
         str(meta.get("net", "?")), now_iso()))
    return mid


def store_event(match_id, ev: dict):
    state.db.run(
        "INSERT INTO events(match_id,t,timestamp,type,detail) VALUES (?,?,?,?,?)",
        (match_id, _f(ev.get("t", 0), 0.0), now_iso(),
         str(ev.get("type", "?")), str(ev.get("detail", ev.get("meta", "")))))


# --------------------------------------------------------------------------
# room / session model
# --------------------------------------------------------------------------

def _next_session_id(code):
    # MAX(session_no) rather than COUNT(*) so ids can never collide with an
    # existing row if sessions are ever pruned or renumbered.
    r = state.db.q("SELECT COALESCE(MAX(session_no),0) n FROM sessions "
                   "WHERE room_code=?", (code,))
    n = int(r[0]["n"]) if r else 0
    return f"{code}-S{n+1:03d}", n + 1


# A session is "live" while the room still exists. MATCH_STARTED sets ACTIVE
# and MATCH_ENDED sets MATCH_DONE, but those are still the SAME session -- a
# lookup that only matches 'OPEN' would split one room visit into two
# sessions as soon as a match started.
LIVE_SESSION_STATES = ("OPEN", "ACTIVE", "MATCH_DONE")
_LIVE_SQL = "'OPEN','ACTIVE','MATCH_DONE'"


def ensure_session(code, host_device="", host_name="", experiment_id=""):
    """One open session per room; created when the room appears and closed
    when it empties. Recording therefore spans the PRE-MATCH period."""
    if not code:
        return None
    rows = state.db.q("SELECT * FROM sessions WHERE room_code=? AND status IN (%s)"
                      % _LIVE_SQL, (code,))
    if rows:
        return rows[0]["id"]
    sid, no = _next_session_id(code)
    state.db.run(
        """INSERT INTO sessions(id,session_no,room_code,created_at,host_device,
        player_count,device_count,optimization_mode,status,experiment_id)
        VALUES (?,?,?,?,?,0,0,'PENDING','OPEN',?)""",
        (sid, no, code, now_iso(), host_device or None, experiment_id or None))
    return sid


def close_session(code, reason="room_empty"):
    for r in state.db.q("SELECT id FROM sessions WHERE room_code=? AND status IN (%s)"
                        % _LIVE_SQL, (code,)):
        state.db.run(
            "UPDATE sessions SET ended_at=?, status=? WHERE id=?",
            (now_iso(), reason, r["id"]))
        state.db.run("UPDATE rooms SET empty_at=? WHERE code=?", (now_iso(), code))


REOPEN_GRACE_S = 90.0  # session may be re-opened only this soon after closing


def open_session(code):
    """Recover a session that was closed prematurely (reconnect race, delayed
    guest ROOM_JOINED, duplicate ROOM_CREATED).

    Only the NEWEST session is eligible and only inside a short grace window,
    so a finished recording is never resurrected and history stays immutable.
    Returns the recovered session id, or None when a fresh session is needed.
    """
    if not code:
        return None
    rows = state.db.q(
        "SELECT id, ended_at FROM sessions WHERE room_code=? AND status NOT IN (%s)"
        " ORDER BY session_no DESC, id DESC LIMIT 1" % _LIVE_SQL, (code,))
    if not rows:
        return None
    r = rows[0]
    age = _iso_age(r["ended_at"])
    if age > REOPEN_GRACE_S:
        return None
    state.db.run("UPDATE sessions SET status='OPEN', ended_at=NULL WHERE id=?",
                 (r["id"],))
    return r["id"]


def session_of(code):
    r = state.db.q("SELECT * FROM sessions WHERE room_code=? AND status IN (%s)"
                   % _LIVE_SQL, (code,))
    return r[0] if r else None


def sync_session_counts(sid):
    """Keep session player/device counters honest.

    player_count/device_count = devices currently present; peak_players/
    peak_devices = high-water marks for the whole session. Peaks are stored
    as max() so they only ever grow, even if rows are reconciled later.
    """
    if not sid:
        return
    row = state.db.q(
        "SELECT COUNT(*) n FROM devices WHERE session_id=?", (sid,))
    present = int(row[0]["n"]) if row else 0
    total = state.db.q("SELECT COUNT(*) n FROM devices WHERE session_id=?",
                       (sid,))
    ever = int(total[0]["n"]) if total else 0
    state.db.run(
        "UPDATE sessions SET player_count=?, device_count=?,"
        " peak_players=MAX(COALESCE(peak_players,0),?),"
        " peak_devices=MAX(COALESCE(peak_devices,0),?) WHERE id=?",
        (present, present, ever, ever, sid))


def touch_device(sid, device_id, name="", platform="", role="client"):
    """Upsert a device into the session (reconnect keeps the same row)."""
    if not sid or not device_id:
        return
    now = now_iso()
    row = state.db.q("SELECT * FROM devices WHERE session_id=? AND device_id=?",
                     (sid, device_id))
    if row:
        state.db.run(
            "UPDATE devices SET left_at=NULL, status='CONNECTED', last_seen=?,"
            " name=COALESCE(NULLIF(?,''),name), platform=COALESCE(NULLIF(?,''),platform)"
            " WHERE session_id=? AND device_id=?",
            (now, name, platform, sid, device_id))
    else:
        state.db.run(
            "INSERT INTO devices(session_id,device_id,name,platform,role,"
            "joined_at,status,last_seen) VALUES (?,?,?,?,?,?,'CONNECTED',?)",
            (sid, device_id, name or device_id, platform, role, now, now))
    sync_session_counts(sid)


def device_left(sid, device_id, status="DISCONNECTED"):
    if not sid or not device_id:
        return
    now = now_iso()
    state.db.run("UPDATE devices SET status=?, last_seen=?, left_at=? "
                 "WHERE session_id=? AND device_id=?",
                 (status, now, None if status == "CONNECTED" else now,
                  sid, device_id))
    sync_session_counts(sid)


def session_event(sid, kind, detail, t=0.0):
    state.db.run(
        "INSERT INTO events(match_id,t,timestamp,type,detail) VALUES (?,?,?,?,?)",
        (sid, _f(t, 0.0), now_iso(), kind, str(detail)))


def record_config_change(sid, kind, changes):
    if not sid or not changes:
        return
    for field, pair in (changes or {}).items():
        old = pair.get("from") if isinstance(pair, dict) else None
        new = pair.get("to") if isinstance(pair, dict) else None
        state.db.run(
            "INSERT INTO config_history(session_id,timestamp,kind,field,"
            "old_value,new_value) VALUES (?,?,?,?,?,?)",
            (sid, now_iso(), kind, field, str(old), str(new)))


def _config_label(changes, config=None):
    """Readable one-line summary of a config change for the event timeline.

    Falls back to the effective config when the diff is empty (a re-apply of
    the same settings), so the timeline never shows a bare "[]".
    """
    if changes:
        return ", ".join(
            "%s %s->%s" % (f, (p.get("from") if isinstance(p, dict) else "?"),
                            (p.get("to") if isinstance(p, dict) else "?"))
            for f, p in changes.items())
    if isinstance(config, dict) and config:
        keep = ("algorithm_name", "delta_enabled", "dedup_enabled",
                "compression_enabled", "priority_enabled", "partial_enabled")
        got = [f"{k}={config[k]}" for k in keep if k in config]
        return ("re-applied: " + ", ".join(got)) if got else "re-applied"
    return "re-applied (no field delta)"


def handle_room_event(ev, tel, sid_holder):
    """Room/session lifecycle from game events. Returns the session id."""
    kind = str(ev.get("type", ""))
    det = ev.get("detail", {}) if isinstance(ev.get("detail"), dict) else {}
    code = str(det.get("room_code") or ev.get("room_code") or tel.get("room_code", ""))
    device = str(det.get("device_id") or ev.get("device_id") or tel.get("device_id", ""))
    exp = str(tel.get("experiment_id", "") or "")

    if kind == "ROOM_CREATED":
        state.db.run(
            """INSERT INTO rooms(code,room_id,host_device,host_name,max_players,
            mode,created_at,updated_at,state) VALUES (?,?,?,?,?,?,?,?,'ACTIVE')
            ON CONFLICT(code) DO UPDATE SET updated_at=?, state='ACTIVE',
            empty_at=NULL""",
            (code, str(det.get("room_id", "")), str(det.get("host_device", device)),
             str(det.get("host_name", "")), int(det.get("max_players", 8)),
             str(det.get("mode", "NORMAL")), now_iso(), now_iso(), now_iso()))
        open_session(code)
        sid = ensure_session(code, str(det.get("host_device", device)),
                             str(det.get("host_name", "")), exp)
        if sid:
            touch_device(sid, device, str(det.get("host_name", "")),
                         str(tel.get("platform", "")), "host")
            session_event(sid, "ROOM_CREATED", f"{code} host={det.get('host_name','')}",
                          ev.get("t", 0.0))
        return sid

    if kind in ("ROOM_JOINED", "ROOM_LEFT"):
        if kind == "ROOM_JOINED":
            open_session(code)
        sid = ensure_session(code, experiment_id=exp)
        if not sid:
            return None
        did = str(det.get("device_id") or device or ("player-%s" % det.get("player_id", "?")))
        if kind == "ROOM_JOINED":
            touch_device(sid, did, str(det.get("name", "")), str(det.get("platform", "")))
            session_event(sid, "PLAYER_JOINED",
                          f"{det.get('name','')} [{did}]", ev.get("t", 0.0))
        else:
            device_left(sid, did)
            session_event(sid, "PLAYER_LEFT",
                          f"{det.get('name','')} [{did}]", ev.get("t", 0.0))
            # last device gone -> close the session but KEEP the record
            still = state.db.q(
                "SELECT device_id FROM devices WHERE session_id=? AND left_at IS NULL",
                (sid,))
            if not still:
                close_session(code)
                state.db.run("UPDATE rooms SET state='EMPTY' WHERE code=?", (code,))
                session_event(sid, "SESSION_ENDED", "all devices left",
                              ev.get("t", 0.0))
        return sid

    if kind == "MATCH_STARTED":
        sid = ensure_session(code, experiment_id=exp)
        if sid:
            # The host reports MATCH_STARTED twice (metadata is corrected after
            # the roster is known). The FIRST one wins so match_start_time is
            # never overwritten by a later, skewed timestamp.
            first = not state.db.q("SELECT 1 FROM sessions WHERE id=? AND "
                                   "match_start_time IS NOT NULL", (sid,))
            if first:
                state.db.run("UPDATE sessions SET match_start_time=?, status='ACTIVE'"
                             " WHERE id=?", (now_iso(), sid))
                state.db.run("UPDATE rooms SET match_started_at=?, state='PLAYING'"
                             " WHERE code=?", (now_iso(), code))
                session_event(sid, "MATCH_STARTED", str(tel.get("mode", "")),
                              ev.get("t", 0.0))
        return sid

    if kind == "MATCH_ENDED":
        _row = session_of(code)
        sid = (_row["id"] if _row else None) or ensure_session(code, experiment_id=exp)
        if sid:
            state.db.run("UPDATE sessions SET match_end_time=?, status='MATCH_DONE'"
                         " WHERE id=?", (now_iso(), sid))
            state.db.run("UPDATE rooms SET match_ended_at=?, state='LOBBY'"
                         " WHERE code=?", (now_iso(), code))
            session_event(sid, "MATCH_ENDED", "", ev.get("t", 0.0))
        return sid

    if kind == "OPTIMIZATION_CHANGED":
        _row = session_of(code)
        sid = _row["id"] if _row else None
        if sid:
            _ch = det.get("changes") or {}
            record_config_change(sid, "optimization", _ch)
            session_event(sid, "OPTIMIZATION_CHANGED",
                          _config_label(_ch, det.get("config")),
                          ev.get("t", 0.0))
        return sid

    if kind == "NETWORK_CONFIG_CHANGED":
        _row = session_of(code)
        sid = _row["id"] if _row else None
        if sid:
            _ch = det.get("changes") or {}
            record_config_change(sid, "network", _ch)
            session_event(sid, "NETWORK_CONFIG_CHANGED", _config_label(_ch, None),
                          ev.get("t", 0.0))
        return sid

    if kind == "EXPERIMENT_STARTED":
        _row = session_of(code)
        sid = _row["id"] if _row else None
        if sid and exp:
            state.db.run("UPDATE sessions SET experiment_id=?, optimization_mode=?"
                         " WHERE id=?", (exp, str(tel.get("mode", "")), sid))
        return sid

    return session_of(code)["id"] if session_of(code) else None


def finish_match(match_id):
    rows = state.db.q(
        "SELECT * FROM metric_samples WHERE match_id=? ORDER BY t", (match_id,))
    if not rows:
        return
    def avg(k):
        vs = [r[k] for r in rows if r[k] is not None and r[k] >= 0]
        return sum(vs) / len(vs) if vs else -1.0
    last = rows[-1]
    summary = {
        "match_id": match_id, "samples": len(rows),
        "duration": last["t"], "avg_fps": avg("fps"),
        "avg_frame_ms": avg("frame_ms"), "avg_cpu": avg("cpu"),
        "avg_ram": avg("ram"), "avg_rtt": avg("rtt"),
        "avg_ping": avg("ping"),
        "avg_loss": avg("loss"),
        "bytes_sent": last["bytes_sent"], "bytes_received": last["bytes_recv"],
        "original_bytes": last["orig"], "compressed_bytes": last["comp"],
        "compression_ratio": (last["comp"] / max(1.0, last["orig"])
                              if last["orig"] > 0 else -1.0),
        "reduction_pct": (100.0 * (1.0 - last["comp"] / last["orig"])
                          if last["orig"] > 0 else -1.0),
        "bytes_saved": last["saved"], "deltas": last["deltas"],
        "fulls": last["fulls"],
    }
    state.db.run(
        "UPDATE matches SET ended_at=?, summary_json=? WHERE match_id=?",
        (now_iso(), json.dumps(summary), match_id))
    # stateless experiment linking (survives service restarts): a match
    # carrying an experiment_id lands in the baseline/optimized slot
    # matching its mode, unless that slot is already filled.
    mrow = state.db.q("SELECT experiment_id, mode FROM matches WHERE match_id=?",
                      (match_id,))
    if mrow and mrow[0]["experiment_id"]:
        eid = mrow[0]["experiment_id"]
        erow = state.db.q("SELECT baseline_match_id, optimized_match_id FROM experiments WHERE id=?", (eid,))
        if erow:
            side = "optimized" if "OPTIMIZED" in str(mrow[0]["mode"]) else "baseline"
            col = "optimized_match_id" if side == "optimized" else "baseline_match_id"
            if not erow[0][col]:
                state.db.run(f"UPDATE experiments SET {col}=?, status=? WHERE id=?",
                             (match_id, side + "_done", eid))
    # link into an armed in-memory run (live status transitions)
    for key, run in list(state.pending_runs.items()):
        if run.get("match_id") == match_id or (
                run.get("experiment_id") and match_belongs(match_id, run["experiment_id"])):
            col = "baseline_match_id" if run["side"] == "baseline" else "optimized_match_id"
            state.db.run(f"UPDATE experiments SET {col}=?, status=? WHERE id=?",
                         (match_id, "baseline_done" if run["side"] == "baseline" else "optimized_done",
                          run["experiment_id"]))
            del state.pending_runs[key]


def match_belongs(match_id, exp_id):
    r = state.db.q("SELECT experiment_id FROM matches WHERE match_id=?", (match_id,))
    return bool(r) and r[0]["experiment_id"] == exp_id


def sweep_rooms(grace_s=60.0):
    """Safety net for hosts that vanish without ROOM_LEFT (kill, crash, power
    loss). Devices stop heartbeating, so once every device in an open session
    is stale the room is closed and the recording finalized. Uses only stored
    data and is labeled as a timeout, never invented."""
    # 'OPEN' alone is not enough: MATCH_STARTED moves a session to 'ACTIVE'
    # and MATCH_ENDED to 'MATCH_DONE', and those must still be swept when the
    # host dies mid-match.
    for s in state.db.q("SELECT id, room_code, created_at FROM sessions "
                         "WHERE status IN ('OPEN','ACTIVE','MATCH_DONE')"):
        sid, code = s["id"], s["room_code"]
        rows = state.db.q("SELECT device_id, last_seen FROM devices "
                          "WHERE session_id=?", (sid,))
        # age of the freshest heartbeat; a session that never got one is
        # judged on its own age
        freshest = min([_iso_age(d["last_seen"]) for d in rows] or
                       [_iso_age(s["created_at"])])
        if freshest <= grace_s:
            continue
        if rows:
            state.db.run("UPDATE devices SET status='LOST', left_at=? "
                         "WHERE session_id=? AND left_at IS NULL", (now_iso(), sid))
            sync_session_counts(sid)
            why = "all devices stale >%ds" % int(grace_s)
        else:
            why = "no device ever reported in >%ds" % int(grace_s)
        session_event(sid, "SESSION_ENDED", "host heartbeat lost: " + why)
        close_session(code, "timeout: host lost")
        state.db.run("UPDATE rooms SET state='EMPTY' WHERE code=?", (code,))


def sweep_timeouts():
    """Honest safety net: a match whose game exited without MATCH_ENDED
    (crash/kill/quit-race) is finalized from STORED samples and labeled
    as a timeout — never invented, never shown as live."""
    live_mid = (state.live_tel() or {}).get("match_id", "")
    for m in state.db.q("SELECT match_id FROM matches WHERE ended_at IS NULL"):
        mid = m["match_id"]
        if mid == live_mid and state.conn_state()[0] == "CONNECTED":
            continue
        last = state.db.q("SELECT t FROM metric_samples WHERE match_id=? "
                          "ORDER BY t DESC LIMIT 1", (mid,))
        if not last:
            continue
        age_live = state.conn_state()[1]
        if age_live < 0 or age_live > 45:
            state.db.run(
                "INSERT INTO events(match_id,t,timestamp,type,detail)"
                " VALUES (?,?,?,?,?)",
                (mid, last[0]["t"], now_iso(), "MATCH_ENDED",
                 "timeout finalize: game exited without MATCH_ENDED"))
            finish_match(mid)


SAMPLE_KEYS = ["t", "fps", "frame_ms", "cpu", "ram", "ping", "rtt", "loss",
               "up", "dn", "bytes_sent", "bytes_received", "pkts_sent",
               "pkts_recv", "orig", "comp", "ratio", "comp_us", "decomp_us",
               "deltas", "fulls", "saved", "kills", "deaths"]


@app.post("/api/ingest")
async def ingest(payload: dict):
    try:
        return await _ingest(payload)
    except Exception as e:  # never swallow: surface it, game retries
        print("INGEST ERROR:", type(e).__name__, e)
        traceback.print_exc()
        return JSONResponse({"ok": False, "error": str(e)}, status_code=500)


async def _ingest(payload: dict):
    tel = payload.get("telemetry", payload)
    client = str(payload.get("client", "godot"))
    state.last_seen[client] = time.time()
    state.live[client] = tel
    live_mid = (state.live_tel() or {}).get("match_id", "")
    exp_id = str(tel.get("experiment_id", "") or "")
    code = str(tel.get("room_code", "") or payload.get("room_code", ""))
    dev = str(payload.get("device_id", "") or tel.get("device_id", ""))
    mid = None
    sid = None

    # room/session lifecycle events first (they can create the session)
    for ev in tel.get("events", []) or []:
        et = str(ev.get("type", ""))
        if et in ("ROOM_CREATED", "ROOM_JOINED", "ROOM_LEFT", "MATCH_STARTED",
                  "MATCH_ENDED", "OPTIMIZATION_CHANGED",
                  "NETWORK_CONFIG_CHANGED", "EXPERIMENT_STARTED",
                  "EXPERIMENT_STOPPED"):
            s = handle_room_event(ev, tel, None)
            if s:
                sid = s
            if et in ("MATCH_STARTED", "MATCH_ENDED"):
                mid = ensure_match({"match_id": tel.get("match_id", "")}, exp_id)
            continue
        if et == "MATCH_STARTED":
            mid = ensure_match(ev.get("meta", {}), exp_id)
        if mid or tel.get("match_id"):
            store_event(mid or str(tel.get("match_id", "")), ev)
        if et == "MATCH_ENDED":
            finish_match(str(ev.get("match_id", tel.get("match_id", ""))))

    # a room may exist without any event (client joined before host reporting)
    if code and not sid:
        open_session(code)
        sid = ensure_session(code, experiment_id=exp_id)

    if tel.get("match_id"):
        meta = dict(tel.get("match_meta", {}) or {})
        meta["match_id"] = tel.get("match_id")
        meta.setdefault("mode", tel.get("mode", "?"))
        mid = ensure_match(meta, exp_id)
        if sid:
            state.db.run("UPDATE sessions SET match_id=? WHERE id=? AND match_id IS NULL",
                         (tel.get("match_id"), sid))
        rows = []
        for s in tel.get("new_samples", []) or []:
            rows.append((
                tel.get("match_id"), _f(s.get("t", 0), 0.0), now_iso(),
                str(tel.get("mode", "?")),
                _f(s.get("fps")), _f(s.get("frame_ms")), _f(s.get("cpu")),
                _f(s.get("ram")), _f(s.get("ping")), _f(s.get("rtt")),
                _f(s.get("loss")), _f(s.get("up", 0), 0.0),
                _f(s.get("dn", 0), 0.0), _f(s.get("bytes_sent"), 0.0),
                _f(s.get("bytes_received"), 0.0), _i(s.get("pkts_sent")),
                _i(s.get("pkts_recv")), _f(s.get("orig"), 0.0),
                _f(s.get("comp"), 0.0), _f(s.get("ratio")),
                _f(s.get("comp_us"), 0.0), _f(s.get("decomp_us"), 0.0),
                _i(s.get("deltas")), _i(s.get("fulls")),
                _f(s.get("saved"), 0.0), _i(s.get("kills")),
                _i(s.get("deaths")),
                json.dumps({"codec_flags": tel.get("codec_flags", {}),
                            "net_cfg": tel.get("net_cfg", {})})))
        state.db.insert_samples(rows)
        buf = state.ring.setdefault(str(tel.get("match_id")), [])
        buf.extend(rows)
        del buf[:-7200]

    # per-device session recording (host PC + every guest device)
    if sid and dev:
        touch_device(sid, dev, str(tel.get("device_name", "")),
                     str(tel.get("platform", "")),
                     "host" if tel.get("is_host") else "client")
        s = tel.get("sample", {}) or {}
        ncfg = tel.get("net_cfg", {}) or {}
        state.db.run(
            """INSERT INTO session_samples(session_id,device_id,t,timestamp,
            phase,fps,cpu,ram,up_bps,dn_bps,rtt,ping,loss,bytes_sent,bytes_recv,
            orig,comp,ratio,deltas,fulls,peers) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (sid, dev, _f(s.get("t", 0.0)), now_iso(),
             str(tel.get("phase", "")), _f(s.get("fps")), _f(s.get("cpu")),
             _f(s.get("ram")), _f(s.get("up", 0), 0.0), _f(s.get("dn", 0), 0.0),
             _f(s.get("rtt")), _f(s.get("ping")), _f(s.get("loss")),
             _f(s.get("bytes_sent"), 0.0), _f(s.get("bytes_received"), 0.0),
             _f((tel.get("opt") or {}).get("orig", 0.0)),
             _f((tel.get("opt") or {}).get("comp", 0.0)),
             _f((tel.get("opt") or {}).get("ratio")),
             _i((tel.get("opt") or {}).get("deltas")),
             _i((tel.get("opt") or {}).get("fulls")),
             _i(tel.get("net_peers", 0))))
        # room stays alive while any device is connected
        state.db.run("UPDATE rooms SET updated_at=?, state=CASE WHEN state='EMPTY'"
                     " THEN 'ACTIVE' ELSE state END WHERE code=?",
                     (now_iso(), code))
        open_session(code)

    await broadcast({"type": "LIVE", "stale": False,
                     "telemetry": state.live_tel(),
                     "server_time": time.time(),
                     "connection": state.conn_state()[0]})
    return {"ok": True, "session_id": sid}


# --------------------------------------------------------------------------
# game command queue
# --------------------------------------------------------------------------

def _iso_ago(seconds: float) -> str:
    """Same format as now_iso(), `seconds` in the past (lexicographically sortable)."""
    return datetime.fromtimestamp(time.time() - seconds,
                                  tz=timezone.utc).isoformat()


@app.get("/api/commands")
async def get_commands(client: str = "godot"):
    # Commands nobody ever consumed (game was closed/restarting) must not
    # fire later against a room that has moved on -- expire them.
    state.db.run(
        "UPDATE commands SET status='EXPIRED', result='no consumer within 120s'"
        " WHERE status='QUEUED' AND created_at<?", (_iso_ago(120.0),))
    rows = state.db.q(
        "SELECT * FROM commands WHERE target=? AND status='QUEUED' ORDER BY id",
        (client,))
    out = [{"id": str(r["id"]), "cmd": r["cmd"],
            "params": json.loads(r["params_json"] or "{}")} for r in rows]
    return {"commands": out}


@app.post("/api/ack")
async def ack(payload: dict):
    state.db.run("UPDATE commands SET status=?, result=? WHERE id=?",
                 (str(payload.get("status", "DONE")),
                  str(payload.get("detail", ""))[:500],
                  int(payload.get("id", -1))))
    await broadcast({"type": "CMD_ACK", "ack": payload})
    return {"ok": True}


def queue_command(cmd: str, params: dict, target: str = "godot"):
    return state.db.run(
        "INSERT INTO commands(created_at,target,cmd,params_json,status,result)"
        " VALUES (?,?,?,?,?,?)",
        (now_iso(), target, cmd, json.dumps(params), "QUEUED", ""))


@app.post("/api/send-command")
async def send_command(payload: dict):
    cmd = str(payload.get("cmd", ""))
    params = payload.get("params", {}) or {}
    err = validate_command(cmd, params)
    if err:
        return JSONResponse({"ok": False, "error": err}, status_code=400)
    cid = queue_command(cmd, params)
    return {"ok": True, "id": cid, "note": "COMMAND SENT (game ACKs on poll)"}


# --------------------------------------------------------------------------
# held ("pending") join requests -- host asks the dashboard to accept/reject
# --------------------------------------------------------------------------

PENDING_FIELDS = ("name", "avatar", "device", "device_name", "platform",
                  "approver")


@app.post("/api/rooms/{code}/pending")
async def add_pending(code: str, payload: dict):
    """Host registers a join it is holding (settings.approve_joins on)."""
    peer = payload.get("peer")
    if peer is None:
        return JSONResponse({"ok": False, "error": "peer required"},
                            status_code=400)
    vals = {k: str(payload.get(k, "") or "") for k in PENDING_FIELDS}
    lid = state.db.run(
        """INSERT INTO pending_joins(code,peer,name,avatar,device,
        device_name,platform,players,max_players,approver,created_at,status)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
        (code, int(peer), vals["name"], int(payload.get("avatar") or 0),
         vals["device"], vals["device_name"], vals["platform"],
         int(payload.get("players") or 0), int(payload.get("max_players") or 0),
         vals["approver"], now_iso(), "pending"))
    row = (state.db.q("SELECT * FROM pending_joins WHERE id=?", (lid,)) or [{}])[0]
    await broadcast({"type": "PENDING_JOINS", "code": code})
    return {"ok": True, "id": lid, "join": _pending_public(row)}


def _pending_public(r: dict) -> dict:
    return {"id": int(r.get("id") or 0), "code": r.get("code", ""),
            "peer": int(r.get("peer") or 0), "name": r.get("name", ""),
            "avatar": int(r.get("avatar") or 0), "device": r.get("device", ""),
            "device_name": r.get("device_name", ""),
            "platform": r.get("platform", ""),
            "players": int(r.get("players") or 0),
            "max_players": int(r.get("max_players") or 0),
            "status": r.get("status", "pending"),
            "created_at": r.get("created_at", "")}


@app.get("/api/rooms/{code}/pending")
async def list_pending(code: str, include_done: int = 0):
    q = "SELECT * FROM pending_joins WHERE code=?"
    args = [code]
    if not include_done:
        q += " AND status IN ('pending','approved','rejected')"
    q += " ORDER BY id DESC LIMIT 50"
    return {"pending": [_pending_public(r) for r in state.db.q(q, args)]}


@app.post("/api/pending/{pid}/decision")
async def decide_pending(pid: int, payload: dict):
    """Dashboard Accept/Reject -> device-agnostic game command + status flip."""
    action = str(payload.get("action", ""))
    if action not in ("approve", "reject"):
        return JSONResponse({"ok": False, "error": "action must be approve|reject"},
                            status_code=400)
    rows = state.db.q("SELECT * FROM pending_joins WHERE id=?", (pid,))
    if not rows:
        return JSONResponse({"ok": False, "error": "unknown join request"},
                            status_code=404)
    r = rows[0]
    if r["status"] != "pending":
        return JSONResponse({"ok": False, "error": "already %s" % r["status"]},
                            status_code=409)
    status = "approved" if action == "approve" else "rejected"
    state.db.run("UPDATE pending_joins SET status=?, decided_at=? WHERE id=?",
                 (status, now_iso(), pid))
    queue_command("approve_join" if action == "approve" else "reject_join",
                  {"peer": int(r["peer"]), "code": r["code"],
                   "pending": int(pid), "name": r["name"] or "Guest"})
    await broadcast({"type": "PENDING_JOINS", "code": r["code"]})
    return {"ok": True, "id": pid, "status": status}


@app.post("/api/pending/resolve")
async def resolve_pending(payload: dict):
    """Host confirms a held join is finished (decision applied, or it
    auto-approved / expired with nobody watching). Matched by (code, peer)
    because the host may never have learned this row's id."""
    code = str(payload.get("code", ""))
    try:
        peer = int(payload.get("peer", -1))
    except (TypeError, ValueError):
        peer = -1
    status = str(payload.get("status", "done"))
    if status not in ("approved", "rejected", "done"):
        return JSONResponse({"ok": False, "error": "bad status"},
                            status_code=400)
    rows = state.db.q(
        "SELECT * FROM pending_joins WHERE code=? AND peer=? AND status!='done'"
        " ORDER BY id DESC LIMIT 1", (code, peer))
    if not rows:
        return {"ok": True, "note": "nothing open for that peer"}
    state.db.run("UPDATE pending_joins SET status=?, decided_at=? WHERE id=?",
                 (status, now_iso(), int(rows[0]["id"])))
    await broadcast({"type": "PENDING_JOINS", "code": code})
    return {"ok": True, "id": int(rows[0]["id"]), "status": status}


def validate_command(cmd: str, p: dict):
    known = {"ping", "set_opt", "set_net", "start_metrics", "stop_metrics",
             "experiment_start", "experiment_stop", "start_match", "stop_match",
             "pause"}
    if cmd not in known:
        return f"unknown command: {cmd}"
    if cmd == "start_match" or cmd == "stop_match" or cmd == "pause":
        return ""  # host/state validation happens in the game
    if cmd == "set_net":
        if "update_hz" in p:
            try:
                hz = float(p["update_hz"])
            except (TypeError, ValueError):
                return "update_hz must be a number"
            if hz < 5 or hz > 60:
                return "update_hz %.1f out of range 5..60" % hz
        if "budget_kbps" in p:
            try:
                b = float(p["budget_kbps"])
            except (TypeError, ValueError):
                return "budget_kbps must be a number"
            if b < 0 or b > 100000:
                return "budget_kbps %.1f out of range 0..100000" % b
        if "max_packet" in p:
            try:
                mp = int(p["max_packet"])
            except (TypeError, ValueError):
                return "max_packet must be an integer"
            if mp != 0 and (mp < 256 or mp > 1048576):
                return "max_packet %d out of range 256..1048576" % mp
        for k, hi in (("latency_ms", 5000), ("jitter_ms", 5000), ("loss_pct", 100)):
            if k in p:
                try:
                    v = float(p[k])
                except (TypeError, ValueError):
                    return f"{k} must be a number"
                if v < 0 or v > hi:
                    return f"{k}={v} out of range 0..{hi}"
        for k in ("medium_pct", "low_pct"):
            if k in p:
                try:
                    v = int(p[k])
                except (TypeError, ValueError):
                    return f"{k} must be an integer"
                if v < 0 or v > 100:
                    return f"{k}={v} out of range 0..100"
    if cmd == "set_opt":
        for k in ("medium_every", "full_every", "algorithm"):
            if k in p:
                try:
                    int(p[k])
                except (TypeError, ValueError):
                    return f"{k} must be an integer"
        me = int(p.get("medium_every", 1))
        fe = int(p.get("full_every", 1))
        al = int(p.get("algorithm", 0))
        if me < 1 or me > 60:
            return "medium_every out of range 1..60"
        if fe < 1 or fe > 600:
            return "full_every out of range 1..600"
        if al < 0 or al > 3:
            return "algorithm out of range 0..3"
    return ""


# --------------------------------------------------------------------------
# live / status
# --------------------------------------------------------------------------

@app.get("/api/status")
async def status():
    sweep_timeouts()
    sweep_rooms()
    st, age = state.conn_state()
    return {"connection": st, "age_s": age,
            "matches": state.db.q("SELECT COUNT(*) c FROM matches")[0]["c"],
            "experiments": state.db.q("SELECT COUNT(*) c FROM experiments")[0]["c"],
            "auto_launch": state.args.auto_launch,
            "game_path": state.args.game_path}


def _match_status(r, sess):
    if r["match_started_at"] and r["match_ended_at"]:
        return "ENDED"
    if not r["match_started_at"]:
        return "NOT STARTED"
    # started but never ended: live only if the room/session is still open
    live_states = LIVE_SESSION_STATES
    if sess is not None and str(sess["status"]) in live_states:
        return "RUNNING"
    return "TIMEOUT (host lost)"


@app.get("/api/live")
async def live():
    return state.live_payload()


@app.get("/health")
async def health():
    """Health check endpoint for monitoring."""
    return {"status": "ok", "service": "CloudArena Monitor", "timestamp": time.time()}


@app.get("/api/rooms")
async def rooms():
    """Active rooms + their open session summary (room-centric dashboard)."""
    out = []
    for r in state.db.q("SELECT * FROM rooms ORDER BY created_at DESC"):
        code = r["code"]
        sess = session_of(code)
        devs = []
        if sess:
            devs = state.db.q(
                "SELECT * FROM devices WHERE session_id=? ORDER BY joined_at", (sess["id"],))
        conn = [d for d in devs if not d["left_at"]]
        last = state.db.q(
            "SELECT * FROM session_samples WHERE session_id=? ORDER BY t DESC LIMIT 1",
            (sess["id"],)) if sess else []
        out.append({
            "code": code, "room_id": r["room_id"],
            "state": r["state"], "mode": r["mode"],
            "host_device": r["host_device"], "host_name": r["host_name"],
            "created_at": r["created_at"],
            "match_started_at": r["match_started_at"],
            "match_ended_at": r["match_ended_at"],
            "session_id": sess["id"] if sess else None,
            "session_no": sess["session_no"] if sess else None,
            "session_status": sess["status"] if sess else "NONE",
            "session_started": sess["created_at"] if sess else None,
            "session_elapsed": _session_elapsed(sess) if sess else 0.0,
            "match_elapsed": _match_elapsed(r) if r else 0.0,
            "players": len(conn), "max_players": r["max_players"] or 8,
            "devices": len(devs), "devices_connected": len(conn),
            # An unterminated match is only "RUNNING" while the room is
            # actually live. If the host died, report it as a timeout rather
            # than showing RUNNING forever.
            "match_status": _match_status(r, sess),
            "optimization": _session_opt(sess, last[0] if last else None),
            "bandwidth_kbps": _session_bw(sess, last[0] if last else None),
            "last_fps": (last[0]["fps"] if last and last[0]["fps"] is not None else -1),
            "last_rtt": (last[0]["rtt"] if last and last[0]["rtt"] is not None else -1),
            "last_update": last[0]["timestamp"] if last else None,
        })
    return {"rooms": out, "server_time": time.time(),
            "connection": state.conn_state()[0]}


def _parse_iso(s):
    if not s:
        return 0.0
    try:
        from datetime import datetime as _dt
        return (_dt.fromisoformat(s) - _dt.now(_dt.now().astimezone().tzinfo)).total_seconds()
    except Exception:
        return 0.0


def _iso_age(s):
    """Seconds elapsed since an ISO timestamp.

    Unlike _parse_iso (which returns a NEGATIVE offset from now), this is a
    non-negative age: 0.0 means "just now", and 1e9 means unparseable. Use
    this for heartbeat/staleness decisions so the sign is never ambiguous.
    """
    if not s:
        return 1e9
    off = _parse_iso(s)
    if off == 0.0:
        return 1e9
    return max(0.0, -off)


def _session_elapsed(s):
    if not s:
        return 0.0
    end = s["ended_at"] or now_iso()
    try:
        from datetime import datetime as _dt
        a = _dt.fromisoformat(s["created_at"])
        b = _dt.fromisoformat(end)
        return max(0.0, (b - a).total_seconds())
    except Exception:
        return 0.0


def _match_elapsed(r):
    if not r["match_started_at"]:
        return 0.0
    end = r["match_ended_at"] or now_iso()
    try:
        from datetime import datetime as _dt
        a = _dt.fromisoformat(r["match_started_at"])
        b = _dt.fromisoformat(end)
        return max(0.0, (b - a).total_seconds())
    except Exception:
        return 0.0


def _session_opt(sess, last_sample):
    if not sess:
        return "UNKNOWN"
    if last_sample and last_sample["orig"] is not None and last_sample["orig"] > 0:
        return "ENABLED" if last_sample["comp"] < last_sample["orig"] else "NORMAL"
    return str(sess["optimization_mode"] or "PENDING")


def _session_bw(sess, last_sample):
    if not sess:
        return 0
    try:
        cfg = json.loads(sess["network_config"] or "{}")
        if cfg.get("budget_kbps"):
            return float(cfg["budget_kbps"])
    except Exception:
        pass
    return 0


@app.get("/api/rooms/{code}")
async def room_detail(code: str):
    r = state.db.q("SELECT * FROM rooms WHERE code=?", (code,))
    if not r:
        return JSONResponse({"error": "room not found"}, status_code=404)
    room = dict(r[0])
    sess = session_of(code)
    if not sess:
        hist = state.db.q("SELECT * FROM sessions WHERE room_code=? ORDER BY id DESC",
                          (code,))
        sess = hist[0] if hist else None
    if not sess:
        return {"room": room, "session": None, "devices": [], "events": []}
    sid = sess["id"]
    devs = state.db.q("SELECT * FROM devices WHERE session_id=? ORDER BY joined_at", (sid,))
    per_device = {}
    for d in devs:
        rows = state.db.q(
            """SELECT AVG(fps) fps, AVG(rtt) rtt, AVG(ping) ping, AVG(loss) loss,
            AVG(cpu) cpu, AVG(ram) ram, MAX(t) last_t
            FROM session_samples WHERE session_id=? AND device_id=?""",
            (sid, d["device_id"]))
        per_device[d["device_id"]] = rows[0] if rows else {}
    return {
        "room": room, "session": dict(sess), "devices": [dict(d) for d in devs],
        "device_metrics": per_device,
        "events": state.db.q(
            "SELECT * FROM events WHERE match_id=? ORDER BY id", (sid,)),
        "config_history": state.db.q(
            "SELECT * FROM config_history WHERE session_id=? ORDER BY id", (sid,)),
        "session_elapsed": _session_elapsed(sess),
        "match_elapsed": _match_elapsed(room),
    }


@app.get("/api/sessions")
async def session_history():
    return {"sessions": state.db.q(
        "SELECT * FROM sessions ORDER BY created_at DESC LIMIT 200")}


@app.get("/api/sessions/{sid}")
async def session_detail(sid: str):
    s = state.db.q("SELECT * FROM sessions WHERE id=?", (sid,))
    if not s:
        return JSONResponse({"error": "session not found"}, status_code=404)
    return {
        "session": s[0],
        "room": (state.db.q("SELECT * FROM rooms WHERE code=?", (s[0]["room_code"],)) or [{}])[0],
        "devices": state.db.q("SELECT * FROM devices WHERE session_id=?", (sid,)),
        "samples": state.db.q(
            "SELECT * FROM session_samples WHERE session_id=? ORDER BY t", (sid,)),
        "events": state.db.q("SELECT * FROM events WHERE match_id=? ORDER BY id", (sid,)),
        "config_history": state.db.q(
            "SELECT * FROM config_history WHERE session_id=? ORDER BY id", (sid,)),
        "report": session_report(sid),
    }


def session_report(sid: str):
    """Final session report computed ONLY from stored samples."""
    rows = state.db.q("SELECT * FROM session_samples WHERE session_id=? ORDER BY t", (sid,))
    s = state.db.q("SELECT * FROM sessions WHERE id=?", (sid,))
    if not rows or not s:
        return {"ok": False, "error": "no samples"}

    def col(k, per_device=True):
        if not per_device:
            return [r[k] for r in rows if r[k] is not None and r[k] >= 0]
        agg = {}
        for r in rows:
            if r[k] is not None and r[k] >= 0:
                agg.setdefault(r["device_id"], []).append(r[k])
        return [v for vs in agg.values() for v in vs]

    def avg(vals):
        return sum(vals) / len(vals) if vals else -1.0

    fps = col("fps")
    last = rows[-1]
    orig = last["orig"] or 0.0
    comp = last["comp"] or 0.0
    devs = state.db.q("SELECT COUNT(*) c FROM devices WHERE session_id=?", (sid,))
    return {
        "ok": True,
        "session_id": sid,
        "room_code": s[0]["room_code"],
        "players": devs[0]["c"] if devs else 0,
        "samples": len(rows),
        "duration_s": last["t"],
        "avg_fps": avg(fps), "min_fps": min(fps) if fps else -1,
        "max_fps": max(fps) if fps else -1,
        "p1_low_fps": (sorted(fps)[max(0, int(len(fps) * 0.01) - 1)] if fps else -1),
        "avg_rtt": avg(col("rtt")), "avg_ping": avg(col("ping")),
        "avg_loss": avg(col("loss")),
        "avg_cpu": avg(col("cpu")), "avg_ram": avg(col("ram")),
        "avg_up": avg(col("up_bps")), "avg_dn": avg(col("dn_bps")),
        "total_sent": last["bytes_sent"], "total_recv": last["bytes_recv"],
        "original": orig, "transferred": comp,
        "reduction_pct": (100.0 * (1 - comp / orig)) if orig > 0 else -1,
        "optimization_mode": s[0]["optimization_mode"],
        "status": s[0]["status"],
    }


@app.get("/api/rooms/{code}/samples")
async def room_samples(code: str, stride: int = 1, device_id: str = ""):
    sess = session_of(code)
    if not sess:
        hist = state.db.q("SELECT * FROM sessions WHERE room_code=? ORDER BY id DESC",
                          (code,))
        sess = hist[0] if hist else None
    if not sess:
        return {"samples": [], "count": 0}
    if device_id:
        rows = state.db.q(
            "SELECT * FROM session_samples WHERE session_id=? AND device_id=? ORDER BY t",
            (sess["id"], device_id))
    else:
        rows = state.db.q("SELECT * FROM session_samples WHERE session_id=? ORDER BY t",
                          (sess["id"],))
    if stride > 1:
        rows = rows[::stride]
    return {"count": len(rows), "samples": rows, "session_id": sess["id"]}
@app.get("/api/sessions/compare")
async def compare_sessions(a: str, b: str):
    """Side-by-side of two recorded sessions (no verdict, values only)."""
    out = {}
    for sid in (a, b):
        s = state.db.q("SELECT * FROM sessions WHERE id=?", (sid,))
        if not s:
            return JSONResponse({"error": f"session not found: {sid}"}, status_code=404)
        rep = session_report(sid)
        rep["session"] = dict(s[0])
        rep["devices"] = state.db.q(
            "SELECT * FROM devices WHERE session_id=?", (sid,))
        rep["config_history"] = state.db.q(
            "SELECT * FROM config_history WHERE session_id=? ORDER BY id", (sid,))
        out[sid] = rep
    # experimental conditions visible so the user can judge comparability
    conds = {}
    for sid, rep in out.items():
        conds[sid] = {
            "room": rep["session"]["room_code"],
            "players": rep["players"],
            "mode": rep["session"]["optimization_mode"],
            "bandwidth": _session_bw(rep["session"], None),
            "network": rep["session"]["network_config"],
            "optimization": rep["session"]["optimization_config"],
            "duration_s": rep["duration_s"],
        }
    same = (conds[a]["players"] == conds[b]["players"]
            and abs(conds[a]["bandwidth"] - conds[b]["bandwidth"]) < 0.01)
    return {"a": out[a], "b": out[b], "conditions": conds,
            "conditions_match": same,
            "note": "Values are measured; no configuration is declared better."}


@app.get("/api/sessions/export/{sid}")
async def export_session(sid: str, format: str = "json"):
    s = state.db.q("SELECT * FROM sessions WHERE id=?", (sid,))
    if not s:
        return JSONResponse({"error": "session not found"}, status_code=404)
    payload = {
        "session": s[0],
        "room": (state.db.q("SELECT * FROM rooms WHERE code=?", (s[0]["room_code"],)) or [{}])[0],
        "devices": state.db.q("SELECT * FROM devices WHERE session_id=?", (sid,)),
        "samples": state.db.q("SELECT * FROM session_samples WHERE session_id=? ORDER BY t",
                              (sid,)),
        "events": state.db.q("SELECT * FROM events WHERE match_id=? ORDER BY id", (sid,)),
        "config_history": state.db.q(
            "SELECT * FROM config_history WHERE session_id=? ORDER BY id", (sid,)),
        "report": session_report(sid),
    }
    if format == "csv":
        rows = payload["samples"]
        buf = io.StringIO()
        w = csv.writer(buf)
        if rows:
            w.writerow(list(rows[0].keys()))
            for r in rows:
                w.writerow(list(r.values()))
        return PlainTextResponse(buf.getvalue(), media_type="text/csv",
                                 headers={"Content-Disposition":
                                          f"attachment; filename={sid}.csv"})
    return JSONResponse(payload, headers={"Content-Disposition":
                                          f"attachment; filename={sid}.json"})


@app.get("/api/devices/{sid}")
async def session_devices(sid: str):
    return {"devices": state.db.q(
        "SELECT * FROM devices WHERE session_id=? ORDER BY joined_at", (sid,))}


@app.get("/api/peer-status")
async def peer_status():
    """Live peer/connection facts, straight from the game (no guessing)."""
    tel = state.live_tel()
    conn, age = state.conn_state()
    return {
        "connection": conn, "age_s": age,
        "stale": conn != "CONNECTED",
        "match_id": tel.get("match_id", ""),
        "phase": tel.get("phase", ""),
        "mode": tel.get("mode", ""),
        "net_mode": tel.get("net_host", ""),
        "net_connected": tel.get("net_connected", False),
        "peers": tel.get("net_peers", 0),
        "rtt": (tel.get("sample", {}) or {}).get("rtt", -1.0),
        "ping": (tel.get("sample", {}) or {}).get("ping", -1.0),
        "loss": (tel.get("sample", {}) or {}).get("loss", -1.0),
    }


# --------------------------------------------------------------------------
# samples / matches / events
# --------------------------------------------------------------------------

@app.get("/api/matches")
async def matches():
    rows = state.db.q(
        """SELECT match_id,experiment_id,room_id,mode,map,map_seed,
        player_count,humans,bots,duration,network_mode,source,started_at,
        ended_at,summary_json FROM matches ORDER BY started_at DESC LIMIT 200""")
    for r in rows:
        try:
            r["summary"] = json.loads(r.pop("summary_json") or "{}")
        except Exception:
            r.pop("summary_json", None)
            r["summary"] = {}
    return {"matches": rows}


@app.get("/api/matches/{mid}")
async def match_detail(mid: str):
    m = state.db.q("SELECT * FROM matches WHERE match_id=?", (mid,))
    if not m:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"match": m[0]}


@app.get("/api/samples")
async def samples(match_id: str, t0: float = 0.0, t1: float = 1e12,
                  stride: int = 1):
    rows = state.db.q(
        """SELECT * FROM metric_samples WHERE match_id=? AND t>=? AND t<=?
        ORDER BY t""", (match_id, t0, t1))
    if stride > 1:
        rows = rows[::stride]
    return {"match_id": match_id, "count": len(rows), "samples": rows}


@app.get("/api/events")
async def events(match_id: str = ""):
    if match_id:
        rows = state.db.q("SELECT * FROM events WHERE match_id=? ORDER BY id",
                          (match_id,))
    else:
        rows = state.db.q("SELECT * FROM events ORDER BY id DESC LIMIT 200")
    return {"events": rows}


# --------------------------------------------------------------------------
# experiments
# --------------------------------------------------------------------------

def default_exp_config():
    return {"map": "arena", "map_seed": 1234, "players": 8, "humans": 1,
            "bots": 7, "duration": 180, "network": "REAL", "bandwidth_kbps": 0,
            "latency_ms": 0, "jitter_ms": 0, "loss_pct": 0, "rate": 20,
            "peer": False, "port": 7777,
            "opt_flags": ["delta", "dedup", "compression", "priority",
                          "partial"]}


@app.post("/api/experiments")
async def create_experiment(payload: dict):
    name = str(payload.get("name", "experiment")).strip()[:80] or "experiment"
    cfg = default_exp_config()
    for k in cfg:
        if k in payload:
            cfg[k] = payload[k]
    exp_id = "exp%03d" % (1 + len(state.db.q("SELECT id FROM experiments")))
    state.db.run(
        "INSERT INTO experiments(id,name,created_at,status,notes,config_json)"
        " VALUES (?,?,?,?,?,?)",
        (exp_id, name, now_iso(), "created",
         str(payload.get("notes", ""))[:500], json.dumps(cfg)))
    return {"ok": True, "id": exp_id, "config": cfg}


@app.get("/api/experiments")
async def list_experiments():
    return {"experiments": state.db.q("SELECT * FROM experiments ORDER BY id")}


@app.get("/api/experiments/{eid}")
async def get_experiment(eid: str):
    r = state.db.q("SELECT * FROM experiments WHERE id=?", (eid,))
    if not r:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"experiment": r[0]}


@app.delete("/api/experiments/{eid}")
async def delete_experiment(eid: str):
    r = state.db.q("SELECT * FROM experiments WHERE id=?", (eid,))
    if not r:
        return JSONResponse({"error": "not found"}, status_code=404)
    if r[0]["status"] in ("baseline_running", "optimized_running",
                          "benchmark_running"):
        return JSONResponse(
            {"error": "experiment is running; stop it first"}, status_code=409)
    state.db.run("DELETE FROM experiments WHERE id=?", (eid,))
    return {"ok": True}


def run_side(eid: str, side: str):
    """Arm + optionally auto-launch one side (baseline|optimized)."""
    r = state.db.q("SELECT * FROM experiments WHERE id=?", (eid,))
    if not r:
        return {"ok": False, "error": "experiment not found"}
    exp = r[0]
    if exp["status"] in ("baseline_running", "optimized_running",
                         "benchmark_running"):
        return {"ok": False, "error": "experiment already running"}
    cfg = json.loads(exp["config_json"] or "{}")
    mode = "NORMAL" if side == "baseline" else "OPTIMIZED"
    flags = [] if side == "baseline" else cfg.get("opt_flags", [])
    run_id = f"{eid}-{side}"
    state.pending_runs[run_id] = {"experiment_id": eid, "side": side,
                                  "match_id": None}
    state.db.run("UPDATE experiments SET status=? WHERE id=?",
                 ("baseline_running" if side == "baseline" else "optimized_running",
                  eid))
    launched = False
    port = int(cfg.get("port", 7777))
    rf = str(_room_file(eid))
    if state.args.auto_launch:
        launched = launch_headless(eid, side, mode, cfg, flags,
                                   peer=bool(cfg.get("peer", False)),
                                   roomfile=rf, port=port)
    else:
        queue_command("experiment_start", {"experiment_id": eid})
    return {"ok": True, "run": run_id, "mode": mode,
            "launched": launched,
            "note": ("game auto-launched" if launched else
                     "run the game manually with experiment_id=" + eid)}


def launch_headless(eid, side, mode, cfg, flags, peer=False, code=None,
                    roomfile=None, port=7777):
    cmd = ["flatpak", "run", "org.godotengine.Godot", "--headless",
           "--path", state.args.game_path,
           "--script", "res://tests/ExperimentRun.gd", "--",
           f"--mode={mode}", f"--seed={int(cfg.get('map_seed', 1234))}",
           f"--dur={int(cfg.get('duration', 180))}", f"--exp={eid}",
           f"--mon={state.args.port}", f"--rate={float(cfg.get('rate', 20))}",
           f"--budget={float(cfg.get('bandwidth_kbps', 0))}",
           f"--lat={float(cfg.get('latency_ms', 0))}",
           f"--jit={float(cfg.get('jitter_ms', 0))}",
           f"--loss={float(cfg.get('loss_pct', 0))}",
           f"--sim_bw={float(cfg.get('bandwidth_kbps', 0))}",
           f"--port={port}"]
    if roomfile:
        cmd.append(f"--roomfile={roomfile}")
    if peer:
        # host waits (non-blocking) for the real guest to join the lobby
        cmd.append("--peer=1")
    cmd.append("--flags=" + (",".join(flags) if flags
                             else "nodelta,nodedup,nocompression,nopriority,partial"))
    try:
        log = open(HERE / f"run_{eid}_{side}.log", "w")
        subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
        if False and peer and code:
            # real second peer so the host measures genuine RTT / ping /
            # loss instead of reporting N/A. Launched from the service
            # because the game process cannot spawn peers in the sandbox.
            peer_cmd = ["flatpak", "run", "org.godotengine.Godot", "--headless",
                        "--path", state.args.game_path,
                        "--script", "res://tests/ExperimentRun.gd", "--",
                        "--role=guest", f"--code={code}",
                        f"--dur={int(cfg.get('duration', 180))}",
                        f"--exp={eid}", f"--mon={state.args.port}",
                        f"--port={port}"]
            plog = open(HERE / f"run_{eid}_{side}_peer.log", "w")
            subprocess.Popen(peer_cmd, stdout=plog, stderr=subprocess.STDOUT)
        return True
    except Exception as e:
        state.db.run("UPDATE experiments SET status=? WHERE id=?",
                     ("failed", eid))
        print("launch failed:", e)
        return False


def _room_file(eid):
    return HERE / f"room_{eid}.txt"


def peer_watch(eid, side, mode, cfg, flags, port=7777):
    """Background: wait for the host to publish its room code, then start
    the real guest process. Runs in a thread so the API stays responsive."""
    rf = _room_file(eid)
    try:
        if rf.exists():
            rf.unlink()
    except OSError:
        pass
    code = None
    deadline = time.time() + 40
    while time.time() < deadline:
        try:
            if rf.exists():
                c = rf.read_text().strip()
                if len(c) == 6 and c.isdigit():
                    code = c
                    break
        except OSError:
            pass
        if state.bench["stop"]:
            return
        time.sleep(0.4)
    if code:
        launch_headless(eid, side + "_peer", mode, cfg, flags,
                        peer=True, code=code, port=port)
        print(f"peer for {eid} launched with code {code}")
    else:
        print(f"peer for {eid}: no room code appeared")


@app.post("/api/experiments/{eid}/start")
async def start_side(eid: str, payload: dict):
    side = str(payload.get("side", "baseline"))
    if side not in ("baseline", "optimized"):
        return JSONResponse({"error": "side must be baseline|optimized"},
                            status_code=400)
    return run_side(eid, side)


@app.post("/api/experiments/{eid}/stop")
async def stop_side(eid: str):
    for k in [k for k, v in state.pending_runs.items()
              if v["experiment_id"] == eid]:
        del state.pending_runs[k]
    state.db.run("UPDATE experiments SET status=? WHERE id=?",
                 ("stopped", eid))
    return {"ok": True}


# --------------------------------------------------------------------------
# compare
# --------------------------------------------------------------------------

def summarize_match(mid: str):
    rows = state.db.q(
        "SELECT * FROM metric_samples WHERE match_id=? ORDER BY t", (mid,))
    m = state.db.q("SELECT * FROM matches WHERE match_id=?", (mid,))
    if not rows or not m:
        return None
    def avg(k):
        vs = [r[k] for r in rows if r[k] is not None and r[k] >= 0]
        return sum(vs) / len(vs) if vs else -1.0
    last = rows[-1]
    return {
        "match_id": mid, "mode": m[0]["mode"], "map": m[0]["map"],
        "map_seed": m[0]["map_seed"], "players": m[0]["player_count"],
        "humans": m[0]["humans"], "bots": m[0]["bots"],
        "duration": last["t"], "network": m[0]["network_mode"],
        "source": m[0]["source"], "samples": len(rows),
        "data": last["comp"], "data_orig": last["orig"],
        "avg_up": avg("up_bps"), "avg_dn": avg("dn_bps"),
        "avg_rtt": avg("rtt"), "avg_ping": avg("ping"),
        "avg_fps": avg("fps"), "avg_cpu": avg("cpu"), "avg_ram": avg("ram"),
        "loss": avg("loss"),
        "ratio": (last["comp"] / max(1.0, last["orig"])
                  if last["orig"] > 0 else -1.0),
        "reduction": (100.0 * (1.0 - last["comp"] / last["orig"])
                      if last["orig"] > 0 else -1.0),
        "deltas": last["deltas"], "fulls": last["fulls"],
        "saved": last["saved"],
    }


def compatibility(a: dict, b: dict):
    reasons = []
    if a["map"] != b["map"]:
        reasons.append(f"map differs ({a['map']} vs {b['map']})")
    if a["map_seed"] != b["map_seed"]:
        reasons.append(f"map_seed differs ({a['map_seed']} vs {b['map_seed']})")
    if a["players"] != b["players"]:
        reasons.append(f"player count differs ({a['players']} vs {b['players']})")
    if a["bots"] != b["bots"]:
        reasons.append(f"bot count differs ({a['bots']} vs {b['bots']})")
    if abs(a["duration"] - b["duration"]) > max(5.0, 0.1 * max(a["duration"], 1)):
        reasons.append("duration differs >10%% (%.0fs vs %.0fs)" % (a["duration"], b["duration"]))
    if a["network"] != b["network"]:
        reasons.append(f"network differs ({a['network']} vs {b['network']})")
    return reasons


@app.get("/api/compare")
async def compare(a: str, b: str):
    sa, sb = summarize_match(a), summarize_match(b)
    if not sa or not sb:
        return JSONResponse({"error": "one or both matches have no data"},
                            status_code=404)
    reasons = compatibility(sa, sb)
    base, opt = (sa, sb) if "OPTIMIZED" in str(sb.get("mode", "")) or \
        "NORMAL" in str(sa.get("mode", "")) else (sb, sa)
    keys = ["data", "avg_up", "avg_dn", "avg_rtt", "avg_ping", "avg_fps",
            "avg_cpu", "avg_ram", "loss", "ratio"]
    delta = {}
    for k in keys:
        va, vo = base.get(k, -1), opt.get(k, -1)
        if va is not None and vo is not None and va >= 0 and vo >= 0 and va != 0:
            delta[k] = 100.0 * (vo - va) / abs(va)
        else:
            delta[k] = None
    return {"a": sa, "b": sb, "base_id": base["match_id"],
            "opt_id": opt["match_id"], "compatible": not reasons,
            "reasons": reasons, "delta_pct": delta}


@app.get("/api/exp-compare/{eid}")
async def exp_compare(eid: str):
    r = state.db.q("SELECT * FROM experiments WHERE id=?", (eid,))
    if not r or not r[0]["baseline_match_id"] or not r[0]["optimized_match_id"]:
        return JSONResponse(
            {"error": "experiment needs both baseline and optimized matches"},
            status_code=404)
    return await compare(r[0]["baseline_match_id"], r[0]["optimized_match_id"])


# --------------------------------------------------------------------------
# configs
# --------------------------------------------------------------------------

@app.get("/api/config/opt")
async def get_opt():
    rows = state.db.q("SELECT * FROM optimization_configs ORDER BY id DESC LIMIT 1")
    return {"config": rows[0] if rows else {}}


@app.post("/api/config/opt")
async def set_opt(payload: dict):
    err = validate_command("set_opt", payload.get("settings", {}))
    if err:
        return JSONResponse({"ok": False, "error": err}, status_code=400)
    s = payload.get("settings", {})
    state.db.run(
        """INSERT INTO optimization_configs(created_at,name,delta_enabled,
        dedup_enabled,compression_enabled,priority_enabled,partial_enabled,
        algorithm,medium_every,full_every,update_hz,budget_kbps,
        max_packet_size) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (now_iso(), str(payload.get("name", "custom")),
         int(bool(s.get("delta_enabled", True))),
         int(bool(s.get("dedup_enabled", True))),
         int(bool(s.get("compression_enabled", True))),
         int(bool(s.get("priority_enabled", True))),
         int(bool(s.get("partial_enabled", True))),
         int(s.get("algorithm", 2)), int(s.get("medium_every", 3)),
         int(s.get("full_every", 60)), float(s.get("update_hz", 20)),
         float(s.get("budget_kbps", 0)), int(s.get("max_packet_size", 1400))))
    cid = None
    if payload.get("apply_to_game", True):
        cmd_params = {k: s[k] for k in (
            "delta_enabled", "dedup_enabled", "compression_enabled",
            "priority_enabled", "partial_enabled", "medium_every",
            "full_every", "algorithm") if k in s}
        if cmd_params:
            cid = queue_command("set_opt", cmd_params)
    return {"ok": True, "command_id": cid}


@app.get("/api/config/net")
async def get_net():
    rows = state.db.q("SELECT * FROM network_configs ORDER BY id DESC LIMIT 1")
    return {"config": rows[0] if rows else {}}


@app.post("/api/config/net")
async def set_net(payload: dict):
    s = payload.get("settings", {})
    for k, lo, hi in (("bandwidth_kbps", 0, 100000), ("latency_ms", 0, 5000),
                      ("jitter_ms", 0, 5000), ("loss_pct", 0, 100)):
        if k in s:
            try:
                v = float(s[k])
            except (TypeError, ValueError):
                return JSONResponse({"ok": False, "error": f"{k} must be a number"},
                                    status_code=400)
            if not (lo <= v <= hi):
                return JSONResponse(
                    {"ok": False, "error": f"{k}={v} out of range {lo}..{hi}"},
                    status_code=400)
    state.db.run(
        """INSERT INTO network_configs(created_at,name,bandwidth_kbps,
        latency_ms,jitter_ms,loss_pct) VALUES (?,?,?,?,?,?)""",
        (now_iso(), str(payload.get("name", "custom")),
         float(s.get("bandwidth_kbps", 0)), float(s.get("latency_ms", 0)),
         float(s.get("jitter_ms", 0)), float(s.get("loss_pct", 0))))
    cid = None
    if payload.get("apply_to_game", True) and "bandwidth_kbps" in s:
        cid = queue_command("set_net", {"budget_kbps": float(s["bandwidth_kbps"])})
    return {"ok": True, "command_id": cid,
            "note": "game budget updated; latency/jitter/loss apply to simulated runs"}


@app.get("/api/commands-log")
async def commands_log():
    return {"commands": state.db.q(
        "SELECT * FROM commands ORDER BY id DESC LIMIT 100")}


# --------------------------------------------------------------------------
# export
# --------------------------------------------------------------------------

@app.get("/api/export/{eid}")
async def export_exp(eid: str, format: str = "json"):
    r = state.db.q("SELECT * FROM experiments WHERE id=?", (eid,))
    if not r:
        return JSONResponse({"error": "not found"}, status_code=404)
    exp = r[0]
    mids = [m for m in (exp["baseline_match_id"], exp["optimized_match_id"]) if m]
    data = {"experiment": exp, "matches": {},
            "samples": {}, "comparison": None}
    for mid in mids:
        m = state.db.q("SELECT * FROM matches WHERE match_id=?", (mid,))
        data["matches"][mid] = m[0] if m else {}
        data["samples"][mid] = state.db.q(
            "SELECT * FROM metric_samples WHERE match_id=? ORDER BY t", (mid,))
    if len(mids) == 2:
        data["comparison"] = await compare(mids[0], mids[1])
    if format == "csv":
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["experiment", eid, exp["name"], exp["status"]])
        w.writerow([])
        for mid in mids:
            w.writerow([f"match {mid}"])
            rows = data["samples"][mid]
            if rows:
                w.writerow(list(rows[0].keys()))
                for s in rows:
                    w.writerow(list(s.values()))
            w.writerow([])
        return PlainTextResponse(buf.getvalue(), media_type="text/csv",
                                 headers={"Content-Disposition":
                                          f"attachment; filename={eid}.csv"})
    return JSONResponse(data, headers={"Content-Disposition":
                                       f"attachment; filename={eid}.json"})


@app.get("/api/export-match/{mid}")
async def export_match(mid: str, format: str = "json"):
    m = state.db.q("SELECT * FROM matches WHERE match_id=?", (mid,))
    if not m:
        return JSONResponse({"error": "not found"}, status_code=404)
    rows = state.db.q("SELECT * FROM metric_samples WHERE match_id=? ORDER BY t",
                      (mid,))
    if format == "csv":
        buf = io.StringIO()
        w = csv.writer(buf)
        if rows:
            w.writerow(list(rows[0].keys()))
            for s in rows:
                w.writerow(list(s.values()))
        return PlainTextResponse(buf.getvalue(), media_type="text/csv")
    return {"match": m[0], "samples": rows}


# --------------------------------------------------------------------------
# benchmark matrix
# --------------------------------------------------------------------------

@app.post("/api/benchmark")
async def start_benchmark(payload: dict):
    if state.bench["running"]:
        return JSONResponse({"error": "benchmark already running"}, status_code=409)
    bws = [float(x) for x in payload.get("bandwidths_kbps", [625, 250, 125, 64, 32])]
    modes = [str(x).upper() for x in payload.get("modes", ["NORMAL", "OPTIMIZED"])]
    base = payload.get("config", {}) or {}
    state.bench.update(running=True, stop=False, log=[])
    t = threading.Thread(target=_bench_worker,
                         args=(bws, modes, base, state.args.port), daemon=True)
    t.start()
    return {"ok": True, "cells": len(bws) * len(modes)}


@app.post("/api/benchmark/stop")
async def stop_benchmark():
    state.bench["stop"] = True
    return {"ok": True}


@app.get("/api/benchmark")
async def benchmark_status():
    return state.bench


def _bench_worker(bws, modes, base, port):
    try:
        for bw in bws:
            for mode in modes:
                if state.bench["stop"]:
                    break
                name = f"bench {bw:g}kbps {mode}"
                exp_id = "exp%03d" % (1 + len(state.db.q("SELECT id FROM experiments")))
                cfg = dict(default_exp_config())
                cfg.update(base)
                cfg["bandwidth_kbps"] = bw
                cfg["duration"] = int(base.get("duration", 60))
                state.db.run(
                    "INSERT INTO experiments(id,name,created_at,status,notes,config_json)"
                    " VALUES (?,?,?,?,?,?)",
                    (exp_id, name, now_iso(), "benchmark_running",
                     "auto benchmark cell", json.dumps(cfg)))
                flags = [] if mode == "NORMAL" else cfg.get("opt_flags", [])
                ok = launch_headless(exp_id, mode.lower(), mode, cfg, flags)
                state.bench["log"].append({"cell": name, "launched": ok,
                                           "t": now_iso()})
                # wait for this cell's match to finish (or stop/timeout)
                deadline = time.time() + cfg["duration"] + 150
                while time.time() < deadline and not state.bench["stop"]:
                    r = state.db.q("SELECT ended_at FROM matches WHERE experiment_id=?",
                                   (exp_id,))
                    if r and r[0]["ended_at"]:
                        break
                    time.sleep(5)
                side = "baseline" if mode == "NORMAL" else "optimized"
                col = "baseline_match_id" if side == "baseline" else "optimized_match_id"
                m = state.db.q("SELECT match_id FROM matches WHERE experiment_id=?",
                               (exp_id,))
                if m:
                    state.db.run(f"UPDATE experiments SET {col}=?, status=? WHERE id=?",
                                 (m[0]["match_id"], "done", exp_id))
                else:
                    state.db.run("UPDATE experiments SET status=? WHERE id=?",
                                 ("failed", exp_id))
            if state.bench["stop"]:
                break
    finally:
        state.bench["running"] = False


# --------------------------------------------------------------------------
# websocket
# --------------------------------------------------------------------------

async def broadcast(msg: dict):
    dead = []
    for ws in list(state.ws_clients):
        try:
            await ws.send_json(msg)
        except Exception:
            dead.append(ws)
    for ws in dead:
        state.ws_clients.discard(ws)


async def live_pump():
    while True:
        await asyncio.sleep(1.0)
        if state and state.ws_clients:
            await broadcast(state.live_payload())


@app.on_event("startup")
async def _startup():
    asyncio.create_task(live_pump())


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    state.ws_clients.add(ws)
    try:
        await ws.send_json(state.live_payload())
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        state.ws_clients.discard(ws)


# --------------------------------------------------------------------------
# static + main
# --------------------------------------------------------------------------

@app.get("/api/settings")
async def get_settings():
    return {"port": state.args.port, "game_path": state.args.game_path,
            "auto_launch": state.args.auto_launch,
            "db": str(state.db.path)}


def main():
    global state
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8901)
    ap.add_argument("--db", default=str(HERE / "cloud_arena_monitor.db"))
    ap.add_argument("--game-path",
                    default="/home/lokeshpapapa/Downloads/thin_client/godot")
    ap.add_argument("--no-auto-launch", dest="auto_launch",
                    action="store_false", default=True)
    # Loopback by default. --host 0.0.0.0 is opt-in and is what a phone on
    # the same LAN needs in order to load the dashboard and post telemetry.
    ap.add_argument("--host", default="127.0.0.1",
                    help="bind address; use 0.0.0.0 to expose on the LAN")
    args = ap.parse_args()
    db = DB(Path(args.db))
    state = State(db, args)
    app.mount("/", StaticFiles(directory=str(HERE / "static"), html=True),
              name="static")
    import uvicorn
    shown = "127.0.0.1" if args.host in ("0.0.0.0", "::") else args.host
    print(f"CLOUD ARENA MONITOR on http://{shown}:{args.port}  db={args.db}")
    if args.host not in ("127.0.0.1", "localhost"):
        print("WARNING: bound to the LAN. Anyone on this network can read "
              "telemetry and send control commands. Use only on a trusted "
              "network and stop the service when done.")
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
