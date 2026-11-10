# Manual VPS Setup Guide for Cloud Arena

This guide walks you through manually setting up a cloud VPS to host Cloud Arena's multiplayer servers.

## Prerequisites

- VPS with public IP address (DigitalOcean, AWS, Linode, etc.)
- Ubuntu 22.04 LTS
- 2 CPU cores, 4GB RAM minimum
- SSH access configured

## Step 1: Initial VPS Configuration

```bash
# SSH into your VPS
ssh root@YOUR_VPS_IP

# Update system
apt-get update && apt-get upgrade -y

# Install required packages
apt-get install -y python3 python3-pip python3-venv wget unzip curl ufw

# Create service user
useradd -r -s /bin/bash -d /opt/cloud_arena cloudarena

# Create directories
mkdir -p /opt/cloud_arena/{monitor,godot,logs}
chown -R cloudarena:cloudarena /opt/cloud_arena
```

## Step 2: Configure Firewall

```bash
# Enable firewall
ufw --force enable

# Allow SSH (IMPORTANT - do this first!)
ufw allow 22/tcp

# Allow game server port (WebSocket)
ufw allow 7777/tcp

# Allow monitor API port
ufw allow 8901/tcp

# Check status
ufw status
```

## Step 3: Deploy FastAPI Monitor Server

From your **local machine**, upload the monitor server:

```bash
# Navigate to project directory
cd /path/to/thin_client

# Upload monitor server files
scp -r monitor/server.py monitor/requirements.txt root@YOUR_VPS_IP:/opt/cloud_arena/monitor/
```

On the **VPS**, set up Python environment:

```bash
cd /opt/cloud_arena/monitor

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install --upgrade pip
pip install -r requirements.txt

# Fix permissions
chown -R cloudarena:cloudarena /opt/cloud_arena/monitor
```

## Step 4: Create Monitor Service

On the **VPS**:

```bash
cat > /etc/systemd/system/cloudarena-monitor.service << 'EOF'
[Unit]
Description=Cloud Arena Monitor API
After=network.target

[Service]
Type=simple
User=cloudarena
WorkingDirectory=/opt/cloud_arena/monitor
Environment="PATH=/opt/cloud_arena/monitor/venv/bin"
ExecStart=/opt/cloud_arena/monitor/venv/bin/uvicorn server:app --host 0.0.0.0 --port 8901 --workers 2
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Start and enable service
systemctl daemon-reload
systemctl start cloudarena-monitor
systemctl enable cloudarena-monitor

# Check status
systemctl status cloudarena-monitor
```

Test the monitor API:

```bash
curl http://localhost:8901/health
# Should return: {"status":"ok","service":"CloudArena Monitor"}

curl http://localhost:8901/rooms
# Should return: {"rooms":[]}
```

## Step 5: Export Godot Server Build

On your **local machine** with Godot editor:

1. Open the project: `godot/project.godot`
2. Go to: **Project** → **Export**
3. Add export preset if not exists:
   - Click **Add...** → **Linux/X11**
   - Name: "Linux Server"
4. Configure export settings:
   - **Runnable**: ✅ Enabled
   - **Export Mode**: Resources Only (creates .pck file)
   - **Features**: Custom: `server`
5. Export:
   - Click **Export PCK/ZIP**
   - Save as: `dist/cloud_arena_server.pck`

Alternative - Export full executable:
- **Export Project**
- Save as: `dist/cloud_arena_server`
- This creates a standalone executable

## Step 6: Install Godot Headless on VPS

On the **VPS**:

```bash
cd /tmp

# Download Godot 4.3 Linux headless
# (Replace with Godot 4.4-dev5 URL when available)
wget https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip

# Extract
unzip Godot_v4.3-stable_linux.x86_64.zip

# Move to deployment directory
mv Godot_v4.3-stable_linux.x86_64 /opt/cloud_arena/godot/godot_server
chmod +x /opt/cloud_arena/godot/godot_server

# Cleanup
rm Godot_v4.3-stable_linux.x86_64.zip
```

## Step 7: Upload Game Server Build

From your **local machine**:

```bash
# Upload the exported .pck file
scp dist/cloud_arena_server.pck root@YOUR_VPS_IP:/opt/cloud_arena/godot/

# Or upload full executable if you exported that way
scp dist/cloud_arena_server root@YOUR_VPS_IP:/opt/cloud_arena/godot/
```

## Step 8: Create Game Server Service

On the **VPS**:

```bash
cat > /etc/systemd/system/cloudarena-game.service << 'EOF'
[Unit]
Description=Cloud Arena Game Server (Godot Headless)
After=network.target

[Service]
Type=simple
User=cloudarena
WorkingDirectory=/opt/cloud_arena/godot
ExecStart=/opt/cloud_arena/godot/godot_server --headless --main-pack cloud_arena_server.pck -- --environment=production
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# If you uploaded full executable instead of .pck:
# ExecStart=/opt/cloud_arena/godot/cloud_arena_server --headless -- --environment=production

# Fix permissions
chown -R cloudarena:cloudarena /opt/cloud_arena/godot

# Start and enable service
systemctl daemon-reload
systemctl start cloudarena-game
systemctl enable cloudarena-game

# Check status
systemctl status cloudarena-game
```

