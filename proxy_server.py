#!/usr/bin/env python3
"""
Cloud Arena Proxy Server
Routes HTTP registry API and proxies WebSocket to Godot
Runs on single port (required for Render.com free tier)

URL Routing:
- /registry/* → Room registry HTTP API (handled here)
- /* (WebSocket) → Godot game server (proxied to internal port)
"""

import json
import time
import threading
import os
import socket
import select
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from socketserver import ThreadingMixIn

# In-memory room registry
rooms = {}
rooms_lock = threading.Lock()
ROOM_EXPIRY_SECONDS = 600

# Godot server internal port
GODOT_PORT = 10001


class ProxyHandler(BaseHTTPRequestHandler):
    """Handle HTTP API and proxy WebSocket to Godot"""
    
    protocol_version = 'HTTP/1.1'
    
    def log_message(self, format, *args):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {format % args}")
    
    def _set_headers(self, status=200, content_type='application/json'):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()
    
    def do_OPTIONS(self):
        """Handle CORS preflight"""
        self._set_headers(200)
    
    def do_GET(self):
        """Handle GET - Registry API or WebSocket proxy"""
        path = urlparse(self.path).path
        
        # Check for WebSocket upgrade
        if self.headers.get('Upgrade', '').lower() == 'websocket':
            self._proxy_websocket()
            return
        
        # Health check
        if path == '/' or path == '/health':
            self._set_headers(200, 'text/plain')
            self.wfile.write(b'OK - Cloud Arena Proxy')
            return
        
        # Registry: Get room by code
        if path.startswith('/registry/rooms/') and len(path.split('/')) == 4:
            code = path.split('/')[-1]
            self._handle_room_lookup(code)
            return
        
        # Registry: List rooms
        if path == '/registry/rooms':
            self._handle_list_rooms()
            return
        
        # Unknown
        self._set_headers(404)
        self.wfile.write(json.dumps({'ok': False, 'error': 'Not found'}).encode())
    
    def do_POST(self):
        """Handle POST - Registry API"""
        path = urlparse(self.path).path
        
        if path == '/registry/rooms/register':
            self._handle_room_register()
        elif path == '/registry/rooms/heartbeat':
            self._handle_room_heartbeat()
        elif path == '/registry/rooms/unregister':
            self._handle_room_unregister()
        else:
            self._set_headers(404)
            self.wfile.write(json.dumps({'ok': False, 'error': 'Not found'}).encode())
    
    def _proxy_websocket(self):
        """Proxy WebSocket connection to Godot server"""
        try:
            # Build a proper WebSocket upgrade request to forward to Godot
            from hashlib import sha1
            from base64 import b64encode
            
            # Extract the Sec-WebSocket-Key from client request
            ws_key = self.headers.get('Sec-WebSocket-Key', '')
            if not ws_key:
                self.send_error(400, "Missing Sec-WebSocket-Key header")
                return
            
            # Connect to Godot server
            godot_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            godot_sock.connect(('127.0.0.1', GODOT_PORT))
            
            # Send upgrade request to Godot (include all required WebSocket headers)
            request = f"GET {self.path} HTTP/1.1\r\n"
            request += "Host: localhost:10001\r\n"
            request += "Upgrade: websocket\r\n"
            request += "Connection: Upgrade\r\n"
            request += f"Sec-WebSocket-Key: {ws_key}\r\n"
            request += "Sec-WebSocket-Version: 13\r\n"
            request += "\r\n"
            
            godot_sock.sendall(request.encode())
            
            # Read the complete response (headers + empty line)
            response_data = b""
            while b"\r\n\r\n" not in response_data:
                chunk = godot_sock.recv(1024)
                if not chunk:
                    print("[PROXY] ERROR: Godot server closed connection during handshake")
                    self.send_error(502, "Bad Gateway")
                    return
                response_data += chunk
            
            # Parse Godot's response
            response_str = response_data.decode('utf-8', errors='ignore')
            headers_part = response_str.split('\r\n\r\n')[0]
            
            # Send response to client with proper WebSocket upgrade headers
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            
            # Generate the Sec-WebSocket-Accept from the key
            magic_string = ws_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            sha1_hash = sha1(magic_string.encode()).digest()
            ws_accept = b64encode(sha1_hash).decode('ascii')
            self.send_header('Sec-WebSocket-Accept', ws_accept)
            self.end_headers()
            
            # Now bidirectionally proxy the WebSocket frames
            self._bidirectional_proxy(self.connection, godot_sock)
            
        except Exception as e:
            print(f"[PROXY] WebSocket proxy error: {e}")
            self.send_error(502, "Bad Gateway")
    
    def _bidirectional_proxy(self, client, server):
        """Proxy WebSocket frames between client and server"""
        try:
            while True:
                readable, _, exceptional = select.select([client, server], [], [client, server], 1.0)
                
                if exceptional:
                    break
                
                for sock in readable:
                    data = sock.recv(4096)
                    if not data:
                        return
                    
                    if sock is client:
                        server.sendall(data)
                    else:
                        client.sendall(data)
        except Exception as e:
            print(f"[PROXY] Bidirectional proxy ended: {e}")
    
    def _handle_room_lookup(self, code):
        """Look up room by code"""
        with rooms_lock:
            room = rooms.get(code)
            if room and (time.time() - room['last_heartbeat']) < ROOM_EXPIRY_SECONDS:
                self._set_headers(200)
                self.wfile.write(json.dumps({
                    'ok': True,
                    'code': code,
                    'host': room['host_ip'],
                    'port': room['port'],
                    'host_name': room['host_name'],
                    'players': room['current_players'],
                    'max_players': room['max_players']
                }).encode())
            else:
                if room:
                    del rooms[code]
                self._set_headers(404)
                self.wfile.write(json.dumps({
                    'ok': False,
                    'error': 'Room not found'
                }).encode())
    
    def _handle_list_rooms(self):
        """List all active rooms"""
        with rooms_lock:
            now = time.time()
            expired = [code for code, room in rooms.items() 
                      if (now - room['last_heartbeat']) >= ROOM_EXPIRY_SECONDS]
            for code in expired:
                del rooms[code]
            
            active_rooms = [
                {
                    'code': code,
                    'host_name': room['host_name'],
                    'players': room['current_players'],
                    'max_players': room['max_players']
                }
                for code, room in rooms.items()
            ]
            
            self._set_headers(200)
            self.wfile.write(json.dumps({
                'ok': True,
                'rooms': active_rooms,
                'count': len(active_rooms)
            }).encode())
    
    def _handle_room_register(self):
        """Register room"""
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        
        try:
            data = json.loads(body.decode())
            code = str(data.get('code', '')).strip()
            
            if not code or len(code) != 6 or not code.isdigit():
                self._set_headers(400)
                self.wfile.write(json.dumps({
                    'ok': False,
                    'error': 'Invalid room code (must be 6 digits)'
                }).encode())
                return
            
            host_ip = data.get('host_ip', self.client_address[0])
            
            with rooms_lock:
                rooms[code] = {
                    'code': code,
                    'host_ip': host_ip,
                    'port': int(data.get('port', 10000)),
                    'host_name': str(data.get('host_name', 'Unknown')),
                    'created_at': time.time(),
                    'last_heartbeat': time.time(),
                    'max_players': int(data.get('max_players', 8)),
                    'current_players': int(data.get('current_players', 1))
                }
            
            print(f"[ROOM] Registered: {code} by {host_ip}")
            
            self._set_headers(200)
            self.wfile.write(json.dumps({
                'ok': True,
                'code': code,
                'message': 'Room registered'
            }).encode())
        except Exception as e:
            print(f"[ERROR] Register failed: {e}")
            self._set_headers(500)
            self.wfile.write(json.dumps({
                'ok': False,
                'error': str(e)
            }).encode())
    
    def _handle_room_heartbeat(self):
        """Update heartbeat"""
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        
        try:
            data = json.loads(body.decode())
            code = str(data.get('code', '')).strip()
            
            with rooms_lock:
                if code in rooms:
                    rooms[code]['last_heartbeat'] = time.time()
                    rooms[code]['current_players'] = int(data.get('current_players', 
                                                                   rooms[code]['current_players']))
                    self._set_headers(200)
                    self.wfile.write(json.dumps({'ok': True}).encode())
                else:
                    self._set_headers(404)
                    self.wfile.write(json.dumps({
                        'ok': False,
                        'error': 'Room not found'
                    }).encode())
        except Exception as e:
            self._set_headers(500)
            self.wfile.write(json.dumps({'ok': False, 'error': str(e)}).encode())
    
    def _handle_room_unregister(self):
        """Unregister room"""
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        
        try:
            data = json.loads(body.decode())
            code = str(data.get('code', '')).strip()
            
            with rooms_lock:
                if code in rooms:
                    del rooms[code]
                    print(f"[ROOM] Unregistered: {code}")
                    self._set_headers(200)
                    self.wfile.write(json.dumps({'ok': True}).encode())
                else:
                    self._set_headers(404)
                    self.wfile.write(json.dumps({'ok': False, 'error': 'Not found'}).encode())
        except Exception as e:
            self._set_headers(500)
            self.wfile.write(json.dumps({'ok': False, 'error': str(e)}).encode())


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def cleanup_expired_rooms():
    """Background cleanup"""
    while True:
        time.sleep(60)
        now = time.time()
        with rooms_lock:
            expired = [code for code, room in rooms.items() 
                      if (now - room['last_heartbeat']) >= ROOM_EXPIRY_SECONDS]
            for code in expired:
                print(f"[ROOM] Expired: {code}")
                del rooms[code]


def run_proxy():
    """Run proxy server"""
    port = int(os.environ.get('PORT', 10000))
    
    print(f"[PROXY] Cloud Arena Proxy Server")
    print(f"[PROXY] Port: {port}")
    print(f"[PROXY] Registry: /registry/*")
    print(f"[PROXY] Game WebSocket: / (proxied to :{GODOT_PORT})")
    
    # Start cleanup thread
    threading.Thread(target=cleanup_expired_rooms, daemon=True).start()
    
    # Start server
    server = ThreadedHTTPServer(('', port), ProxyHandler)
    
    print(f"[PROXY] Ready!")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[PROXY] Shutting down...")
        server.shutdown()


if __name__ == '__main__':
    run_proxy()
