#!/usr/bin/env python3
"""
Cloud Arena Room Registry Server
Simple HTTP API for global room registration and discovery
"""

import json
import time
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import threading
import os

# In-memory room registry
# Format: {code: {host_ip, port, host_name, created_at, last_heartbeat, max_players, current_players}}
rooms = {}
rooms_lock = threading.Lock()

# Room expiry time (10 minutes without heartbeat)
ROOM_EXPIRY_SECONDS = 600

class RoomRegistryHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        """Custom logging"""
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
        """Handle GET requests"""
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        query = parse_qs(parsed_path.query)
        
        # Health check
        if path == '/' or path == '/health':
            self._set_headers(200, 'text/plain')
            self.wfile.write(b'OK')
            return
        
        # Get room by code
        if path.startswith('/rooms/'):
            code = path.split('/')[-1]
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
                    # Room not found or expired
                    if room:
                        del rooms[code]
                    self._set_headers(404)
                    self.wfile.write(json.dumps({
                        'ok': False,
                        'error': 'Room not found'
                    }).encode())
            return
        
        # List all active rooms
        if path == '/rooms':
            with rooms_lock:
                # Clean expired rooms
                now = time.time()
                expired = [code for code, room in rooms.items() 
                          if (now - room['last_heartbeat']) >= ROOM_EXPIRY_SECONDS]
                for code in expired:
                    del rooms[code]
                
                # Return active rooms
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
            return
        
        # Unknown endpoint
        self._set_headers(404)
        self.wfile.write(json.dumps({'ok': False, 'error': 'Not found'}).encode())
    
    def do_POST(self):
        """Handle POST requests"""
        parsed_path = urlparse(self.path)
        path = parsed_path.path
        
        # Register or update room
        if path == '/rooms/register':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)
            
            try:
                data = json.loads(body.decode())
                code = str(data.get('code', '')).strip()
                
                # Validate code format (6 digits)
                if not code or len(code) != 6 or not code.isdigit():
                    self._set_headers(400)
                    self.wfile.write(json.dumps({
                        'ok': False,
                        'error': 'Invalid room code format (must be 6 digits)'
                    }).encode())
                    return
                
                # Get host IP (use provided or client IP)
                host_ip = data.get('host_ip', self.client_address[0])
                
                # Register room
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
                
                print(f"[ROOM] Registered: {code} by {host_ip} ({data.get('host_name')})")
                
                self._set_headers(200)
                self.wfile.write(json.dumps({
                    'ok': True,
                    'code': code,
                    'message': 'Room registered successfully'
                }).encode())
                return
                
            except Exception as e:
                print(f"[ERROR] Failed to register room: {e}")
                self._set_headers(500)
                self.wfile.write(json.dumps({
                    'ok': False,
                    'error': f'Server error: {str(e)}'
                }).encode())
                return
        
        # Heartbeat endpoint
        if path == '/rooms/heartbeat':
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
                        self.wfile.write(json.dumps({
                            'ok': True,
                            'message': 'Heartbeat received'
                        }).encode())
                    else:
                        self._set_headers(404)
                        self.wfile.write(json.dumps({
                            'ok': False,
                            'error': 'Room not found'
                        }).encode())
                return
                
            except Exception as e:
                print(f"[ERROR] Heartbeat failed: {e}")
                self._set_headers(500)
                self.wfile.write(json.dumps({
                    'ok': False,
                    'error': f'Server error: {str(e)}'
                }).encode())
                return
        
        # Unregister room
        if path == '/rooms/unregister':
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
                        self.wfile.write(json.dumps({
                            'ok': True,
                            'message': 'Room unregistered'
                        }).encode())
                    else:
                        self._set_headers(404)
                        self.wfile.write(json.dumps({
                            'ok': False,
                            'error': 'Room not found'
                        }).encode())
                return
                
            except Exception as e:
                print(f"[ERROR] Unregister failed: {e}")
                self._set_headers(500)
                self.wfile.write(json.dumps({
                    'ok': False,
                    'error': f'Server error: {str(e)}'
                }).encode())
                return
        
        # Unknown endpoint
        self._set_headers(404)
        self.wfile.write(json.dumps({'ok': False, 'error': 'Not found'}).encode())

def cleanup_expired_rooms():
    """Background thread to clean up expired rooms"""
    while True:
        time.sleep(60)  # Check every minute
        now = time.time()
        with rooms_lock:
            expired = [code for code, room in rooms.items() 
                      if (now - room['last_heartbeat']) >= ROOM_EXPIRY_SECONDS]
            for code in expired:
                print(f"[ROOM] Expired: {code}")
                del rooms[code]

def run_server(port=8080):
    """Run the room registry server"""
    server_address = ('', port)
    httpd = HTTPServer(server_address, RoomRegistryHandler)
    
    # Start cleanup thread
    cleanup_thread = threading.Thread(target=cleanup_expired_rooms, daemon=True)
    cleanup_thread.start()
    
    print(f"[REGISTRY] Cloud Arena Room Registry running on port {port}")
    print(f"[REGISTRY] Endpoints:")
    print(f"  POST /rooms/register - Register a new room")
    print(f"  GET /rooms/<code> - Look up room by code")
    print(f"  GET /rooms - List all active rooms")
    print(f"  POST /rooms/heartbeat - Update room heartbeat")
    print(f"  POST /rooms/unregister - Remove room")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[REGISTRY] Shutting down...")
        httpd.shutdown()

if __name__ == '__main__':
    port = int(os.environ.get('REGISTRY_PORT', 8080))
    run_server(port)
