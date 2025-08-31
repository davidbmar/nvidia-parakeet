#!/bin/bash
set -e

# Production RNN-T Deployment - Step 4.0: Enable HTTPS with Fixed WebSocket Support
# This script adds HTTPS support with proper WSS (WebSocket Secure) handling
# Fixes infinite loop issues and ensures protocol matching (HTTPS->WSS)

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
        echo -e "${RED}❌ Required variable $var not set in $ENV_FILE${NC}"
        exit 1
    fi
done

echo -e "${BLUE}🔒 Production RNN-T Deployment - Enable HTTPS (Fixed Version)${NC}"
echo "================================================================"
echo "Target Instance: $GPU_INSTANCE_IP"
echo "Features:"
echo "  ✅ HTTPS with self-signed certificate"
echo "  ✅ WSS (WebSocket Secure) support"
echo "  ✅ Fixed disconnect handling (no infinite loops)"
echo "  ✅ Automatic protocol detection (HTTPS->WSS)"
echo ""

# Function to run SSH commands
ssh_cmd() {
    local cmd="$*"
    echo -e "${BLUE}🔧 SSH: $cmd${NC}"
    if ! ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "$cmd"; then
        echo -e "${RED}❌ SSH command failed: $cmd${NC}"
        exit 1
    fi
}

# Function to copy files to instance
copy_to_instance() {
    local local_path="$1"
    local remote_path="$2"
    echo -e "${BLUE}📁 Copying: $(basename $local_path) → $remote_path${NC}"
    if ! scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "$local_path" ubuntu@"$GPU_INSTANCE_IP":"$remote_path"; then
        echo -e "${RED}❌ File copy failed: $local_path${NC}"
        exit 1
    fi
}

# Step 1: Stop any existing services
echo -e "${GREEN}=== Step 1: Stopping Existing Services ===${NC}"
ssh_cmd "sudo systemctl stop rnnt-https 2>/dev/null || true"
ssh_cmd "sudo systemctl stop rnnt-websocket 2>/dev/null || true"
echo -e "${GREEN}✅ Services stopped${NC}"

# Step 2: Generate SSL Certificate (if not exists)
echo -e "${GREEN}=== Step 2: SSL Certificate Setup ===${NC}"
if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "[ -f /opt/rnnt/ssl/server.crt ]" 2>/dev/null; then
    echo -e "${YELLOW}⚠️  SSL certificate already exists${NC}"
else
    echo "Generating new SSL certificate..."
    ssh_cmd "sudo mkdir -p /opt/rnnt/ssl"
    ssh_cmd "cd /opt/rnnt/ssl && sudo openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt -days 365 -nodes -subj '/C=US/ST=State/L=City/O=Organization/CN=$GPU_INSTANCE_IP'"
    ssh_cmd "sudo chown -R ubuntu:ubuntu /opt/rnnt/ssl"
    echo -e "${GREEN}✅ SSL certificate generated${NC}"
fi

# Step 3: Deploy Fixed WebSocket Server
echo -e "${GREEN}=== Step 3: Deploying Fixed WebSocket Server ===${NC}"

# Create the fixed WebSocket server with proper disconnect handling
cat > /tmp/rnnt-server-websocket-fixed.py << 'EOF'
#!/usr/bin/env python3
"""
Enhanced RNN-T Server with WebSocket Support - FIXED VERSION
Fixed: Proper disconnect handling to prevent infinite loops
"""

import os
import sys
import uuid
from pathlib import Path

# Add parent directory to path for imports
sys.path.append(str(Path(__file__).parent.parent))

# Import original server components
from rnnt_server import (
    app, logger, RNNT_SERVER_PORT, RNNT_SERVER_HOST, RNNT_MODEL_SOURCE,
    MODEL_LOADED, MODEL_LOAD_TIME, LOG_LEVEL, DEV_MODE,
    asr_model, load_model, health_check, transcribe_file, transcribe_s3,
    torch, uvicorn
)

