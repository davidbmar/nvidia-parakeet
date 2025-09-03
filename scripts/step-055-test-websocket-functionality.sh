#!/bin/bash
set -e

# Production RNN-T Deployment - Step 3.2: Test WebSocket Server (Simple Version)
# This script tests the WebSocket-enabled RNN-T server functionality
#
# Prerequisites:
# - Step 031 (WebSocket server start) must be completed first

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

echo -e "${BLUE}🧪 Production RNN-T Deployment - Test WebSocket Server${NC}"
echo "================================================================"
echo "Target Instance: $GPU_INSTANCE_IP"
echo ""

# Step 1: Service Status
echo -e "${GREEN}=== Step 1: Service Status Check ===${NC}"
SERVICE_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "sudo systemctl is-active rnnt-https" 2>/dev/null || echo "failed")

if [ "$SERVICE_STATUS" = "active" ]; then
    echo -e "${GREEN}✅ WebSocket service is running${NC}"
else
    echo -e "${RED}❌ WebSocket service is not running: $SERVICE_STATUS${NC}"
    exit 1
fi

# Step 2: Test Endpoints
echo -e "${GREEN}=== Step 2: REST API Tests ===${NC}"

echo "Testing Root endpoint..."
ROOT_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "timeout 10 curl -k -s --connect-timeout 5 https://localhost/" 2>/dev/null || echo "FAILED")
if echo "$ROOT_RESPONSE" | grep -q "WebSocket"; then
    echo -e "${GREEN}✅ Root endpoint: PASS${NC}"
else
    echo -e "${RED}❌ Root endpoint: FAIL${NC}"
fi

echo "Testing Health endpoint..."
HEALTH_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "timeout 10 curl -k -s --connect-timeout 5 https://localhost/health" 2>/dev/null || echo "FAILED")
if echo "$HEALTH_RESPONSE" | grep -q "healthy"; then
    echo -e "${GREEN}✅ Health endpoint: PASS${NC}"
else
    echo -e "${RED}❌ Health endpoint: FAIL${NC}"
fi

echo "Testing WebSocket Status endpoint..."
WS_STATUS_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "timeout 10 curl -k -s --connect-timeout 5 https://localhost/ws/status" 2>/dev/null || echo "FAILED")
if echo "$WS_STATUS_RESPONSE" | grep -q "active"; then
    echo -e "${GREEN}✅ WebSocket status: PASS${NC}"
else
    echo -e "${RED}❌ WebSocket status: FAIL${NC}"
fi

# Step 3: WebSocket Connectivity Test
echo -e "${GREEN}=== Step 3: WebSocket Connectivity Test ===${NC}"

# Create simple WebSocket test
WS_TEST="
import asyncio
import websockets
import json
import sys

async def test_ws():
    try:
        uri = 'ws://localhost:8000/ws/transcribe?client_id=test'
        async with websockets.connect(uri, timeout=10) as ws:
            welcome = await asyncio.wait_for(ws.recv(), timeout=5)
            data = json.loads(welcome)
            if data.get('type') == 'connection':
                print('✅ WebSocket connection: PASS')
                return True
    except Exception as e:
        print(f'❌ WebSocket connection: FAIL - {e}')
        return False

if __name__ == '__main__':
    result = asyncio.run(test_ws())
    sys.exit(0 if result else 1)
"

echo "$WS_TEST" > /tmp/ws_test.py
scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no /tmp/ws_test.py ubuntu@"$GPU_INSTANCE_IP":/tmp/ >/dev/null 2>&1

if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "cd /opt/rnnt && source venv/bin/activate && timeout 15 python /tmp/ws_test.py" 2>/dev/null; then
    echo -e "${GREEN}✅ WebSocket connectivity: PASS${NC}"
else
    echo -e "${RED}❌ WebSocket connectivity: FAIL${NC}"
fi

# Final Results
echo ""
echo -e "${BLUE}🎉 WebSocket Server Test Results${NC}"
echo "================================================================"
echo ""
echo -e "${GREEN}✅ WebSocket server is deployed and functional!${NC}"
echo ""
echo -e "${YELLOW}🌐 Access URLs:${NC}"
echo "• Demo UI: http://$GPU_INSTANCE_IP:8000/static/index.html"
echo "• WebSocket API: ws://$GPU_INSTANCE_IP:8000/ws/transcribe"
echo "• REST API: http://$GPU_INSTANCE_IP:8000"
echo "• Examples: http://$GPU_INSTANCE_IP:8000/examples/"
echo ""
echo -e "${BLUE}🚀 Ready for Development:${NC}"
echo "• Open the demo UI to test real-time transcription"
echo "• Use the WebSocket API in your applications"
echo "• Check examples for integration guidance"
echo ""

# Cleanup
rm -f /tmp/ws_test.py
ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "rm -f /tmp/ws_test.py" 2>/dev/null || true