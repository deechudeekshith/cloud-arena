# Cloud Arena - Render.com Deployment Guide

**Date:** 2026-10-29  
**Platform:** Render.com Free Tier  
**Purpose:** Deploy Cloud Arena as a global internet multiplayer FPS game

---

## Overview

This guide walks you through deploying Cloud Arena's Godot dedicated server to Render.com's free tier. After deployment, players from anywhere in the world can create and join rooms using 6-digit codes, without being on the same WiFi network.

---

## What You Get

✅ **Free hosting** - No credit card required  
✅ **Global internet access** - Players connect from anywhere  
✅ **Automatic HTTPS/WSS** - Free TLS certificates  
✅ **6-digit room codes** - Easy room joining  
✅ **8-player matches** - Including bot AI  
✅ **Server-authoritative gameplay** - Combat, physics, bots all run on server  

⚠️ **Free tier limitations:**
- Sleeps after 15 minutes of no activity
- Takes ~60 seconds to wake up from sleep
- 750 free hours per month (enough for continuous uptime)
- 5 GB bandwidth per month (~17 hours of 8-player matches)
- Rooms are lost when server sleeps

---

## Prerequisites

1. **GitHub Account** - Render deploys from Git repositories
2. **Render Account** - Sign up at [render.com](https://render.com) (no credit card required)
3. **This Project** - Already configured with Dockerfile and render.yaml

---

## Step 1: Push Project to GitHub

1. Create a new GitHub repository (e.g., "cloud-arena-server")
2. Push your project:

```powershell
cd c:\Users\rdeek\Desktop\sem5\cloud\project\thin_client\thin_client

# Initialize git if not already done
git init
git add .
git commit -m "Initial commit - Cloud Arena with Render deployment"

# Add your GitHub repository
git remote add origin https://github.com/YOUR_USERNAME/cloud-arena-server.git
git branch -M main
git push -u origin main
```

---

## Step 2: Deploy to Render

### Option A: Using Render Dashboard (Recommended)

1. Go to [dashboard.render.com](https://dashboard.render.com)
2. Click **"New +"** → **"Web Service"**
3. Connect your GitHub account if not already connected
4. Select your `cloud-arena-server` repository
5. Configure the service:

   **Service Name:** `cloud-arena-server` (or any name you prefer)  
   **Region:** Oregon (or closest to your players)  
   **Branch:** `main`  
   **Runtime:** Docker  
   **Dockerfile Path:** `./Dockerfile`  
   **Plan:** Free  
   
6. Click **"Create Web Service"**
7. Wait for deployment (takes 3-5 minutes)
8. Note your service URL: `https://cloud-arena-server.onrender.com`

### Option B: Using Render Blueprint (Automatic)

If your repository includes `render.yaml` (it does), Render will detect it automatically:

1. Go to [dashboard.render.com](https://dashboard.render.com)
2. Click **"New +"** → **"Blueprint"**
3. Select your repository
4. Render automatically reads `render.yaml` and configures everything
5. Click **"Apply"**

---

## Step 3: Verify Deployment

### Check Health Endpoint

Visit: `https://your-app-name.onrender.com/health`

You should see: **"healthy"**

### Check Server Logs

1. In Render Dashboard, click on your service
2. Go to **"Logs"** tab
3. Look for these messages:

```
[GameRoot] ========================================
[GameRoot] CLOUD ARENA - DEDICATED SERVER MODE
[GameRoot] ========================================
[GameRoot] Starting dedicated server...
[GameRoot] Using PORT from environment: 10000
[GameRoot] Binding to 0.0.0.0:10000...
[GameRoot] ========================================
[GameRoot] Server started successfully!
[GameRoot] Listening on 0.0.0.0:10000
[GameRoot] Ready to accept client connections
[GameRoot] Max players per room: 8
[GameRoot] ========================================
[HealthServer] Listening on 0.0.0.0:10000
[GameRoot] Health check server running on port 10000
[GameRoot] Server running... (Ctrl+C to stop)
```

If you see these messages, **your server is running successfully!**

---

## Step 4: Update Client Configuration

Now update your Android and PC clients to connect to your Render server.

### Edit ServerConfig.gd

File: `godot/scripts/game/ServerConfig.gd`

Find the `load_production_config()` function and update line 99:

```gdscript
# BEFORE (placeholder):
var server_host = "YOUR_RENDER_APP_NAME.onrender.com"

# AFTER (your actual Render URL):
var server_host = "cloud-arena-server.onrender.com"  # Replace with YOUR app name
```

**Full updated function:**

```gdscript
func load_production_config() -> void:
	var render_url = OS.get_environment("RENDER_URL")
	var server_host = "cloud-arena-server.onrender.com"  # ← UPDATE THIS
	var use_secure = true
	
	if render_url != "":
		server_host = render_url.replace("https://", "").replace("http://", "")
		print("[ServerConfig] Using RENDER_URL: %s" % server_host)
	
	config = {
		"environment": "production",
		"monitor_api": {
			"base_url": "https://%s" % server_host,
			"use_https": use_secure,
			"timeout": 20.0
		},
		"game_server": {
			"host": server_host,  # Your Render URL
			"port": 443,  # WSS uses port 443
			"use_wss": use_secure,
			"connection_timeout": 30.0,
			"reconnect_attempts": 5,
			"reconnect_delay": 3.0
		},
		"room_discovery": {
			"enabled": false,
			"broadcast_port": 47777
		},
		"networking": {
			"max_players": 8,
			"tick_rate": 30,
			"compression_enabled": true
		}
	}
```

### Set Environment to Production

File: `godot/scripts/game/ServerConfig.gd`, line 18:

```gdscript
# Change from DEVELOPMENT to PRODUCTION:
var current_environment: Environment = Environment.PRODUCTION
```

---

## Step 5: Build Android APK

Now build a fresh Android APK with production configuration:

### Using Godot Editor:

1. Open Godot Editor
2. Load your project
3. Go to **Project** → **Export**
4. Select **Android** export template
5. Configure:
   - **Name:** `Cloud_Arena_Final`
   - **Export Mode:** Release
6. Click **Export Project**
7. Save as: `Cloud_Arena_Final.apk`

### Using Command Line:

```powershell
# Export Android APK
godot --headless --export-release "Android" "Cloud_Arena_Final.apk"
```

---

## Step 6: Test Multiplayer

### Test 1: Single Device (Wake-up Test)

1. Install `Cloud_Arena_Final.apk` on your Android device
2. Open the app
3. Click **"Create Room"**
4. **IMPORTANT:** First connection takes ~60 seconds if server is asleep
5. You should see:
   - "Connecting to server..." message
   - After ~60 seconds: Room created with 6-digit code
6. Write down the room code

### Test 2: Two Devices (Real Multiplayer Test)

**Device A (Your Phone):**
1. Create room (if server is awake, this is instant)
2. Note the 6-digit room code

**Device B (Friend's Phone or PC):**
1. Open Cloud Arena
2. Click **"Join Room"**
3. Enter the 6-digit code from Device A
4. Click **"Join"**
5. Both players should see each other in the lobby

**Start Match:**
1. Both players click **"Ready"**
2. Host clicks **"Start Match"**
3. Match starts with 8 players (2 humans + 6 bots)
4. Real multiplayer gameplay!

---

## Troubleshooting

### Issue: "Connection failed" or "Server not found"

**Cause:** Server might be sleeping or URL is incorrect.

**Solution:**
1. Visit `https://your-app-name.onrender.com/health` in a browser
2. Wait for server to wake up (~60 seconds)
3. Retry connection in game

### Issue: "Room not found" when joining

**Cause:** Server restarted and rooms were lost.

**Solution:**
1. Host creates a NEW room
2. Joiners use the NEW room code
3. Rooms only exist while server is awake

### Issue: Server keeps sleeping

**Cause:** No active connections for 15 minutes.

**Solution:**
- This is normal Render free tier behavior
- First player to connect wakes the server
- Active matches keep server awake
- Accept 60-second wait for first connection

### Issue: "Version mismatch" errors

**Cause:** Godot 4.7-dev project, Godot 4.3 server.

**Solution:**
1. Update Dockerfile to use Godot 4.7-dev (may require custom build)
2. OR rebuild project with Godot 4.3 stable locally

### Issue: High bandwidth usage

**Symptom:** Render warns about exceeding 5 GB monthly limit.

**Solution:**
- 5 GB = ~17 hours of 8-player matches
- Reduce player count per match
- OR upgrade to Render paid plan ($7/month for 100 GB)

---

## Monitoring Your Server

### View Logs

1. Go to [dashboard.render.com](https://dashboard.render.com)
2. Click your service
3. Go to **"Logs"** tab
4. See real-time server activity:
   - Room creations
   - Player connections
   - Match starts
   - Errors

### View Metrics

1. In Render Dashboard, go to **"Metrics"** tab
2. See:
   - Bandwidth usage
   - Request count
   - Instance hours used
   - Uptime/downtime

### Check Sleep Status

In Render Dashboard:
- **Green dot**: Server is awake and running
- **Gray dot**: Server is sleeping
- Click service name to wake it up manually

---

## Server Sleeping Behavior Explained

### When Server Sleeps:

- **Trigger:** 15 minutes of zero activity
- **What happens:**
  - All rooms are lost (in-memory data)
  - Players are disconnected
  - Server process stops
  
### When Server Wakes:

- **Trigger:** New HTTP request or WebSocket connection
- **Wake time:** ~60 seconds
- **What happens:**
  - Server restarts from scratch
  - New empty room registry
  - Ready for new rooms

### How to Minimize Impact:

1. **For active play sessions:** Players keep server awake automatically
2. **For idle periods:** Accept that server will sleep (this is expected)
3. **For first connection:** Inform players about 60-second wait time
4. **For room codes:** Codes are only valid while server is awake

---

## Cost Analysis

### Free Tier Limits:

- **Instance hours:** 750/month (enough for 24/7 uptime)
- **Bandwidth:** 5 GB/month (~17 hours of 8-player matches)
- **Build time:** Free (no limit)
- **Credit card:** NOT required

### When You Might Exceed:

**Scenario 1: Heavy usage**
- 100 players, 5 hours/day each = ~25 GB bandwidth/month
- **Cost:** $3 overage (5GB free + 20GB @ $0.15/GB)

**Scenario 2: Continuous matches**
- 10 concurrent 8-player matches, 24/7 = ~150 GB/month
- **Cost:** $21.75 overage

### Upgrade Options:

- **Hobby Plan:** $7/month, 100 GB bandwidth
- **Pro Plan:** $25/month, 1 TB bandwidth, priority support

---

## Updating Your Server

### Deploy New Changes:

1. Make code changes locally
2. Commit and push to GitHub:
   ```bash
   git add .
   git commit -m "Update server logic"
   git push
   ```
3. Render automatically rebuilds and deploys (takes 3-5 minutes)
4. No downtime (zero-downtime deploys)

### Manual Deploy:

1. Go to Render Dashboard
2. Click your service
3. Click **"Manual Deploy"** → **"Deploy latest commit"**

---

## Advanced Configuration

### Environment Variables

In Render Dashboard, go to **"Environment"** tab to set:

- `GODOT_ENVIRONMENT=production` (set by default)
- `MAX_PLAYERS=8` (change if needed)
- `LOG_LEVEL=info` (or `debug` for troubleshooting)

### Custom Domain

1. In Render Dashboard, go to **"Settings"** → **"Custom Domain"**
2. Add your domain (e.g., `arena.yourdomain.com`)
3. Update DNS records as shown
4. Update ServerConfig.gd with your custom domain

### Health Check Path

Render pings `/health` every 30 seconds. If it fails 3 times:
- Service is marked unhealthy
- Render restarts the service automatically

---

## Security Considerations

### What's Protected:

✅ **TLS encryption** - All traffic uses HTTPS/WSS  
✅ **DDoS protection** - Render provides automatic protection  
✅ **Server-authoritative** - Clients can't cheat (damage, score calculated on server)  
✅ **Room codes** - 6 digits = 1 million combinations, randomly generated  

### What's NOT Protected:

⚠️ **No authentication** - Anyone with room code can join  
⚠️ **No rate limiting** - Players can create unlimited rooms  
⚠️ **No ban system** - No way to block misbehaving players  

### Recommendations:

For production use, consider adding:
1. Player authentication (login system)
2. Rate limiting (max rooms per IP)
3. Ban system (block IPs/users)
4. Room passwords (optional private rooms)

---

## FAQ

**Q: Do I need to keep my laptop on?**  
A: No. Once deployed to Render, server runs independently.

**Q: Can players on mobile data connect?**  
A: Yes. Render server has public internet IP.

**Q: How many players can connect simultaneously?**  
A: 8 players per room. Multiple rooms can exist simultaneously (limited by bandwidth).

**Q: What happens if I exceed bandwidth?**  
A: Without payment method: services suspend until next month. With payment method: charged $0.15/GB.

**Q: Can I use custom port (not 443)?**  
A: No. Render routes all traffic through standard ports (443 for WSS, 80 for HTTP).

**Q: Will my Android APK work after server sleeps?**  
A: Yes. APK doesn't change. Players just need to wait 60 seconds for first connection after sleep.

**Q: Can I deploy to multiple regions?**  
A: Free tier allows one service. Paid plans allow multiple deployments in different regions.

---

## Next Steps

After deployment:

1. ✅ **Test with friends** - Share APK, test real multiplayer
2. ✅ **Monitor bandwidth** - Check if 5 GB is enough for your usage
3. ✅ **Gather feedback** - Note connection issues, bugs, gameplay problems
4. ✅ **Iterate** - Fix issues, add features, redeploy

### Future Enhancements:

- **Persistent rooms:** Use Redis or Postgres to survive restarts
- **Matchmaking:** Auto-match players instead of room codes
- **Leaderboards:** Global player rankings
- **Authentication:** Player accounts and profiles
- **Multiple regions:** Deploy to US, EU, Asia for lower latency

---

## Support Resources

- **Render Docs:** https://render.com/docs
- **Render Community:** https://community.render.com
- **Godot Docs:** https://docs.godotengine.org
- **WebSocket Guide:** https://render.com/docs/websocket

---

**Congratulations!** You've deployed Cloud Arena to global internet multiplayer! 🎮🌍

Players from anywhere can now create and join rooms using 6-digit codes, without being on the same WiFi, without your laptop running, and without paying for hosting (free tier).

**Your deployment URL:** `https://cloud-arena-server.onrender.com` (replace with your actual URL)

Share your APK and let the battles begin! ⚔️
