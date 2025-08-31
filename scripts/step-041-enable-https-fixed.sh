#!/bin/bash
set -e

# Production RNN-T Deployment - Enable HTTPS (FIXED VERSION)
# This script enables HTTPS with proper systemd service for production deployment

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

# Setup logging
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
LOG_DIR="$SCRIPT_DIR/../logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/step-041-enable-https-fixed-$TIMESTAMP.log"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE" >&2
}

# Start logging
log "=== Step 041: Enable HTTPS (Fixed Version) Started ==="
log "Log file: $LOG_FILE"
log "Target Instance: $GPU_INSTANCE_IP"
log "SSH Key: $SSH_KEY_FILE"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔒 Production RNN-T Deployment - Enable HTTPS (FIXED VERSION)${NC}"
echo "================================================================"
echo "Target Instance: ${GPU_INSTANCE_IP}"
echo "Features:"
echo "  ✅ HTTPS with self-signed certificate"
echo "  ✅ WSS (WebSocket Secure) support" 
echo "  ✅ Proper systemd service with root privileges"
echo "  ✅ Auto-restart on reboot"
echo ""

# Verify required variables
log "Verifying environment variables..."
if [[ -z "$GPU_INSTANCE_IP" ]] || [[ -z "$SSH_KEY_FILE" ]]; then
    log_error "Missing required environment variables"
    log_error "Required: GPU_INSTANCE_IP, SSH_KEY_FILE"
    echo -e "${RED}❌ Missing required environment variables${NC}"
    echo "Required: GPU_INSTANCE_IP, SSH_KEY_FILE"
    exit 1
fi
log "Environment variables verified: GPU_INSTANCE_IP=$GPU_INSTANCE_IP"

echo -e "${GREEN}=== Step 1: Stopping Existing Services ===${NC}"
log "Stopping existing HTTPS and WebSocket services..."
if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "sudo systemctl stop rnnt-https 2>/dev/null || true"; then
    log "rnnt-https service stopped successfully"
else
    log_error "Failed to stop rnnt-https service"
fi

if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "sudo systemctl stop rnnt-websocket 2>/dev/null || true"; then
    log "rnnt-websocket service stopped successfully"
else
    log_error "Failed to stop rnnt-websocket service"
fi
echo -e "${GREEN}✅ Services stopped${NC}"

echo -e "${GREEN}=== Step 2: SSL Certificate Setup ===${NC}"
log "Checking SSL certificate setup..."
# Check if certificate already exists
if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "test -f /opt/rnnt/server.crt"; then
    log "SSL certificate already exists, skipping generation"
    echo -e "${YELLOW}⚠️  SSL certificate already exists${NC}"
else
    log "Generating self-signed SSL certificate for $GPU_INSTANCE_IP..."
    echo "🔐 Generating self-signed SSL certificate..."
    if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "
        cd /opt/rnnt &&
        openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt -days 365 -nodes \\
            -subj '/CN=${GPU_INSTANCE_IP}/O=RNN-T Production/C=US' &&
        chmod 600 server.key server.crt &&
        echo '✅ SSL certificate generated'
    "; then
        log "SSL certificate generated successfully"
    else
        log_error "Failed to generate SSL certificate"
        exit 1
    fi
fi

echo -e "${GREEN}=== Step 3: Deploying Fixed WebSocket Components ===${NC}"
# Copy all fixed WebSocket components with tensor conversion fixes
log "Copying WebSocket components with tensor fixes..."

if scp -i "$SSH_KEY_FILE" "$SCRIPT_DIR/../websocket/websocket_handler.py" ubuntu@"$GPU_INSTANCE_IP":/opt/rnnt/websocket/websocket_handler.py; then
    log "websocket_handler.py copied successfully"
else
    log_error "Failed to copy websocket_handler.py"
    exit 1
fi

if scp -i "$SSH_KEY_FILE" "$SCRIPT_DIR/../websocket/transcription_stream.py" ubuntu@"$GPU_INSTANCE_IP":/opt/rnnt/websocket/transcription_stream.py; then
    log "transcription_stream.py copied successfully"
else
    log_error "Failed to copy transcription_stream.py"
    exit 1
fi

if scp -i "$SSH_KEY_FILE" "$SCRIPT_DIR/../websocket/audio_processor.py" ubuntu@"$GPU_INSTANCE_IP":/opt/rnnt/websocket/audio_processor.py; then
    log "audio_processor.py copied successfully"
else
    log_error "Failed to copy audio_processor.py"
    exit 1
fi

# Verify tensor fix is deployed
log "Verifying tensor conversion fix is deployed..."
if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "grep -q 'isinstance.*torch.Tensor' /opt/rnnt/websocket/transcription_stream.py"; then
    log "✅ Tensor conversion fix verified in deployed file"
else
    log_error "❌ Tensor conversion fix not found in deployed file"
    exit 1
fi

# Verify MODEL DEBUG line is deployed  
if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "grep -q 'MODEL DEBUG' /opt/rnnt/websocket/transcription_stream.py"; then
    log "✅ Debug logging verified in deployed file"
else
    log_error "❌ Debug logging not found in deployed file"
    exit 1
fi

