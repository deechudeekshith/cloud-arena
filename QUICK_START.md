# Cloud Arena - Quick Start Guide

## For Users Who Want to Play NOW

### 1. Deploy Server (5 minutes)

1. **Push to GitHub:**
   ```bash
   git init
   git add .
   git commit -m "Cloud Arena"
   git remote add origin https://github.com/YOUR_USERNAME/cloud-arena.git
   git push -u origin main
   ```

2. **Deploy to Render:**
   - Go to [render.com](https://render.com) and sign up (no credit card)
   - Click "New +" → "Web Service"
   - Connect GitHub and select your repository
   - Runtime: Docker
   - Plan: Free
   - Click "Create Web Service"
   - Wait 3-5 minutes for deployment
   - Note your URL: `https://your-app-name.onrender.com`

3. **Verify it works:**
   - Visit: `https://your-app-name.onrender.com/health`
   - Should see: "healthy"

### 2. Update Client (2 minutes)

Edit `godot/scripts/game/ServerConfig.gd`:

**Line 18:**
```gdscript
var current_environment: Environment = Environment.PRODUCTION
```

**Line 99:**
```gdscript
var server_host = "your-app-name.onrender.com"  # Your Render URL here
```

### 3. Build APK (3 minutes)

In Godot Editor:
- Project → Export → Android
- Export as `Cloud_Arena_Final.apk`

OR command line:
```bash
godot --headless --export-release "Android" "Cloud_Arena_Final.apk"
```

### 4. Test! (1 minute + 60 seconds first connection)

**Device 1:**
1. Install APK
2. Open app
3. Create Room
4. **Wait ~60 seconds** (server waking up)
5. Note 6-digit room code

**Device 2:**
1. Install APK
2. Open app
3. Join Room
4. Enter code from Device 1
5. Both ready → Start Match!

---

## Important Notes

✅ **First connection takes ~60 seconds** (server sleeping)  
✅ **After that, connections are instant** (server stays awake)  
✅ **Free tier limits:** 5 GB bandwidth/month (~17 hours of 8-player matches)  
✅ **No credit card required**  
✅ **Works globally** (any WiFi or mobile data)  

⚠️ **Server sleeps after 15 min of inactivity** (rooms are lost)  
⚠️ **Solution:** Create new room after wake-up  

---

## Troubleshooting

**"Connection failed"**  
→ Server is sleeping. Wait 60 seconds and retry.

**"Room not found"**  
→ Server restarted. Host creates NEW room.

**"Version mismatch"**  
→ Rebuild project with Godot 4.3 or update Dockerfile to 4.7-dev.

---

## Full Documentation

See `RENDER_DEPLOYMENT_GUIDE.md` for complete details.

**Ready to play!** 🎮
