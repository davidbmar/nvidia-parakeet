#!/bin/bash
set -e

# Production RNN-T Deployment - Step 3.1: Start WebSocket Server
# This script starts the WebSocket-enabled RNN-T server
#
# Prerequisites:
# - Step 026 (WebSocket deployment) must be completed first
#
# What this script does:
# 1. Stops the regular RNN-T server
# 2. Creates systemd service for WebSocket server
# 3. Starts WebSocket server with monitoring
# 4. Verifies WebSocket endpoints

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    exit 1
fi

source "$ENV_FILE"

# Validate required variables
required_vars=("GPU_INSTANCE_IP" "SSH_KEY_FILE")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}❌ Required variable $var not set${NC}"
        exit 1
    fi
done

echo -e "${BLUE}🚀 Production RNN-T Deployment - Start WebSocket Server${NC}"
echo "================================================================"
echo "Target Instance: $GPU_INSTANCE_IP"
echo ""

# Function to run SSH command with error handling
ssh_cmd() {
    local cmd="$*"
    echo -e "${BLUE}🔧 SSH: $cmd${NC}"
    if ! ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "$cmd"; then
        echo -e "${RED}❌ SSH command failed: $cmd${NC}"
        exit 1
    fi
}

# Step 1: Stop Regular RNN-T Server
echo -e "${GREEN}=== Step 1: Stopping Regular RNN-T Server ===${NC}"
ssh_cmd "sudo systemctl stop rnnt-server || echo 'Service was not running'"
ssh_cmd "sudo systemctl disable rnnt-server || echo 'Service not enabled'"

# Step 2: Create WebSocket Service
echo -e "${GREEN}=== Step 2: Creating WebSocket Service ===${NC}"

# Create systemd service file
WEBSOCKET_SERVICE="[Unit]
Description=Production RNN-T WebSocket Transcription Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/rnnt
Environment=PYTHONPATH=/opt/rnnt
Environment=CUDA_VISIBLE_DEVICES=0
Environment=TORCH_CUDA_ARCH_LIST=7.5
ExecStart=/opt/rnnt/venv/bin/python rnnt-server-websocket.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rnnt-websocket
KillMode=mixed
TimeoutStopSec=30

# Resource limits
MemoryMax=6G
CPUQuota=200%

[Install]
WantedBy=multi-user.target"

echo "$WEBSOCKET_SERVICE" > /tmp/rnnt-websocket.service

# Copy and install service
echo -e "${BLUE}📁 Installing systemd service${NC}"
scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no /tmp/rnnt-websocket.service ubuntu@"$GPU_INSTANCE_IP":/tmp/

ssh_cmd "sudo mv /tmp/rnnt-websocket.service /etc/systemd/system/"
ssh_cmd "sudo systemctl daemon-reload"
ssh_cmd "sudo systemctl enable rnnt-websocket"

# Step 3: Start WebSocket Server
echo -e "${GREEN}=== Step 3: Starting WebSocket Server ===${NC}"
ssh_cmd "sudo systemctl start rnnt-websocket"

# Wait for service to start
echo -e "${YELLOW}⏳ Waiting for WebSocket server to initialize...${NC}"
sleep 15

# Check service status
SERVICE_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "sudo systemctl is-active rnnt-websocket" 2>/dev/null || echo "failed")

if [ "$SERVICE_STATUS" = "active" ]; then
    echo -e "${GREEN}✅ WebSocket server is running${NC}"
else
    echo -e "${RED}❌ WebSocket server failed to start${NC}"
    echo "Checking logs..."
    ssh_cmd "sudo journalctl -u rnnt-websocket --no-pager -n 20"
    exit 1
fi

# Step 4: Health Check
echo -e "${GREEN}=== Step 4: Health Check ===${NC}"
echo -e "${YELLOW}⏳ Testing server endpoints...${NC}"

# Wait a bit more for full initialization
sleep 10

# Test REST endpoints
echo "Testing root endpoint..."
if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s --connect-timeout 10 http://localhost:8000/ | grep -q 'WebSocket'" 2>/dev/null; then
    echo -e "${GREEN}✅ Root endpoint responding${NC}"
else
    echo -e "${YELLOW}⚠️  Root endpoint not ready yet${NC}"
fi

echo "Testing health endpoint..."
if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s --connect-timeout 10 http://localhost:8000/health | grep -q 'healthy'" 2>/dev/null; then
    echo -e "${GREEN}✅ Health endpoint responding${NC}"
else
    echo -e "${YELLOW}⚠️  Health endpoint not ready yet${NC}"
fi

echo "Testing WebSocket status..."
if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s --connect-timeout 10 http://localhost:8000/ws/status | grep -q 'active'" 2>/dev/null; then
    echo -e "${GREEN}✅ WebSocket endpoint responding${NC}"
else
    echo -e "${YELLOW}⚠️  WebSocket endpoint not ready yet${NC}"
fi

# Step 5: Display Connection Info
echo -e "${GREEN}=== Step 5: Connection Information ===${NC}"

echo ""
echo -e "${GREEN}🎉 WebSocket Server Started Successfully!${NC}"
echo "================================================================"
echo "Server Status: ACTIVE"
echo ""
echo -e "${BLUE}🌐 Access URLs:${NC}"
echo "   REST API: http://$GPU_INSTANCE_IP:8000"
echo "   WebSocket: ws://$GPU_INSTANCE_IP:8000/ws/transcribe"
echo "   Demo UI: http://$GPU_INSTANCE_IP:8000/static/index.html"
echo "   Simple Example: http://$GPU_INSTANCE_IP:8000/examples/simple-client.html"
echo ""
echo -e "${BLUE}🔧 Server Management:${NC}"
echo "   Status: sudo systemctl status rnnt-websocket"
echo "   Logs: sudo journalctl -u rnnt-websocket -f"
echo "   Restart: sudo systemctl restart rnnt-websocket"
echo ""
echo -e "${YELLOW}📜 Next Steps:${NC}"
echo "1. Run: ./scripts/step-032-test-websocket.sh"
echo "   → This will run comprehensive tests on all WebSocket functionality"
echo "   → Tests include REST API, WebSocket connectivity, and audio streaming"
echo "2. Open demo UI: http://$GPU_INSTANCE_IP:8000/static/index.html"
echo "   → Interactive web interface for real-time audio recording and transcription"
echo "3. Test examples: http://$GPU_INSTANCE_IP:8000/examples/"
echo "   → Simple client examples and developer documentation"
echo ""

# Auto-run next script function
read -p "Would you like to automatically run step-032-test-websocket.sh now? (y/N): " -r
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}🧪 Running comprehensive tests automatically...${NC}"
    exec "$SCRIPT_DIR/step-032-test-websocket.sh"
fi

# Clean up
rm -f /tmp/rnnt-websocket.service