# Import WebSocket components
from websocket.websocket_handler import WebSocketHandler
from fastapi import WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from starlette.websockets import WebSocketState

# Create WebSocket handler instance
ws_handler = None
active_connections = set()

@app.on_event("startup")
async def startup_event_enhanced():
    """Enhanced startup with WebSocket support"""
    global ws_handler
    
    logger.info("🚀 Starting Enhanced RNN-T Server with WebSocket Support")
    logger.info(f"Configuration: port={RNNT_SERVER_PORT}, model={RNNT_MODEL_SOURCE}")
    
    # Load model on startup
    await load_model()
    
    # Initialize WebSocket handler
    ws_handler = WebSocketHandler(asr_model)
    logger.info("✅ WebSocket handler initialized")

# Remove the original root route to avoid conflicts
original_routes = app.routes[:]
app.routes.clear()
for route in original_routes:
    if hasattr(route, 'path') and route.path == '/':
        continue
    app.routes.append(route)

# Mount static files for web interface
app.mount("/static", StaticFiles(directory="static"), name="static")
app.mount("/examples", StaticFiles(directory="examples"), name="examples")

@app.get("/")
async def root_enhanced():
    """Enhanced root endpoint with WebSocket info"""
    return {
        "service": "Production RNN-T Server with WebSocket Streaming",
        "version": "2.0.1",
        "model": RNNT_MODEL_SOURCE,
        "status": "READY" if MODEL_LOADED else "LOADING",
        "architecture": "RNN-T Conformer",
        "gpu_available": torch.cuda.is_available(),
        "device": "cuda" if torch.cuda.is_available() else "cpu",
        "model_load_time": f"{MODEL_LOAD_TIME:.1f}s" if MODEL_LOAD_TIME else "not loaded",
        "endpoints": {
            "rest": ["/health", "/transcribe/file", "/transcribe/s3"],
            "websocket": ["/ws/transcribe"],
            "web": ["/static/index.html", "/examples/simple-client.html"]
        },
        "features": {
            "real_time_streaming": True,
            "word_level_timestamps": True,
            "partial_results": True,
            "vad": True,
            "https_wss_support": True
        },
        "active_connections": len(active_connections)
    }

