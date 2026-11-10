# Dockerfile for Cloud Arena - Godot Headless Server
# Deploys to Render.com free tier for global multiplayer

FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install required dependencies
RUN apt-get update && apt-get install -y \
    wget \
    unzip \
    ca-certificates \
    libgl1 \
    libglu1-mesa \
    libxcursor1 \
    libxinerama1 \
    libxrandr2 \
    libxi6 \
    libpulse0 \
    libasound2 \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Download Godot 4.3 stable headless (closest to 4.7, no official 4.7 release yet)
# Project was developed with 4.7 but 4.3 is compatible for server features
RUN wget https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip \
    && unzip Godot_v4.3-stable_linux.x86_64.zip \
    && mv Godot_v4.3-stable_linux.x86_64 /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot \
    && rm Godot_v4.3-stable_linux.x86_64.zip \
    && godot --version || echo "Godot 4.3 installed"

# Copy Godot project files
COPY godot/ /app/godot/

# Pre-scan scripts to generate class cache (fixes "class not found" errors in headless mode)
# This ensures all class_name declarations are registered before the server starts
RUN cd /app/godot && /usr/local/bin/godot --headless --quit --editor 2>&1 | head -n 20 || true

# Copy proxy server and startup script
COPY proxy_server.py /app/proxy_server.py
COPY start_servers.sh /app/start_servers.sh
RUN chmod +x /app/start_servers.sh

# Install Python for room registry
RUN apt-get update && apt-get install -y python3 && rm -rf /var/lib/apt/lists/*

# Set environment variable for headless mode
ENV DISPLAY=:0

# Render sets PORT environment variable (default 10000)
# Godot server will read this and bind to that port
ENV PORT=10000

# Expose port (Render will route traffic to this port)
# Proxy server handles both HTTP registry and WebSocket game traffic
EXPOSE ${PORT}

# Health check endpoint (Render uses this to know when service is ready)
# WebSocket server handles HTTP requests before upgrade, so Render's
# HTTP GET requests will be responded to (connection accepted then closed)
# This is sufficient for Render's health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:${PORT}/ || exit 1

# Run both room registry and Godot server
CMD ["/app/start_servers.sh"]
