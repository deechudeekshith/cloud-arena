# Configure Production Server - Quick Guide

Once you have provisioned your VPS and have the public IP address, follow these steps to configure Cloud Arena for global internet multiplayer.

## Step 1: Update ServerConfig.gd with Real VPS IP

Open: `godot/scripts/game/ServerConfig.gd`

Find the `load_production_config()` function and replace `YOUR_VPS_IP_OR_DOMAIN` with your actual VPS IP:

### Before (Placeholder):
```gdscript
func load_production_config() -> void:
	config = {
		"environment": "production",
		"monitor_api": {
			"base_url": "https://YOUR_VPS_IP_OR_DOMAIN:8901",  # TODO: Replace
			"use_https": true,
			"timeout": 15.0
		},
		"game_server": {
			"host": "YOUR_VPS_IP_OR_DOMAIN",  # TODO: Replace
			"port": 7777,
			"use_wss": true,
			# ...
		},
		# ...
	}
```

### After (Example with IP 165.232.181.45):
```gdscript
func load_production_config() -> void:
	config = {
		"environment": "production",
		"monitor_api": {
			"base_url": "http://165.232.181.45:8901",  # Use http:// not https:// initially
			"use_https": false,  # Set to false until SSL is configured
			"timeout": 15.0
		},
		"game_server": {
			"host": "165.232.181.45",  # Your actual VPS IP
			"port": 7777,
			"use_wss": false,  # Set to false until SSL is configured (use ws:// not wss://)
			"connection_timeout": 20.0,
			"reconnect_attempts": 5,
			"reconnect_delay": 3.0
		},
		"room_discovery": {
			"enabled": false,  # LAN discovery disabled in production
			"broadcast_port": 47777
		},
		"networking": {
			"max_players": 8,
			"tick_rate": 30,
			"compression_enabled": true
		}
	}
```

**IMPORTANT NOTES:**
- Start with `http://` and `ws://` (not HTTPS/WSS) until SSL certificates are configured
- Use `use_https: false` and `use_wss: false` initially
- After adding SSL/TLS (optional), change to `https://`, `wss://` and set flags to `true`

## Step 2: Switch to Production Environment

In the same file (`ServerConfig.gd`), change the current environment:

### Before:
```gdscript
# Current environment - change this to switch between dev and prod
var current_environment: Environment = Environment.DEVELOPMENT
```

### After:
```gdscript
# Current environment - change this to switch between dev and prod
var current_environment: Environment = Environment.PRODUCTION
```

## Step 3: Verify Configuration

Add this validation check to ensure you didn't miss anything:

The `is_production_config_valid()` function will automatically verify that:
- No placeholder values remain (`YOUR_VPS_IP_OR_DOMAIN`)
- No localhost/127.0.0.1 in production config
- Config contains a real public IP or domain

When you run the game, check the console output:

```
[ServerConfig] Loaded production environment
[ServerConfig] Monitor API: http://165.232.181.45:8901
[ServerConfig] Game Server: 165.232.181.45:7777
```

If you see warnings, the config is still invalid.

## Step 4: Build Production APK

1. Open Godot editor: `godot/project.godot`
2. Verify ServerConfig has correct IP (no placeholders)
3. Go to **Project** → **Export**
4. Select **Android** export preset
5. Configure if needed:
   - App name: "Cloud Arena"
   - Package: `com.cloudarena.game`
   - Version: `1.0`
6. Click **Export Project**
7. Save as: `build/cloud_arena_v1.0_global_multiplayer.apk`

**Verification:**
- APK file should be ~30-40 MB
- File exists: `build/cloud_arena_v1.0_global_multiplayer.apk`

## Step 5: Test Production Configuration (Desktop)

Before deploying to mobile, test on desktop:

```bash
# From project root
cd godot

# Run in production mode
godot --environment=production
```

Or manually set in ServerConfig before running.

**Expected behavior:**
- Game starts
- Console shows: "Loaded production environment"
- Monitor API connects to: `http://YOUR_VPS_IP:8901`
- Creating room should connect to cloud server

**If connection fails:**
- Check VPS IP is correct
- Verify VPS firewall allows ports 7777 and 8901
- Check VPS services are running: `systemctl status cloudarena-monitor cloudarena-game`
- Test from command line: `curl http://YOUR_VPS_IP:8901/health`

## Step 6: Test Global Multiplayer

### Test 1: Same Network (Sanity Check)
1. Install APK on 2 devices connected to same WiFi
2. Device 1: Create Room → Get Room ID (e.g., `123456`)
3. Device 2: Join Room → Enter Room ID `123456`
4. Both devices should connect to **cloud server** (not LAN)
5. Verify in logs that connection is to VPS IP, not local IP

### Test 2: Different Networks (Real Test)
1. Device 1 on WiFi
2. Device 2 on mobile data (disable WiFi)
3. Device 1: Create Room → Get Room ID
4. Device 2: Join Room → Enter Room ID
5. **SUCCESS**: If both connect and can play, global multiplayer works!