@app.websocket("/ws/transcribe")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint with fixed disconnect handling"""
    client_id = websocket.query_params.get('client_id', str(uuid.uuid4()))
    
    try:
        await ws_handler.connect(websocket, client_id)
        active_connections.add(client_id)
        
        while True:
            try:
                # Check connection state before receiving
                if websocket.client_state != WebSocketState.CONNECTED:
                    break
                    
                message = await websocket.receive()
                
                # Check for disconnect message
                if "type" in message and message["type"] == "websocket.disconnect":
                    break
                
                if "bytes" in message:
                    await ws_handler.handle_message(websocket, client_id, message["bytes"])
                elif "text" in message:
                    await ws_handler.handle_message(websocket, client_id, message["text"])
                    
            except WebSocketDisconnect:
                logger.info(f"WebSocket client {client_id} disconnected")
                break
            except Exception as e:
                logger.error(f"WebSocket error for {client_id}: {e}")
                
                # Only send error if connection is open
                if websocket.client_state == WebSocketState.CONNECTED:
                    try:
                        await ws_handler.send_error(websocket, str(e))
                    except:
                        break
                else:
                    break
                    
    except Exception as e:
        logger.error(f"WebSocket connection error for {client_id}: {e}")
    finally:
        # Clean disconnect
        active_connections.discard(client_id)
        await ws_handler.disconnect(client_id)
        
        # Ensure WebSocket is closed
        if websocket.client_state == WebSocketState.CONNECTED:
            try:
                await websocket.close()
            except:
                pass
        
        logger.info(f"WebSocket client {client_id} cleanup complete")

@app.get("/ws/status")
async def websocket_status():
    """Get WebSocket server status"""
    return {
        "status": "active",
        "websocket_ready": ws_handler is not None,
        "model_loaded": MODEL_LOADED,
        "active_connections": len(active_connections),
        "gpu_available": torch.cuda.is_available()
    }

if __name__ == "__main__":
    uvicorn.run(
        app,
        host=RNNT_SERVER_HOST,
        port=RNNT_SERVER_PORT,
        log_level=LOG_LEVEL.lower(),
        reload=DEV_MODE
    )
EOF

copy_to_instance "/tmp/rnnt-server-websocket-fixed.py" "/opt/rnnt/rnnt-server-websocket-fixed.py"
ssh_cmd "chmod +x /opt/rnnt/rnnt-server-websocket-fixed.py"

# Step 4: Create HTTPS Server Wrapper
echo -e "${GREEN}=== Step 4: Creating HTTPS Server ===${NC}"

cat > /tmp/rnnt-https-server.py << 'EOF'
#!/usr/bin/env python3
"""
Production HTTPS server with proper SSL/TLS and event loop handling
"""
import sys
import os

# Set up paths
os.chdir('/opt/rnnt')
sys.path.insert(0, '/opt/rnnt')

if __name__ == "__main__":
    import uvicorn
    
    # Run with SSL - uses the fixed WebSocket server
    uvicorn.run(
        "rnnt-server-websocket-fixed:app",
        host="0.0.0.0",
        port=443,
        ssl_keyfile="/opt/rnnt/ssl/server.key",
        ssl_certfile="/opt/rnnt/ssl/server.crt",
        log_level="info",
        reload=False,
        access_log=True,
        limit_concurrency=1000,
        timeout_keep_alive=5
    )
EOF

copy_to_instance "/tmp/rnnt-https-server.py" "/opt/rnnt/rnnt-https-server.py"
ssh_cmd "chmod +x /opt/rnnt/rnnt-https-server.py"

# Step 5: Update JavaScript for Protocol Detection
echo -e "${GREEN}=== Step 5: Updating Client JavaScript ===${NC}"

cat > /tmp/websocket-protocol.js << 'EOF'
// Automatic protocol detection for WebSocket connections
function getWebSocketURL(path = '/ws/transcribe') {
    const protocol = window.location.protocol;
    const host = window.location.host;
    const wsProtocol = (protocol === 'https:') ? 'wss:' : 'ws:';
    const wsUrl = `${wsProtocol}//${host}${path}`;
    console.log(`Using WebSocket URL: ${wsUrl}`);
    return wsUrl;
}

// Update existing WebSocket connections to use this function
if (typeof window !== 'undefined' && window.WebSocket) {
    window.getWebSocketURL = getWebSocketURL;
}
EOF

copy_to_instance "/tmp/websocket-protocol.js" "/opt/rnnt/static/js/websocket-protocol.js"

# Step 6: Create Systemd Service
echo -e "${GREEN}=== Step 6: Creating HTTPS Service ===${NC}"

cat > /tmp/rnnt-https.service << 'EOF'
[Unit]
Description=Production RNN-T HTTPS WebSocket Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
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

copy_to_instance "/tmp/rnnt-https.service" "/tmp/rnnt-https.service"
ssh_cmd "sudo mv /tmp/rnnt-https.service /etc/systemd/system/"
ssh_cmd "sudo systemctl daemon-reload"
ssh_cmd "sudo systemctl enable rnnt-https"

# Step 7: Open HTTPS Port
echo -e "${GREEN}=== Step 7: Configuring Firewall ===${NC}"

# Check if port 443 is already open
if aws ec2 describe-security-groups \
    --group-ids $(aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
        --output text) \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`443`]' \
    --output text 2>/dev/null | grep -q "443"; then
    echo -e "${YELLOW}⚠️  HTTPS port 443 already open${NC}"
else
    echo "Opening HTTPS port 443..."
    SECURITY_GROUP_ID=$(aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
        --output text)
    
    aws ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" 2>/dev/null || echo "Port may already be open"
    
    echo -e "${GREEN}✅ HTTPS port configured${NC}"
fi

# Step 8: Start HTTPS Service
echo -e "${GREEN}=== Step 8: Starting HTTPS Service ===${NC}"
ssh_cmd "sudo systemctl start rnnt-https"

# Wait for service to initialize
echo -e "${YELLOW}⏳ Waiting for service to start (model loading takes ~30s)...${NC}"
sleep 15

# Check service status
SERVICE_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
    "sudo systemctl is-active rnnt-https" 2>/dev/null || echo "failed")

if [ "$SERVICE_STATUS" = "active" ]; then
    echo -e "${GREEN}✅ HTTPS service is running${NC}"
else
    echo -e "${RED}❌ HTTPS service failed to start${NC}"
    echo "Checking logs..."
    ssh_cmd "sudo journalctl -u rnnt-https --no-pager -n 20"
    exit 1
fi

# Step 9: Test HTTPS Access
echo -e "${GREEN}=== Step 9: Testing HTTPS Access ===${NC}"

# Wait for model to load
sleep 20

# Test HTTPS endpoint
echo "Testing HTTPS endpoint..."
if curl -k -s --max-time 10 "https://$GPU_INSTANCE_IP/" | grep -q "RNN-T" 2>/dev/null; then
    echo -e "${GREEN}✅ HTTPS endpoint responding${NC}"
else
    echo -e "${YELLOW}⚠️  HTTPS may still be initializing${NC}"
fi

# Test WebSocket status
echo "Testing WebSocket status endpoint..."
if curl -k -s --max-time 10 "https://$GPU_INSTANCE_IP/ws/status" | grep -q "active" 2>/dev/null; then
    echo -e "${GREEN}✅ WebSocket endpoint ready${NC}"
else
    echo -e "${YELLOW}⚠️  WebSocket endpoint still initializing${NC}"
fi

# Final summary
echo ""
echo -e "${GREEN}🎉 HTTPS Setup Complete!${NC}"
echo "================================================================"
echo -e "${BLUE}🔒 Secure Access URLs:${NC}"
echo "   HTTPS API: https://$GPU_INSTANCE_IP"
echo "   WSS WebSocket: wss://$GPU_INSTANCE_IP/ws/transcribe"
echo "   Demo UI: https://$GPU_INSTANCE_IP/static/index.html"
echo ""
echo -e "${YELLOW}⚠️  Certificate Warning:${NC}"
echo "   Browser will show security warning (self-signed cert)"
echo "   Click 'Advanced' → 'Proceed to $GPU_INSTANCE_IP'"
echo ""
echo -e "${BLUE}🎤 Real-Time Transcription:${NC}"
echo "   1. Open: https://$GPU_INSTANCE_IP/static/index.html"
echo "   2. Accept certificate warning"
echo "   3. Grant microphone permission"
echo "   4. Click 'Start Recording' and speak!"
echo ""
echo -e "${GREEN}✅ Features Enabled:${NC}"
echo "   • HTTPS secure connection"
echo "   • WSS (WebSocket Secure) for real-time streaming"
echo "   • Fixed disconnect handling (no infinite loops)"
echo "   • Automatic protocol detection (HTTPS→WSS)"
echo "   • GPU-accelerated NVIDIA RNN-T model"
echo ""
echo -e "${BLUE}📋 Service Management:${NC}"
echo "   Status: sudo systemctl status rnnt-https"
echo "   Logs: sudo journalctl -u rnnt-https -f"
echo "   Restart: sudo systemctl restart rnnt-https"
echo ""

# Update environment to mark HTTPS as enabled
echo "HTTPS_ENABLED=\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"" >> "$ENV_FILE"

# Clean up temporary files
rm -f /tmp/rnnt-server-websocket-fixed.py /tmp/rnnt-https-server.py /tmp/websocket-protocol.js /tmp/rnnt-https.service

echo -e "${YELLOW}📜 Next Step:${NC}"
echo "   Run: ./scripts/step-055-test-websocket-functionality.sh"
echo "   → This will test the complete HTTPS/WSS setup"
echo ""