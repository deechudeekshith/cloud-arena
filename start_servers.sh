#!/bin/bash
# Start proxy server and Godot game server

echo "[STARTUP] Starting Cloud Arena servers..."

# Start proxy server on public port (FIRST - before Godot)
echo "[STARTUP] Starting proxy server on port $PORT..."
python3 /app/proxy_server.py &
PROXY_PID=$!
echo "[STARTUP] Proxy PID: $PROXY_PID"

# Give proxy time to start
sleep 1

# Start Godot game server on internal port 10001
echo "[STARTUP] Starting Godot server on internal port 10001..."
PORT=10001 /usr/local/bin/godot --headless --path /app/godot &
GODOT_PID=$!
echo "[STARTUP] Godot PID: $GODOT_PID"

# Give Godot time to start
sleep 3

echo "[STARTUP] All servers started!"
echo "[STARTUP] Proxy listens on: 0.0.0.0:$PORT (public)"
echo "[STARTUP] Godot listens on: 127.0.0.1:10001 (internal)"

# Wait for both
wait $PROXY_PID $GODOT_PID