# Clear Python cache to ensure new files are loaded
log "Clearing Python cache..."
if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "sudo rm -rf /opt/rnnt/websocket/__pycache__"; then
    log "Python cache cleared successfully"
else
    log_error "Failed to clear Python cache"
    exit 1
fi

echo -e "${GREEN}✅ Fixed WebSocket components deployed and verified${NC}"

echo -e "${GREEN}=== Step 4: Updating Client JavaScript ===${NC}"
# Ensure static/js directory exists
ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "mkdir -p /opt/rnnt/static/js"

# Copy the updated client with protocol detection
scp -i "$SSH_KEY_FILE" "$SCRIPT_DIR/../static/websocket-client.js" ubuntu@"$GPU_INSTANCE_IP":/opt/rnnt/static/websocket-client.js
echo -e "${GREEN}✅ Client JavaScript updated${NC}"

echo -e "${GREEN}=== Step 5: Creating HTTPS Systemd Service ===${NC}"
# Create the systemd service file with proper root privileges
cat > /tmp/rnnt-https.service << 'EOF'
[Unit]
Description=Production RNN-T HTTPS WebSocket Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/rnnt
Environment=PYTHONPATH=/opt/rnnt
Environment=CUDA_VISIBLE_DEVICES=0
ExecStart=/opt/rnnt/venv/bin/python /opt/rnnt/rnnt-https-server.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rnnt-https
KillMode=mixed
TimeoutStopSec=30
TimeoutStartSec=120

# Resource limits
MemoryMax=6G
CPUQuota=200%

[Install]
WantedBy=multi-user.target
EOF

# Install the service
scp -i "$SSH_KEY_FILE" /tmp/rnnt-https.service ubuntu@"$GPU_INSTANCE_IP":/tmp/
ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "sudo mv /tmp/rnnt-https.service /etc/systemd/system/"
echo -e "${GREEN}✅ Systemd service created${NC}"

echo -e "${GREEN}=== Step 6: Configuring Firewall ===${NC}"
# Check if port 443 is open
if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "sudo ufw status | grep -q '443'"; then
    echo -e "${YELLOW}⚠️  HTTPS port 443 already open${NC}"
else
    echo "🔧 Opening HTTPS port 443..."
    ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "sudo ufw allow 443/tcp"
    echo -e "${GREEN}✅ HTTPS port opened${NC}"
fi

echo -e "${GREEN}=== Step 7: Starting HTTPS Service ===${NC}"
ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "
    sudo systemctl daemon-reload &&
    sudo systemctl enable rnnt-https &&
    sudo systemctl start rnnt-https
"

echo -e "${YELLOW}⏳ Waiting for service to start (model loading takes ~30s)...${NC}"
sleep 35

# Check service status
if ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "sudo systemctl is-active --quiet rnnt-https"; then
    echo -e "${GREEN}✅ HTTPS service is running${NC}"
else
    echo -e "${RED}❌ HTTPS service failed to start${NC}"
    echo "Checking logs..."
    ssh -i "$SSH_KEY_FILE" ubuntu@"$GPU_INSTANCE_IP" "sudo journalctl -u rnnt-https --no-pager -n 20"
    exit 1
fi

echo -e "${GREEN}=== Step 8: Health Check ===${NC}"
echo -e "${YELLOW}⏳ Testing HTTPS endpoints...${NC}"

# Test root endpoint
if curl -k --connect-timeout 10 "https://$GPU_INSTANCE_IP/" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ Root endpoint responding${NC}"
else
    echo -e "${RED}❌ Root endpoint not responding${NC}"
    exit 1
fi

# Test WebSocket status
if curl -k --connect-timeout 10 "https://$GPU_INSTANCE_IP/ws/status" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ WebSocket endpoint responding${NC}"
else
    echo -e "${RED}❌ WebSocket endpoint not responding${NC}"
    exit 1
fi

echo -e "${GREEN}=== Step 9: Connection Information ===${NC}"
echo ""
echo -e "${GREEN}🎉 HTTPS WebSocket Server Started Successfully!${NC}"
echo "================================================================"
echo "Server Status: ACTIVE"
echo ""
echo -e "${BLUE}🌐 Access URLs:${NC}"
echo "   HTTPS API: https://$GPU_INSTANCE_IP/"
echo "   WebSocket: wss://$GPU_INSTANCE_IP/ws/transcribe"
echo "   Demo UI: https://$GPU_INSTANCE_IP/static/index.html"
echo "   Simple Example: https://$GPU_INSTANCE_IP/examples/simple-client.html"
echo ""
echo -e "${BLUE}🔧 Server Management:${NC}"
echo "   Status: sudo systemctl status rnnt-https"
echo "   Logs: sudo journalctl -u rnnt-https -f"
echo "   Restart: sudo systemctl restart rnnt-https"
echo ""
echo -e "${YELLOW}📜 Next Steps:${NC}"
echo "1. Test the web interface: https://$GPU_INSTANCE_IP/static/index.html"
echo "2. The server will auto-restart on reboot"
echo "3. Monitor logs for any issues: sudo journalctl -u rnnt-https -f"
echo ""
echo -e "${GREEN}✅ Production HTTPS deployment complete!${NC}"

# Clean up temporary files
rm -f /tmp/rnnt-https.service