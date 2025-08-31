#!/bin/bash
set -e

# Production RNN-T Deployment - Step 2.7: Enable HTTPS
# This script adds HTTPS support to the WebSocket server using self-signed certificates

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

# Function to run SSH commands
ssh_cmd() {
    local cmd="$*"
    echo -e "${BLUE}🔧 SSH: $cmd${NC}"
    if ! ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "$cmd"; then
        echo -e "${RED}❌ SSH command failed: $cmd${NC}"
        exit 1
    fi
}

# Step 1: Generate SSL Certificate
echo -e "${GREEN}=== Step 1: Generating SSL Certificate ===${NC}"

# Create SSL certificate on the instance
ssh_cmd "sudo mkdir -p /opt/rnnt/ssl"
ssh_cmd "cd /opt/rnnt/ssl && sudo openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt -days 365 -nodes -subj '/C=US/ST=State/L=City/O=Organization/CN=$GPU_INSTANCE_IP'"
ssh_cmd "sudo chown -R ubuntu:ubuntu /opt/rnnt/ssl"

echo -e "${GREEN}✅ SSL certificate generated${NC}"

# Step 2: Update Security Group for HTTPS
echo -e "${GREEN}=== Step 2: Opening HTTPS Port (443) ===${NC}"

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

# Step 3: Create HTTPS-enabled WebSocket Server
echo -e "${GREEN}=== Step 3: Creating HTTPS WebSocket Server ===${NC}"

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

# Step 4: Create HTTPS systemd service
echo -e "${GREEN}=== Step 4: Creating HTTPS Service ===${NC}"

HTTPS_SERVICE='[Unit]
Description=Production RNN-T HTTPS WebSocket Server
After=network.target
Requires=network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
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

# Step 5: Switch to HTTPS service
echo -e "${GREEN}=== Step 5: Starting HTTPS Service ===${NC}"

# Stop the current WebSocket service
ssh_cmd "sudo systemctl stop rnnt-websocket"
ssh_cmd "sudo systemctl disable rnnt-websocket"

# Start HTTPS service
ssh_cmd "sudo systemctl start rnnt-https"

# Wait for service to start
echo "Waiting for HTTPS service to initialize..."
sleep 10

# Check status
SERVICE_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
    "sudo systemctl is-active rnnt-https" 2>/dev/null || echo "failed")

if [ "$SERVICE_STATUS" = "active" ]; then
    echo -e "${GREEN}✅ HTTPS service is running${NC}"
else
    echo -e "${YELLOW}⚠️  HTTPS service status: $SERVICE_STATUS${NC}"
    echo "Checking if HTTP fallback is working..."
    
    # Test HTTP fallback
    HTTP_TEST=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
        "curl -s --connect-timeout 5 http://localhost:8000/health | jq -r '.status' 2>/dev/null || echo 'failed'")
    
    if [ "$HTTP_TEST" = "healthy" ]; then
        echo -e "${GREEN}✅ HTTP fallback is working${NC}"
    else
        echo -e "${RED}❌ Both HTTPS and HTTP failed${NC}"
        exit 1
    fi
fi

# Step 6: Test HTTPS endpoint
echo -e "${GREEN}=== Step 6: Testing HTTPS Access ===${NC}"

# Test HTTPS (may fail due to self-signed cert)
echo "Testing HTTPS endpoint..."
HTTPS_TEST=$(curl -k -s --connect-timeout 5 https://"$GPU_INSTANCE_IP"/health 2>/dev/null | jq -r '.status' 2>/dev/null || echo 'failed')

if [ "$HTTPS_TEST" = "healthy" ]; then
    echo -e "${GREEN}✅ HTTPS endpoint responding${NC}"
    HTTPS_WORKING=true
else
    echo -e "${YELLOW}⚠️  HTTPS test failed, checking HTTP...${NC}"
    HTTPS_WORKING=false
fi

# Test HTTP as backup
HTTP_TEST=$(curl -s --connect-timeout 5 http://"$GPU_INSTANCE_IP":8000/health 2>/dev/null | jq -r '.status' 2>/dev/null || echo 'failed')

if [ "$HTTP_TEST" = "healthy" ]; then
    echo -e "${GREEN}✅ HTTP endpoint responding${NC}"
    HTTP_WORKING=true
else
    echo -e "${RED}❌ HTTP endpoint not responding${NC}"
    HTTP_WORKING=false
fi

# Final summary
echo ""
echo -e "${GREEN}🎉 HTTPS Setup Complete!${NC}"
echo "================================================================"

if [ "$HTTPS_WORKING" = true ]; then
    echo -e "${GREEN}🔒 HTTPS URL: https://$GPU_INSTANCE_IP${NC}"
    echo -e "${GREEN}🔒 Demo UI: https://$GPU_INSTANCE_IP/static/index.html${NC}"
    echo "   (You'll get a security warning - click 'Advanced' → 'Proceed')"
fi

if [ "$HTTP_WORKING" = true ]; then
    echo -e "${BLUE}🌐 HTTP URL: http://$GPU_INSTANCE_IP:8000${NC}"
    echo -e "${BLUE}🌐 Demo UI: http://$GPU_INSTANCE_IP:8000/static/index.html${NC}"
fi

echo ""
echo -e "${YELLOW}📝 Important Notes:${NC}"
echo "• Self-signed certificate will show browser warnings"
echo "• Click 'Advanced' → 'Proceed to site' to bypass warnings"
echo "• For production, use Let's Encrypt or a real SSL certificate"
echo ""

if [ "$HTTPS_WORKING" = true ]; then
    echo -e "${GREEN}✅ Microphone access should now work in browsers!${NC}"
else
    echo -e "${YELLOW}⚠️  HTTPS not working, microphone access still limited to localhost${NC}"
fi

echo ""
echo -e "${YELLOW}📜 Next Steps:${NC}"
echo "1. Open: https://$GPU_INSTANCE_IP/static/index.html"
echo "2. Accept the security warning (self-signed certificate)"
echo "3. Grant microphone permission when prompted"
echo "4. Test real-time transcription!"

# Update .env with HTTPS status
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sed -i "s/HTTPS_ENABLED=\".*\"/HTTPS_ENABLED=\"$HTTPS_WORKING\"/" "$ENV_FILE" 2>/dev/null || \
    echo "HTTPS_ENABLED=\"$HTTPS_WORKING\"" >> "$ENV_FILE"
sed -i "s/HTTPS_SETUP_TIME=\".*\"/HTTPS_SETUP_TIME=\"$TIMESTAMP\"/" "$ENV_FILE" 2>/dev/null || \
    echo "HTTPS_SETUP_TIME=\"$TIMESTAMP\"" >> "$ENV_FILE"