#!/bin/bash
set -e

# Production RNN-T Deployment - Step 2: Install RNN-T Server
# This script installs and configures the RNN-T transcription server

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
    echo "Run: ./scripts/step-000-setup-configuration.sh first"
    exit 1
fi

source "$ENV_FILE"

# Validate required variables
required_vars=("GPU_INSTANCE_IP" "SSH_KEY_FILE" "GPU_INSTANCE_ID")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}❌ Required variable $var not set${NC}"
        echo "Run: ./scripts/step-010-deploy-gpu-instance.sh first"
        exit 1
    fi
done

echo -e "${BLUE}🚀 Production RNN-T Deployment - Server Installation${NC}"
echo "================================================================"
echo "Target Instance: $GPU_INSTANCE_IP ($GPU_INSTANCE_ID)"
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
    local local_path="$1"
    local remote_path="$2"
    echo -e "${BLUE}📁 Copying: $local_path → $remote_path${NC}"
    if ! scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "$local_path" ubuntu@"$GPU_INSTANCE_IP":"$remote_path"; then
        echo -e "${RED}❌ File copy failed: $local_path${NC}"
        exit 1
    fi
}

# Test SSH connection
echo -e "${GREEN}=== Step 1: Testing SSH Connection ===${NC}"
if ! ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        ubuntu@"$GPU_INSTANCE_IP" "echo 'SSH connection successful'" >/dev/null 2>&1; then
    echo -e "${RED}❌ SSH connection failed${NC}"
    echo "Check that the instance is running and accessible"
    exit 1
fi
echo -e "${GREEN}✅ SSH connection confirmed${NC}"

# Step 2: System Update and Dependencies
echo -e "${GREEN}=== Step 2: Installing System Dependencies ===${NC}"
ssh_cmd "sudo apt-get update && sudo apt-get upgrade -y"
ssh_cmd "sudo apt-get install -y python3-pip python3-venv python3-dev build-essential"
ssh_cmd "sudo apt-get install -y ffmpeg libsndfile1 git curl wget"

# Install AWS CLI if not present
ssh_cmd "which aws || (curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install)"

# Step 3: NVIDIA Driver Setup (if needed)
echo -e "${GREEN}=== Step 3: NVIDIA Driver Setup ===${NC}"
NVIDIA_CHECK=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "nvidia-smi || echo 'not-found'" 2>/dev/null)
if [[ "$NVIDIA_CHECK" == *"not-found"* ]]; then
    echo "Installing NVIDIA drivers..."
    ssh_cmd "sudo apt-get install -y ubuntu-drivers-common"
    ssh_cmd "sudo ubuntu-drivers autoinstall"
    echo -e "${YELLOW}⚠️  NVIDIA drivers installed, reboot may be required${NC}"
else
    echo -e "${GREEN}✅ NVIDIA drivers already installed${NC}"
fi

# Step 4: Create Application Directory
echo -e "${GREEN}=== Step 4: Setting Up Application Directory ===${NC}"
ssh_cmd "sudo mkdir -p /opt/rnnt"
ssh_cmd "sudo chown ubuntu:ubuntu /opt/rnnt"
ssh_cmd "mkdir -p /opt/rnnt/{logs,models,temp}"

# Step 5: Copy Server Code
echo -e "${GREEN}=== Step 5: Copying Server Code ===${NC}"
copy_to_instance "$PROJECT_ROOT/docker/rnnt-server.py" "/opt/rnnt/rnnt-server.py"
copy_to_instance "$PROJECT_ROOT/config/requirements.txt" "/opt/rnnt/requirements.txt"

# Copy environment configuration
copy_to_instance "$ENV_FILE" "/opt/rnnt/.env"

# Step 6: Python Environment Setup
echo -e "${GREEN}=== Step 6: Setting Up Python Environment ===${NC}"
ssh_cmd "cd /opt/rnnt && python3 -m venv venv"
ssh_cmd "cd /opt/rnnt && source venv/bin/activate && pip install --upgrade pip wheel setuptools"

# Install PyTorch with CUDA support first
echo "Installing PyTorch with CUDA support..."
ssh_cmd "cd /opt/rnnt && source venv/bin/activate && pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu118"

# Install other requirements
echo "Installing other dependencies..."
ssh_cmd "cd /opt/rnnt && source venv/bin/activate && pip install -r requirements.txt"

# Step 7: Create Systemd Service
echo -e "${GREEN}=== Step 7: Creating Systemd Service ===${NC}"

# Create service file content
SERVICE_FILE_CONTENT="[Unit]
Description=Production RNN-T Transcription Server
After=network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/rnnt
Environment=PATH=/opt/rnnt/venv/bin
ExecStart=/opt/rnnt/venv/bin/python rnnt-server.py
EnvironmentFile=/opt/rnnt/.env
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=rnnt-server

[Install]
WantedBy=multi-user.target"

# Copy service file to instance
echo "$SERVICE_FILE_CONTENT" > /tmp/rnnt-server.service
copy_to_instance "/tmp/rnnt-server.service" "/tmp/rnnt-server.service"

# Install and enable service
ssh_cmd "sudo mv /tmp/rnnt-server.service /etc/systemd/system/"
ssh_cmd "sudo systemctl daemon-reload"
ssh_cmd "sudo systemctl enable rnnt-server"

# Step 8: Download and Cache Model
echo -e "${GREEN}=== Step 8: Downloading RNN-T Model ===${NC}"
echo -e "${YELLOW}⏳ This may take several minutes (downloading ~1.5GB model)...${NC}"

# Create model download script
MODEL_DOWNLOAD_SCRIPT="
import warnings
warnings.filterwarnings('ignore')

import os
import torch
from speechbrain.inference import EncoderDecoderASR

