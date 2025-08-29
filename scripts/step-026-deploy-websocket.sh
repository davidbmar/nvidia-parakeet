#!/bin/bash
set -e

# Production RNN-T Deployment - Step 2.6: Deploy WebSocket Streaming
# This script deploys the WebSocket-enabled RNN-T server with real-time streaming
#
# Prerequisites:
# - Step 020 (basic RNN-T server) must be completed first
# - Step 025 (Docker deployment) should be completed
# - GPU instance must be running with RNN-T model cached
#
# What this script does:
# 1. Copies WebSocket components to GPU instance
# 2. Installs WebSocket dependencies  
# 3. Creates WebSocket-enabled service
# 4. Deploys web interface and examples

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Setup logging
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/step-026-deploy-websocket-$(date +%Y%m%d-%H%M%S).log"
STEP_NAME="Step 026: Deploy WebSocket Components"

# Logging function
log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Start logging
log_message "INFO" "=== $STEP_NAME Started ==="
log_message "INFO" "Log file: $LOG_FILE"
log_message "INFO" "Target Instance: $GPU_INSTANCE_IP"
log_message "INFO" "SSH Key: $SSH_KEY_FILE"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Run: ./scripts/step-000-setup-configuration.sh first"
    exit 1
fi

source "$ENV_FILE"

# Validate required variables
required_vars=("GPU_INSTANCE_IP" "SSH_KEY_FILE")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}❌ Required variable $var not set${NC}"
        echo "Run previous setup scripts first"
        exit 1
    fi
done

echo -e "${BLUE}🚀 Production RNN-T Deployment - WebSocket Streaming${NC}"
echo "================================================================"
echo "Target Instance: $GPU_INSTANCE_IP"
echo "SSH Key: $SSH_KEY_FILE"
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

# Function to copy files to instance
copy_to_instance() {
    local src="$1"
    local dest="$2"
    echo -e "${BLUE}📁 Copying: $src → $dest${NC}"
    if ! scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "$src" ubuntu@"$GPU_INSTANCE_IP":"$dest"; then
        echo -e "${RED}❌ File copy failed: $src${NC}"
        exit 1
    fi
}

# Function to copy directories to instance
copy_dir_to_instance() {
    local src="$1"
    local dest="$2"
    echo -e "${BLUE}📁 Copying directory: $src → $dest${NC}"
    if ! scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -r "$src" ubuntu@"$GPU_INSTANCE_IP":"$dest"; then
        echo -e "${RED}❌ Directory copy failed: $src${NC}"
        exit 1
    fi
}

# Step 1: Test SSH Connection
echo -e "${GREEN}=== Step 1: Testing SSH Connection ===${NC}"
if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$GPU_INSTANCE_IP" "echo 'Connection test'" >/dev/null 2>&1; then
    echo -e "${GREEN}✅ SSH connection confirmed${NC}"
else
    echo -e "${RED}❌ Cannot connect to GPU instance${NC}"
    echo "Check instance status and security groups"
    exit 1
fi

# Step 2: Verify Base RNN-T Server
echo -e "${GREEN}=== Step 2: Verifying Base RNN-T Installation ===${NC}"
if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "[ -f '/opt/rnnt/rnnt-server.py' ]" 2>/dev/null; then
    echo -e "${GREEN}✅ Base RNN-T server found${NC}"
else
    echo -e "${RED}❌ Base RNN-T server not found${NC}"
    echo "Run: ./scripts/step-020-install-rnnt-server.sh first"
    exit 1
fi

# Step 3: Copy WebSocket Components
echo -e "${GREEN}=== Step 3: Copying WebSocket Components ===${NC}"

# Copy WebSocket server
copy_to_instance "$PROJECT_ROOT/docker/rnnt-server-websocket.py" "/opt/rnnt/rnnt-server-websocket.py"

# Copy WebSocket modules
copy_dir_to_instance "$PROJECT_ROOT/websocket" "/opt/rnnt/"

# Copy static files (web interface)
copy_dir_to_instance "$PROJECT_ROOT/static" "/opt/rnnt/"

# Copy examples
copy_dir_to_instance "$PROJECT_ROOT/examples" "/opt/rnnt/"

# Step 4: Install WebSocket Dependencies
echo -e "${GREEN}=== Step 4: Installing WebSocket Dependencies ===${NC}"
ssh_cmd "cd /opt/rnnt && source venv/bin/activate && pip install websockets"

# Step 5: Fix Import Issues
echo -e "${GREEN}=== Step 5: Configuring WebSocket Server ===${NC}"

# Create symbolic link for import compatibility
ssh_cmd "cd /opt/rnnt && ln -sf rnnt-server.py rnnt_server.py"

# Verify WebSocket server can import correctly
echo -e "${YELLOW}⏳ Testing WebSocket server imports...${NC}"
if ssh_cmd "cd /opt/rnnt && source venv/bin/activate && python -c 'import websocket.websocket_handler; print(\"✅ WebSocket imports OK\")'"; then
    echo -e "${GREEN}✅ WebSocket components verified${NC}"
else
    echo -e "${RED}❌ WebSocket component issues detected${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}🎉 WebSocket Components Deployed Successfully!${NC}"
echo "================================================================"
echo "✅ WebSocket server: /opt/rnnt/rnnt-server-websocket.py"
echo "✅ WebSocket modules: /opt/rnnt/websocket/"
echo "✅ Web interface: /opt/rnnt/static/"
echo "✅ Examples: /opt/rnnt/examples/"
echo ""
echo -e "${YELLOW}📜 Next Steps:${NC}"
echo "1. Run: ./scripts/step-031-start-websocket-server.sh"
echo "   → This will create a systemd service and start the WebSocket server"
echo "   → The server will provide real-time audio streaming and transcription"
echo "2. After that: ./scripts/step-032-test-websocket.sh"
echo "   → This will test all WebSocket functionality and endpoints"
echo "3. Then open: http://$GPU_INSTANCE_IP:8000/static/index.html"
echo "   → This will show the web demo interface for testing"
echo ""

# Auto-run next script function
read -p "Would you like to automatically run step-031-start-websocket-server.sh now? (y/N): " -r
if [[ \$REPLY =~ ^[Yy]\$ ]]; then
    echo -e "${BLUE}🚀 Running next script automatically...${NC}"
    exec "\$SCRIPT_DIR/step-031-start-websocket-server.sh"
fi