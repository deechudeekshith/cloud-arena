#!/bin/bash
#
# Cloud Arena - VPS Deployment Script
# Deploys FastAPI monitor server and Godot headless server to cloud VPS
#
# Usage: ./deploy_to_vps.sh <VPS_IP_ADDRESS>
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$#" -ne 1 ]; then
    echo -e "${RED}Error: VPS IP address required${NC}"
    echo "Usage: $0 <VPS_IP_ADDRESS>"
    exit 1
fi

VPS_IP="$1"
VPS_USER="root"
DEPLOY_DIR="/opt/cloud_arena"
SERVICE_USER="cloudarena"

echo -e "${GREEN}Cloud Arena VPS Deployment${NC}"
echo "Target: ${VPS_IP}"
echo ""

# Test SSH
echo -e "${YELLOW}[1/9] Testing SSH connection...${NC}"
if ! ssh "${VPS_USER}@${VPS_IP}" "echo 'Connected'" > /dev/null 2>&1; then
    echo -e "${RED}Cannot connect via SSH${NC}"
    exit 1
fi

# Update system
echo -e "${YELLOW}[2/9] Updating system...${NC}"
ssh "${VPS_USER}@${VPS_IP}" "apt-get update && apt-get upgrade -y"

# Install dependencies
echo -e "${YELLOW}[3/9] Installing dependencies...${NC}"
ssh "${VPS_USER}@${VPS_IP}" "apt-get install -y python3 python3-pip python3-venv ufw curl wget unzip"

# Create service user
echo -e "${YELLOW}[4/9] Creating service user...${NC}"
ssh "${VPS_USER}@${VPS_IP}" << ENDSSH
if ! id -u ${SERVICE_USER} > /dev/null 2>&1; then
    useradd -r -s /bin/bash -d ${DEPLOY_DIR} ${SERVICE_USER}
fi
mkdir -p ${DEPLOY_DIR}/{monitor,godot,logs}
chown -R ${SERVICE_USER}:${SERVICE_USER} ${DEPLOY_DIR}
ENDSSH

# Upload FastAPI
echo -e "${YELLOW}[5/9] Uploading FastAPI monitor...${NC}"
cd "$(dirname "$0")/.."
scp -r monitor/server.py monitor/requirements.txt "${VPS_USER}@${VPS_IP}:${DEPLOY_DIR}/monitor/"

# Install Python deps
echo -e "${YELLOW}[6/9] Installing Python deps...${NC}"
ssh "${VPS_USER}@${VPS_IP}" << ENDSSH
cd ${DEPLOY_DIR}/monitor
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
chown -R ${SERVICE_USER}:${SERVICE_USER} ${DEPLOY_DIR}/monitor
ENDSSH

# Install Godot server
echo -e "${YELLOW}[7/9] Installing Godot server...${NC}"
ssh "${VPS_USER}@${VPS_IP}" << 'ENDSSH'
cd /tmp
# Use Godot 4.3 stable (closest stable to 4.7-dev project)
wget -O godot.zip "https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip"
if [ -f godot.zip ]; then
    unzip -o godot.zip
    mv Godot_v4.3-stable_linux.x86_64 /opt/cloud_arena/godot/godot_server 2>/dev/null || mv Godot_* /opt/cloud_arena/godot/godot_server
    chmod +x /opt/cloud_arena/godot/godot_server
    rm godot.zip
else
    echo "ERROR: Godot download failed"
    exit 1
fi
ENDSSH

# Upload game export
echo -e "${YELLOW}[8/9] Checking for game export...${NC}"
if [ -f "dist/cloud_arena_server.pck" ]; then
    scp dist/cloud_arena_server.pck "${VPS_USER}@${VPS_IP}:${DEPLOY_DIR}/godot/"
else
    echo -e "${YELLOW}WARNING: dist/cloud_arena_server.pck not found - upload manually later${NC}"
fi

# Configure firewall
echo -e "${YELLOW}[9/9] Configuring firewall...${NC}"
ssh "${VPS_USER}@${VPS_IP}" << 'ENDSSH'
ufw --force enable
ufw allow 22/tcp
ufw allow 7777/tcp
ufw allow 8901/tcp
ENDSSH

# Create systemd services
ssh "${VPS_USER}@${VPS_IP}" << ENDSSH
cat > /etc/systemd/system/cloudarena-monitor.service << 'EOF'
[Unit]
Description=Cloud Arena Monitor API
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${DEPLOY_DIR}/monitor
Environment="PATH=${DEPLOY_DIR}/monitor/venv/bin"
ExecStart=${DEPLOY_DIR}/monitor/venv/bin/uvicorn server:app --host 0.0.0.0 --port 8901 --workers 2
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/cloudarena-game.service << 'EOF'
[Unit]
Description=Cloud Arena Game Server
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${DEPLOY_DIR}/godot
ExecStart=${DEPLOY_DIR}/godot/godot_server --headless --main-pack cloud_arena_server.pck
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
ENDSSH

echo -e "${GREEN}Deployment complete!${NC}"
echo ""
echo "Start services:"
echo "  ssh ${VPS_USER}@${VPS_IP} 'systemctl start cloudarena-monitor cloudarena-game'"
echo "  ssh ${VPS_USER}@${VPS_IP} 'systemctl enable cloudarena-monitor cloudarena-game'"
