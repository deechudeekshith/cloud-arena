#!/bin/bash
# Start proxy server and Godot game server

echo "[STARTUP] Starting Cloud Arena servers..."

# Start Godot game server on internal port
echo "[STARTUP] Starting Godot server on internal port 10001..."
PORT=10001 /usr/local/bin/godot --headless --path /app/godot &
GODOT_PID=$!
echo "[STARTUP] Godot PID: $GODOT_PID"

# Give Godot time to start
sleep 3

# Start proxy server on public port
echo "[STARTUP] Starting proxy server on port $PORT..."
python3 /app/proxy_server.py &
PROXY_PID=$!
echo "[STARTUP] Proxy PID: $PROXY_PID"

echo "[STARTUP] All servers started!"

# Wait for both
wait $PROXY_PID $GODOT_PID

