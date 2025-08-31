#!/bin/bash
set -e

# Production RNN-T Deployment - Step 4.0: Enable HTTPS
# This script adds HTTPS support to the WebSocket server using self-signed certificates
# NVIDIA/DevOps optimized for smooth deployment experience

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

echo -e "${BLUE}🔒 Production RNN-T Deployment - Enable HTTPS${NC}"
echo "================================================================"
echo "Target Instance: $GPU_INSTANCE_IP"
echo "Adding HTTPS support with self-signed certificate"
echo ""

# Function to run SSH commands with better error handling
ssh_cmd() {
    local cmd="$*"
    echo -e "${BLUE}🔧 SSH: $cmd${NC}"
    if ! ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "$cmd"; then
        echo -e "${RED}❌ SSH command failed: $cmd${NC}"
        exit 1
    fi
}

# Function to check if Python module can be imported
check_python_import() {
    local module_name="$1"
    local import_test=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
        "cd /opt/rnnt && source venv/bin/activate && python -c 'import $module_name; print(\"OK\")' 2>/dev/null || echo 'FAIL'")
    echo "$import_test"
}

# Step 1: Check Prerequisites and Fix Import Issues
echo -e "${GREEN}=== Step 1: Checking Prerequisites ===${NC}"

# Check if WebSocket server exists
WEBSOCKET_EXISTS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
    "[ -f /opt/rnnt/rnnt-server-websocket.py ] && echo 'YES' || echo 'NO'")

if [ "$WEBSOCKET_EXISTS" != "YES" ]; then
    echo -e "${RED}❌ WebSocket server not found. Please run step-035-deploy-websocket.sh first${NC}"
    exit 1
fi

# Fix Python import naming - create symbolic link with underscores
echo "Fixing Python import naming for rnnt_server_websocket..."
ssh_cmd "cd /opt/rnnt && ln -sf rnnt-server-websocket.py rnnt_server_websocket.py"

# Verify the import works
IMPORT_CHECK=$(check_python_import "rnnt_server_websocket")
if [ "$IMPORT_CHECK" != "OK" ]; then
    echo -e "${RED}❌ Cannot import rnnt_server_websocket module${NC}"
    echo "Checking available files in /opt/rnnt/..."
    ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "ls -la /opt/rnnt/*.py"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites checked and import issues fixed${NC}"

# Step 2: Generate SSL Certificate
echo -e "${GREEN}=== Step 2: Generating SSL Certificate ===${NC}"

# Create SSL certificate on the instance
ssh_cmd "sudo mkdir -p /opt/rnnt/ssl"
ssh_cmd "cd /opt/rnnt/ssl && sudo openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt -days 365 -nodes -subj '/C=US/ST=State/L=City/O=Organization/CN=$GPU_INSTANCE_IP'"
ssh_cmd "sudo chown -R ubuntu:ubuntu /opt/rnnt/ssl"

echo -e "${GREEN}✅ SSL certificate generated${NC}"

# Step 3: Update Security Group for HTTPS
echo -e "${GREEN}=== Step 3: Opening HTTPS Port (443) ===${NC}"