print('🔥 Downloading SpeechBrain Conformer RNN-T model...')
try:
    model = EncoderDecoderASR.from_hparams(
        source='speechbrain/asr-conformer-transformerlm-librispeech',
        savedir='/opt/rnnt/models/asr-conformer-transformerlm-librispeech',
        run_opts={'device': 'cuda' if torch.cuda.is_available() else 'cpu'}
    )
    print('✅ Model download completed successfully')
    print(f'💾 Model cached in: /opt/rnnt/models/')
    print(f'🎮 Device: {\"cuda\" if torch.cuda.is_available() else \"cpu\"}')
except Exception as e:
    print(f'❌ Model download failed: {e}')
    exit(1)
"

echo "$MODEL_DOWNLOAD_SCRIPT" > /tmp/download_model.py
copy_to_instance "/tmp/download_model.py" "/opt/rnnt/download_model.py"

# Run model download
ssh_cmd "cd /opt/rnnt && source venv/bin/activate && python download_model.py"

# Step 9: Start the Service
echo -e "${GREEN}=== Step 9: Starting RNN-T Server ===${NC}"
ssh_cmd "sudo systemctl start rnnt-server"

# Wait for service to start
echo -e "${YELLOW}⏳ Waiting for server to initialize...${NC}"
sleep 10

# Check service status
SERVICE_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "sudo systemctl is-active rnnt-server" 2>/dev/null || echo "failed")

if [ "$SERVICE_STATUS" = "active" ]; then
    echo -e "${GREEN}✅ RNN-T server is running${NC}"
else
    echo -e "${RED}❌ RNN-T server failed to start${NC}"
    echo "Checking logs..."
    ssh_cmd "sudo journalctl -u rnnt-server --no-pager -n 20"
    exit 1
fi

# Step 10: Health Check
echo -e "${GREEN}=== Step 10: Health Check ===${NC}"
echo -e "${YELLOW}⏳ Testing server endpoints...${NC}"

# Wait a bit more for full initialization
sleep 15

# Test root endpoint
echo "Testing root endpoint..."
ROOT_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s http://localhost:8000/ || echo 'failed'")

if [[ "$ROOT_RESPONSE" == *"Production RNN-T"* ]]; then
    echo -e "${GREEN}✅ Root endpoint responding${NC}"
else
    echo -e "${RED}❌ Root endpoint not responding${NC}"
    echo "Response: $ROOT_RESPONSE"
fi

# Test health endpoint
echo "Testing health endpoint..."
HEALTH_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s http://localhost:8000/health || echo 'failed'")

if [[ "$HEALTH_RESPONSE" == *"healthy"* ]] || [[ "$HEALTH_RESPONSE" == *"loading"* ]]; then
    echo -e "${GREEN}✅ Health endpoint responding${NC}"
else
    echo -e "${YELLOW}⚠️  Health endpoint may still be initializing${NC}"
fi

# Step 11: Create Helper Scripts
echo -e "${GREEN}=== Step 11: Creating Helper Scripts ===${NC}"

# Create server management script
MANAGEMENT_SCRIPT='#!/bin/bash
case "$1" in
    start)
        sudo systemctl start rnnt-server
        echo "RNN-T server started"
        ;;
    stop)
        sudo systemctl stop rnnt-server
        echo "RNN-T server stopped"
        ;;
    restart)
        sudo systemctl restart rnnt-server
        echo "RNN-T server restarted"
        ;;
    status)
        sudo systemctl status rnnt-server
        ;;
    logs)
        sudo journalctl -u rnnt-server -f
        ;;
    health)
        curl -s http://localhost:8000/health | python3 -m json.tool
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|health}"
        exit 1
        ;;
esac'

echo "$MANAGEMENT_SCRIPT" > /tmp/rnnt-server-ctl.sh
copy_to_instance "/tmp/rnnt-server-ctl.sh" "/opt/rnnt/rnnt-server-ctl.sh"
ssh_cmd "chmod +x /opt/rnnt/rnnt-server-ctl.sh"

# Final summary
echo ""
echo -e "${GREEN}🎉 RNN-T Server Installation Complete!${NC}"
echo "================================================================"
echo "Server Status: $(echo $SERVICE_STATUS | tr '[:lower:]' '[:upper:]')"
echo "Server URL: http://$GPU_INSTANCE_IP:8000"
echo "Health Check: http://$GPU_INSTANCE_IP:8000/health"
echo ""
echo -e "${BLUE}🔧 Server Management Commands (on instance):${NC}"
echo "   ./rnnt-server-ctl.sh {start|stop|restart|status|logs|health}"
echo ""
echo -e "${BLUE}🌐 API Endpoints:${NC}"
echo "   GET  http://$GPU_INSTANCE_IP:8000/          - Service info"
echo "   GET  http://$GPU_INSTANCE_IP:8000/health    - Health check"
echo "   POST http://$GPU_INSTANCE_IP:8000/transcribe/file - File transcription"
echo ""
echo -e "${BLUE}📋 Quick Test Commands:${NC}"
echo "   curl http://$GPU_INSTANCE_IP:8000/"
echo "   curl http://$GPU_INSTANCE_IP:8000/health"
echo ""
echo -e "${YELLOW}📜 Next Steps:${NC}"
echo "1. Run: ./scripts/step-030-test-system.sh"
echo "2. Upload audio files to test transcription"
echo ""

# Update environment with completion timestamp
COMPLETION_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sed -i "s/SERVER_INSTALLED=\".*\"/SERVER_INSTALLED=\"$COMPLETION_TIME\"/" "$ENV_FILE"

# Clean up temporary files
rm -f /tmp/rnnt-server.service /tmp/download_model.py /tmp/rnnt-server-ctl.sh