### Test 3: Different Cities (Ultimate Test)
1. Friend in different city installs APK
2. You create room
3. Share Room ID (via WhatsApp, etc.)
4. Friend joins using Room ID
5. **SUCCESS**: Cross-city multiplayer working!

## Step 7: Clean Up Old APKs

After successful testing, delete old development builds:

### Files to DELETE:
```
build/cloud_arena.apk
build/cloud_arena_debug.apk
build/cloud_arena_new.apk
build/cloud_arena_newwwwwwwwwww.apk
build/cloud_arena_approval_fixed_debug.apk
build/cloud_arena_approval_fixed_v2_debug.apk
build/cloud_arena_fixed_settings_bug_debug.apk
godot/cloud_arena.apk
```

### Files to KEEP:
```
build/cloud_arena_v1.0_global_multiplayer.apk  ← Final production build
```

Command to clean up:
```bash
cd build
rm -f cloud_arena.apk cloud_arena_debug.apk cloud_arena_new.apk cloud_arena_newwwwwwwwwww.apk cloud_arena_approval_fixed*.apk cloud_arena_fixed_settings_bug_debug.apk
cd ../godot
rm -f cloud_arena.apk
```

Verify only one APK remains:
```bash
find . -name "*.apk" -type f
# Should only show: ./build/cloud_arena_v1.0_global_multiplayer.apk
```

## Switching Back to Development

To test locally again (LAN mode):

1. Open `godot/scripts/game/ServerConfig.gd`
2. Change:
   ```gdscript
   var current_environment: Environment = Environment.DEVELOPMENT
   ```
3. Run game normally - it will use localhost/LAN

## Command Line Override

You can also switch environments without editing code:

```bash
# Run in production mode
godot -- --environment=production

# Run in production with custom server
godot -- --environment=production --server=165.232.181.45
```

## Troubleshooting

### "Could not connect to server"

**Check 1: VPS is reachable**
```bash
ping YOUR_VPS_IP
curl http://YOUR_VPS_IP:8901/health
```

**Check 2: Firewall allows connections**
```bash
ssh root@YOUR_VPS_IP 'ufw status'
# Should show: 7777/tcp ALLOW Anywhere
```

**Check 3: Services are running**
```bash
ssh root@YOUR_VPS_IP 'systemctl status cloudarena-monitor cloudarena-game'
```

**Check 4: ServerConfig is correct**
- No placeholders: `YOUR_VPS_IP_OR_DOMAIN`
- Environment is `PRODUCTION`
- IP matches VPS public IP

### "Room not found" / "Join failed"

**Room creation might be failing on server side**

Check server logs:
```bash
ssh root@YOUR_VPS_IP 'journalctl -u cloudarena-game -n 50'
```

Restart services:
```bash
ssh root@YOUR_VPS_IP 'systemctl restart cloudarena-monitor cloudarena-game'
```

### Connection timeout / slow

**Check latency to VPS:**
```bash
ping YOUR_VPS_IP
# Should be < 100ms for India servers
```

**If high latency:**
- Consider VPS in closer datacenter
- DigitalOcean Bangalore or Mumbai for Indian players
- AWS Mumbai region
- Linode Mumbai

## SSL/TLS Configuration (Optional)

To enable HTTPS/WSS:

1. Get domain name (e.g., `cloudarena.example.com`)
2. Point domain DNS A record to VPS IP
3. Install Let's Encrypt certificate
4. Configure Nginx reverse proxy
5. Update ServerConfig to use `https://` and `wss://`
6. Set `use_https: true` and `use_wss: true`

See: `docs/SSL_SETUP.md` (to be created if needed)

## Verification Checklist

Before declaring success:

- [ ] ServerConfig has real VPS IP (no placeholders)
- [ ] VPS services running (monitor + game server)
- [ ] Firewall allows ports 7777 and 8901
- [ ] Desktop test connects to cloud server
- [ ] APK builds successfully
- [ ] Same-network test passes (2 devices, WiFi)
- [ ] Different-network test passes (WiFi + mobile data)
- [ ] Old APKs deleted (only v1.0 remains)
- [ ] Room creation works
- [ ] Room joining works
- [ ] Game plays smoothly
- [ ] No "same WiFi" requirement
- [ ] Cross-city test passes (if possible)

## Success Criteria

✅ **Global Internet Multiplayer is Working When:**

1. Player in Bengaluru creates room on WiFi
2. Player in Mumbai joins using Room ID on mobile data
3. Both connect successfully
4. Game starts and plays smoothly
5. No lag > 150ms (India to India)
6. Room management works (host, join, leave)
7. Bots function correctly
8. Combat/weapons/teams work as expected

---

**Once all tests pass, document final configuration and celebrate! 🎉**