## Step 9: Verify Services are Running

```bash
# Check monitor API
systemctl status cloudarena-monitor
curl http://localhost:8901/health

# Check game server
systemctl status cloudarena-game

# View logs
journalctl -u cloudarena-monitor -f
journalctl -u cloudarena-game -f

# Test from outside
# From your local machine:
curl http://YOUR_VPS_IP:8901/health
curl http://YOUR_VPS_IP:8901/rooms
```

## Step 10: Update Client Configuration

On your **local machine**, update `godot/scripts/game/ServerConfig.gd`:

```gdscript
## Production configuration (cloud server)
func load_production_config() -> void:
	config = {
		"environment": "production",
		"monitor_api": {
			"base_url": "https://YOUR_VPS_IP:8901",  # Replace YOUR_VPS_IP with actual IP
			"use_https": true,
			"timeout": 15.0
		},
		"game_server": {
			"host": "YOUR_VPS_IP",  # Replace with actual IP
			"port": 7777,
			"use_wss": true,
			"connection_timeout": 20.0,
			"reconnect_attempts": 5,
			"reconnect_delay": 3.0
		},
		# ... rest of config
	}
```

Replace `YOUR_VPS_IP` with your actual VPS IP address (e.g., `165.232.181.45`).

Then update the environment mode in `ServerConfig.gd`:

```gdscript
# Change this line:
var current_environment: Environment = Environment.PRODUCTION
```

## Step 11: Build Production APK

1. Open Godot editor
2. Verify ServerConfig has correct VPS IP
3. Go to **Project** → **Export**
4. Select **Android** export preset
5. Click **Export Project**
6. Save as: `build/cloud_arena_v1.0_global_multiplayer.apk`

## Step 12: Test Global Multiplayer

1. Install APK on Device 1 (on WiFi)
2. Install APK on Device 2 (on mobile data)
3. Device 1: Create Room
4. Device 2: Join using Room ID
5. Both should connect to cloud server and play together!

## Monitoring and Maintenance

### View Logs
```bash
# Monitor API logs
journalctl -u cloudarena-monitor -f

# Game server logs
journalctl -u cloudarena-game -f

# Last 100 lines
journalctl -u cloudarena-monitor -n 100
```

### Restart Services
```bash
systemctl restart cloudarena-monitor
systemctl restart cloudarena-game
```

### Stop Services
```bash
systemctl stop cloudarena-monitor
systemctl stop cloudarena-game
```

### Update Game Server
```bash
# Upload new build
scp dist/cloud_arena_server.pck root@YOUR_VPS_IP:/opt/cloud_arena/godot/

# Restart game service
ssh root@YOUR_VPS_IP 'systemctl restart cloudarena-game'
```

## Troubleshooting

### Monitor API not responding
```bash
# Check if service is running
systemctl status cloudarena-monitor

# Check logs
journalctl -u cloudarena-monitor -n 50

# Test locally
curl http://localhost:8901/health

# Restart
systemctl restart cloudarena-monitor
```

### Game server not accepting connections
```bash
# Check if running
systemctl status cloudarena-game

# Check logs
journalctl -u cloudarena-game -n 50

# Verify port is open
ss -tulpn | grep 7777

# Check firewall
ufw status | grep 7777

# Restart
systemctl restart cloudarena-game
```

### Firewall blocking connections
```bash
# Verify ports are open
ufw status

# Re-add ports if needed
ufw allow 7777/tcp
ufw allow 8901/tcp

# Check if ports are listening
netstat -tuln | grep -E '7777|8901'
```

## Cost Estimate

**DigitalOcean Droplet (Bangalore)**
- 2 CPU, 4GB RAM, 80GB SSD
- $18/month ($0.027/hour)
- Bandwidth: 4TB included

**AWS Lightsail**
- 2 CPU, 4GB RAM
- $20/month

**Linode (Mumbai)**
- 2 CPU, 4GB RAM
- $18/month

## Security Notes

1. **SSH Key Only**: Disable password authentication
2. **Firewall**: Only ports 22, 7777, 8901 open
3. **SSL/TLS**: Consider adding HTTPS with Let's Encrypt for production
4. **Monitoring**: Set up uptime monitoring (UptimeRobot, etc.)
5. **Backups**: Enable VPS snapshots/backups
6. **Updates**: Regularly update system packages

## Next Steps

After VPS is set up and verified:

1. Test from 2 devices on different networks
2. Test from different cities if possible
3. Monitor performance and latency
4. Clean up old APK files (keep only production build)
5. Document final configuration in project README

---

**Need Help?**
- Check logs first: `journalctl -u cloudarena-monitor -n 100`
- Verify firewall: `ufw status`
- Test locally: `curl http://localhost:8901/health`
- Test externally: `curl http://YOUR_VPS_IP:8901/health`