if [ -n "$SECURITY_GROUP_ID" ]; then
    # Check if HTTPS rule already exists
    HTTPS_RULE_EXISTS=$(aws ec2 describe-security-groups \
        --group-ids "$SECURITY_GROUP_ID" \
        --region "$AWS_REGION" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`443\` && ToPort==\`443\`]" \
        --output text)
    
    if [ -z "$HTTPS_RULE_EXISTS" ] || [ "$HTTPS_RULE_EXISTS" = "None" ]; then
        echo "Adding HTTPS rule to security group..."
        aws ec2 authorize-security-group-ingress \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port 443 \
            --cidr 0.0.0.0/0 \
            --region "$AWS_REGION"
        echo -e "${GREEN}✅ HTTPS port 443 opened${NC}"
    else
        echo -e "${YELLOW}⚠️  HTTPS port 443 already open${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Security group ID not found, please open port 443 manually${NC}"
fi

# Step 4: Create HTTPS-enabled WebSocket Server
echo -e "${GREEN}=== Step 4: Creating HTTPS WebSocket Server ===${NC}"

# Create a new WebSocket server file with HTTPS support
HTTPS_SERVER_SCRIPT='#!/opt/rnnt/venv/bin/python
import asyncio
import ssl
import uvicorn
from rnnt_server_websocket import app
import logging

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

if __name__ == "__main__":
    # Create SSL context
    ssl_context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ssl_context.load_cert_chain(
        "/opt/rnnt/ssl/server.crt",
        "/opt/rnnt/ssl/server.key"
    )
    
    logger.info("🔒 Starting HTTPS WebSocket Server")
    logger.info("📡 HTTPS: https://0.0.0.0:443")
    logger.info("📡 HTTP: http://0.0.0.0:8000 (fallback)")
    
    # Run with HTTPS on port 443 and HTTP on port 8000
    config = uvicorn.Config(
        app=app,
        host="0.0.0.0",
        port=443,
        ssl_certfile="/opt/rnnt/ssl/server.crt",
        ssl_keyfile="/opt/rnnt/ssl/server.key",
        log_level="info"
    )
    server = uvicorn.Server(config)
    
    try:
        asyncio.run(server.serve())
    except Exception as e:
        logger.error(f"Failed to start HTTPS server: {e}")
        logger.info("Falling back to HTTP on port 8000")
        # Fallback to HTTP
        config_http = uvicorn.Config(
            app=app,
            host="0.0.0.0", 
            port=8000,
            log_level="info"
        )
        server_http = uvicorn.Server(config_http)
        asyncio.run(server_http.serve())
'

# Write the HTTPS server script
echo "$HTTPS_SERVER_SCRIPT" | ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "cat > /tmp/rnnt-server-https.py"
ssh_cmd "mv /tmp/rnnt-server-https.py /opt/rnnt/rnnt-server-https.py"
ssh_cmd "chmod +x /opt/rnnt/rnnt-server-https.py"

echo -e "${GREEN}✅ HTTPS server script created${NC}"

# Step 5: Create HTTPS systemd service
echo -e "${GREEN}=== Step 5: Creating HTTPS Service ===${NC}"

HTTPS_SERVICE='[Unit]
Description=Production RNN-T HTTPS WebSocket Server
After=network.target
Requires=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/rnnt
Environment=PATH=/opt/rnnt/venv/bin
Environment=PYTHONPATH=/opt/rnnt
ExecStart=/opt/rnnt/rnnt-server-https.py
Restart=always
RestartSec=10
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rnnt-https
MemoryMax=6G
CPUQuota=300%

[Install]
WantedBy=multi-user.target'

# Install the HTTPS service
echo "$HTTPS_SERVICE" | ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "cat > /tmp/rnnt-https.service"
ssh_cmd "sudo mv /tmp/rnnt-https.service /etc/systemd/system/"
ssh_cmd "sudo systemctl daemon-reload"
ssh_cmd "sudo systemctl enable rnnt-https"

echo -e "${GREEN}✅ HTTPS service created${NC}"

# Step 6: Switch to HTTPS service and ensure HTTP also runs
echo -e "${GREEN}=== Step 6: Starting HTTPS Service ===${NC}"

# Stop the current WebSocket service (if running) but keep main HTTP server
echo "Stopping standalone WebSocket service..."
ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
    "sudo systemctl stop rnnt-websocket" 2>/dev/null || echo "WebSocket service not running"
ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
    "sudo systemctl disable rnnt-websocket" 2>/dev/null || echo "WebSocket service not enabled"

# Start HTTPS service
echo "Starting HTTPS service (runs on port 443)..."
ssh_cmd "sudo systemctl start rnnt-https"

# Ensure main HTTP server is also running (port 8000)
echo "Ensuring HTTP server is running on port 8000..."
HTTP_ACTIVE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
    "sudo systemctl is-active rnnt-server" 2>/dev/null || echo "inactive")

if [ "$HTTP_ACTIVE" != "active" ]; then
    echo "Starting HTTP server on port 8000..."
    ssh_cmd "sudo systemctl start rnnt-server"
    ssh_cmd "sudo systemctl enable rnnt-server"
fi

# Wait for services to initialize
echo "Waiting for services to initialize (model loading may take 30-60 seconds)..."
sleep 15

# Check HTTPS service status with detailed logging
echo "Checking HTTPS service status..."
SERVICE_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
    "sudo systemctl is-active rnnt-https" 2>/dev/null || echo "failed")

if [ "$SERVICE_STATUS" = "active" ]; then
    echo -e "${GREEN}✅ HTTPS service is running${NC}"
else
    echo -e "${YELLOW}⚠️  HTTPS service status: $SERVICE_STATUS${NC}"
    echo "Checking HTTPS service logs for troubleshooting..."
    ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
        "sudo journalctl -u rnnt-https -n 10 --no-pager" || echo "Could not retrieve logs"
    
    if [ "$SERVICE_STATUS" = "failed" ]; then
        echo -e "${RED}❌ HTTPS service failed to start${NC}"
        exit 1
    fi
fi

# Check HTTP service status
HTTP_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
    "sudo systemctl is-active rnnt-server" 2>/dev/null || echo "failed")

if [ "$HTTP_STATUS" = "active" ]; then
    echo -e "${GREEN}✅ HTTP service is running${NC}"
else
    echo -e "${YELLOW}⚠️  HTTP service status: $HTTP_STATUS${NC}"
fi

# Step 7: Test endpoints with retry logic
echo -e "${GREEN}=== Step 7: Testing HTTPS and HTTP Access ===${NC}"

# Function to test endpoint with retry logic
test_endpoint() {
    local url="$1"
    local name="$2"
    local max_attempts=3
    local attempt=1
    
    echo "Testing $name endpoint: $url"
    
    while [ $attempt -le $max_attempts ]; do
        echo "  Attempt $attempt/$max_attempts..."
        
        if [[ "$url" =~ ^https:// ]]; then
            result=$(curl -k -s --connect-timeout 10 --max-time 30 "$url/health" 2>/dev/null | jq -r '.status' 2>/dev/null || echo 'failed')
        else
            result=$(curl -s --connect-timeout 10 --max-time 30 "$url/health" 2>/dev/null | jq -r '.status' 2>/dev/null || echo 'failed')
        fi
        
        if [ "$result" = "healthy" ]; then
            echo -e "  ${GREEN}✅ $name endpoint responding${NC}"
            return 0
        elif [ "$result" = "loading" ]; then
            echo -e "  ${YELLOW}⏳ Model still loading, waiting...${NC}"
            sleep 15
        else
            echo -e "  ${YELLOW}⚠️  Attempt $attempt failed (response: $result)${NC}"
            sleep 5
        fi
        
        attempt=$((attempt + 1))
    done
    
    echo -e "  ${RED}❌ $name endpoint not responding after $max_attempts attempts${NC}"
    return 1
}

# Test HTTPS first
if test_endpoint "https://$GPU_INSTANCE_IP" "HTTPS"; then
    HTTPS_WORKING=true
else
    HTTPS_WORKING=false
fi

# Test HTTP
if test_endpoint "http://$GPU_INSTANCE_IP:8000" "HTTP"; then
    HTTP_WORKING=true
else
    HTTP_WORKING=false
fi

# Final summary and validation
echo ""
echo -e "${GREEN}🎉 HTTPS Setup Complete!${NC}"
echo "================================================================"

# Service status summary
echo -e "${BLUE}📊 Service Status Summary:${NC}"
if [ "$HTTPS_WORKING" = true ]; then
    echo -e "${GREEN}  ✅ HTTPS Service: WORKING (Port 443)${NC}"
    echo -e "${GREEN}     🔒 URL: https://$GPU_INSTANCE_IP${NC}"
    echo -e "${GREEN}     🔒 Demo: https://$GPU_INSTANCE_IP/static/index.html${NC}"
fi

if [ "$HTTP_WORKING" = true ]; then
    echo -e "${GREEN}  ✅ HTTP Service: WORKING (Port 8000)${NC}"
    echo -e "${GREEN}     🌐 URL: http://$GPU_INSTANCE_IP:8000${NC}"
    echo -e "${GREEN}     🌐 Demo: http://$GPU_INSTANCE_IP:8000/static/index.html${NC}"
fi

if [ "$HTTPS_WORKING" = false ] && [ "$HTTP_WORKING" = false ]; then
    echo -e "${RED}  ❌ Both services failed - troubleshooting required${NC}"
fi

echo ""

# Browser compatibility note
if [ "$HTTPS_WORKING" = true ]; then
    echo -e "${GREEN}🎤 Microphone Access:${NC}"
    echo -e "${GREEN}  ✅ Should work in all browsers via HTTPS${NC}"
    echo -e "${YELLOW}  ⚠️  You'll see a security warning (self-signed certificate)${NC}"
    echo -e "${YELLOW}  💡 Click 'Advanced' → 'Proceed to [IP]' to bypass${NC}"
else
    echo -e "${YELLOW}🎤 Microphone Access:${NC}"
    echo -e "${YELLOW}  ⚠️  Limited to localhost/HTTP only${NC}"
    echo -e "${YELLOW}  📱 Won't work on mobile or remote browsers${NC}"
fi

echo ""
echo -e "${BLUE}🚀 Quick Start Guide:${NC}"
if [ "$HTTPS_WORKING" = true ]; then
    echo -e "${GREEN}1. For MICROPHONE access (recommended):${NC}"
    echo "   • Open: https://$GPU_INSTANCE_IP/static/index.html"
    echo "   • Click through browser security warning"
    echo "   • Grant microphone permission"
    echo "   • Start talking to test real-time transcription"
    echo ""
fi

if [ "$HTTP_WORKING" = true ]; then
    echo -e "${BLUE}2. For FILE UPLOAD testing:${NC}"
    echo "   • Use: http://$GPU_INSTANCE_IP:8000/static/index.html"
    echo "   • Upload audio files (.wav, .mp3, .m4a)"
    echo "   • No microphone access on this URL"
    echo ""
fi

echo -e "${YELLOW}📋 API Testing:${NC}"
echo "# Health check:"
echo "curl -k https://$GPU_INSTANCE_IP/health"
echo ""
echo "# File transcription:"
echo "curl -k -X POST https://$GPU_INSTANCE_IP/transcribe/file \\"
echo "  -F 'file=@your-audio.wav' -F 'language=en'"
echo ""

# Troubleshooting section
if [ "$HTTPS_WORKING" = false ] || [ "$HTTP_WORKING" = false ]; then
    echo -e "${RED}🔧 Troubleshooting:${NC}"
    echo ""
    echo "If services aren't responding:"
    echo "• Check service logs: ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP 'sudo journalctl -u rnnt-https -f'"
    echo "• Restart services: ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP 'sudo systemctl restart rnnt-https rnnt-server'"
    echo "• Check GPU memory: ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP 'nvidia-smi'"
    echo ""
    echo "Common issues:"
    echo "• Model loading can take 30-60 seconds on first start"
    echo "• GPU out of memory - restart services to reload model"
    echo "• Network issues - check security group has ports 443 and 8000 open"
    echo ""
fi

echo -e "${BLUE}📝 Production Notes:${NC}"
echo "• Self-signed certificates show security warnings"
echo "• For production, use Let's Encrypt: certbot --nginx"
echo "• Monitor with: sudo systemctl status rnnt-https rnnt-server"
echo "• Logs location: sudo journalctl -u rnnt-https -u rnnt-server"

# Update .env with HTTPS status
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sed -i "s/HTTPS_ENABLED=\".*\"/HTTPS_ENABLED=\"$HTTPS_WORKING\"/" "$ENV_FILE" 2>/dev/null || \
    echo "HTTPS_ENABLED=\"$HTTPS_WORKING\"" >> "$ENV_FILE"
sed -i "s/HTTPS_SETUP_TIME=\".*\"/HTTPS_SETUP_TIME=\"$TIMESTAMP\"/" "$ENV_FILE" 2>/dev/null || \
    echo "HTTPS_SETUP_TIME=\"$TIMESTAMP\"" >> "$ENV_FILE"