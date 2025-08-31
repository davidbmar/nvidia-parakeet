#!/bin/bash
set -e

# Production RNN-T Deployment - Step 2.5: Deploy RNN-T Docker Container
# This script builds and deploys the RNN-T container on the GPU instance

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

echo -e "${BLUE}🚀 Production RNN-T Deployment - Docker Container Deployment${NC}"
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

# Function to copy directory to instance
copy_dir_to_instance() {
    local local_path="$1"
    local remote_path="$2"
    echo -e "${BLUE}📁 Copying directory: $local_path → $remote_path${NC}"
    if ! scp -r -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "$local_path" ubuntu@"$GPU_INSTANCE_IP":"$remote_path"; then
        echo -e "${RED}❌ Directory copy failed: $local_path${NC}"
        exit 1
    fi
}

# Test SSH connection
echo -e "${GREEN}=== Step 1: Testing SSH Connection ===${NC}"
if ! ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        ubuntu@"$GPU_INSTANCE_IP" "echo 'SSH connection successful'" >/dev/null 2>&1; then
    echo -e "${RED}❌ SSH connection failed${NC}"
    exit 1
fi
echo -e "${GREEN}✅ SSH connection confirmed${NC}"

# Step 2: Install Docker and NVIDIA Container Toolkit
echo -e "${GREEN}=== Step 2: Installing Docker & NVIDIA Container Toolkit ===${NC}"

# Install Docker if not present
ssh_cmd "which docker || (curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh && sudo usermod -aG docker ubuntu)"

# Install NVIDIA Container Toolkit
ssh_cmd "which nvidia-container-runtime || (
    distribution=\$(. /etc/os-release; echo \$ID\$VERSION_ID) &&
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg &&
    curl -s -L https://nvidia.github.io/libnvidia-container/\$distribution/libnvidia-container.list | \\
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \\
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list &&
    sudo apt-get update &&
    sudo apt-get install -y nvidia-container-toolkit &&
    sudo nvidia-ctk runtime configure --runtime=docker &&
    sudo systemctl restart docker
)"

# Step 3: Verify GPU access in Docker
echo -e "${GREEN}=== Step 3: Verifying GPU Access ===${NC}"
ssh_cmd "docker run --rm --gpus all nvidia/cuda:12.1-runtime-ubuntu22.04 nvidia-smi"

# Step 4: Create application directory
echo -e "${GREEN}=== Step 4: Setting Up Application Directory ===${NC}"
ssh_cmd "mkdir -p ~/rnnt-deploy && cd ~/rnnt-deploy && mkdir -p logs"

# Step 5: Copy project files
echo -e "${GREEN}=== Step 5: Copying Project Files ===${NC}"
copy_to_instance "$PROJECT_ROOT/docker/Dockerfile" "~/rnnt-deploy/Dockerfile"
copy_to_instance "$PROJECT_ROOT/docker/rnnt-server.py" "~/rnnt-deploy/rnnt-server.py"
copy_to_instance "$PROJECT_ROOT/config/requirements.txt" "~/rnnt-deploy/requirements.txt"
copy_to_instance "$ENV_FILE" "~/rnnt-deploy/.env"

# Create config directory on remote
ssh_cmd "mkdir -p ~/rnnt-deploy/config ~/rnnt-deploy/docker"
copy_to_instance "$PROJECT_ROOT/config/requirements.txt" "~/rnnt-deploy/config/requirements.txt"
copy_to_instance "$PROJECT_ROOT/docker/rnnt-server.py" "~/rnnt-deploy/docker/rnnt-server.py"

# Step 6: Build Docker image
echo -e "${GREEN}=== Step 6: Building Docker Image ===${NC}"
echo -e "${YELLOW}⏳ This may take 10-15 minutes (downloading CUDA base image and dependencies)...${NC}"

ssh_cmd "cd ~/rnnt-deploy && docker build -t rnnt-server:latest ."

# Step 7: Stop any existing containers
echo -e "${GREEN}=== Step 7: Stopping Existing Containers ===${NC}"
ssh_cmd "docker stop rnnt-server 2>/dev/null || true && docker rm rnnt-server 2>/dev/null || true"

# Step 8: Run the container
echo -e "${GREEN}=== Step 8: Starting RNN-T Container ===${NC}"
ssh_cmd "cd ~/rnnt-deploy && docker run -d \\
    --name rnnt-server \\
    --gpus all \\
    --restart unless-stopped \\
    -p 8000:8000 \\
    -v \$(pwd)/logs:/app/logs \\
    -v /tmp/speechbrain_cache:/tmp/speechbrain_cache \\
    --env-file .env \\
    rnnt-server:latest"

# Step 9: Wait for initialization
echo -e "${YELLOW}⏳ Waiting for server to initialize (this may take 2-3 minutes)...${NC}"
sleep 30

# Check container status
CONTAINER_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "docker ps --format 'table {{.Names}}\t{{.Status}}' | grep rnnt-server || echo 'not running'")
echo "Container Status: $CONTAINER_STATUS"

if [[ "$CONTAINER_STATUS" == *"not running"* ]]; then
    echo -e "${RED}❌ Container failed to start${NC}"
    echo "Checking container logs..."
    ssh_cmd "docker logs rnnt-server"
    exit 1
fi

# Step 10: Health check
echo -e "${GREEN}=== Step 10: Health Check ===${NC}"
echo -e "${YELLOW}⏳ Testing server endpoints...${NC}"

# Wait for model loading
sleep 60

# Test health endpoint
echo "Testing health endpoint..."
for i in {1..6}; do
    HEALTH_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s --connect-timeout 10 http://localhost:8000/health || echo 'failed'")
    
    if [[ "$HEALTH_RESPONSE" == *"healthy"* ]]; then
        echo -e "${GREEN}✅ Health check passed${NC}"
        break
    elif [[ "$HEALTH_RESPONSE" == *"loading"* ]]; then
        echo -e "${YELLOW}⏳ Model still loading... (attempt $i/6)${NC}"
        sleep 30
    else
        echo -e "${YELLOW}⚠️  Health check attempt $i/6 failed, retrying...${NC}"
        sleep 30
    fi
    
    if [ $i -eq 6 ]; then
        echo -e "${RED}❌ Health check failed after 6 attempts${NC}"
        echo "Response: $HEALTH_RESPONSE"
        echo "Checking container logs..."
        ssh_cmd "docker logs --tail 50 rnnt-server"
    fi
done

# Step 11: Create management script
echo -e "${GREEN}=== Step 11: Creating Management Script ===${NC}"

MANAGEMENT_SCRIPT='#!/bin/bash
case "$1" in
    start)
        docker start rnnt-server
        echo "RNN-T container started"
        ;;
    stop)
        docker stop rnnt-server
        echo "RNN-T container stopped"
        ;;
    restart)
        docker restart rnnt-server
        echo "RNN-T container restarted"
        ;;
    status)
        docker ps --filter name=rnnt-server
        ;;
    logs)
        docker logs -f rnnt-server
        ;;
    health)
        curl -s http://localhost:8000/health | python3 -m json.tool
        ;;
    rebuild)
        docker stop rnnt-server 2>/dev/null || true
        docker rm rnnt-server 2>/dev/null || true
        docker build -t rnnt-server:latest .
        docker run -d --name rnnt-server --gpus all --restart unless-stopped -p 8000:8000 -v $(pwd)/logs:/app/logs -v /tmp/speechbrain_cache:/tmp/speechbrain_cache --env-file .env rnnt-server:latest
        echo "RNN-T container rebuilt and started"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|health|rebuild}"
        exit 1
        ;;
esac'

echo "$MANAGEMENT_SCRIPT" > /tmp/rnnt-ctl.sh
copy_to_instance "/tmp/rnnt-ctl.sh" "~/rnnt-deploy/rnnt-ctl.sh"
ssh_cmd "chmod +x ~/rnnt-deploy/rnnt-ctl.sh"

# Final summary
echo ""
echo -e "${GREEN}🎉 RNN-T Docker Container Deployment Complete!${NC}"
echo "================================================================"
echo "Container Status: $CONTAINER_STATUS"
echo "Server URL: http://$GPU_INSTANCE_IP:8000"
echo "Health Check: http://$GPU_INSTANCE_IP:8000/health"
echo ""
echo -e "${BLUE}🔧 Container Management Commands (on instance):${NC}"
echo "   cd ~/rnnt-deploy && ./rnnt-ctl.sh {start|stop|restart|status|logs|health|rebuild}"
echo ""
echo -e "${BLUE}🌐 API Endpoints:${NC}"
echo "   GET  http://$GPU_INSTANCE_IP:8000/          - Service info"
echo "   GET  http://$GPU_INSTANCE_IP:8000/health    - Health check"  
echo "   POST http://$GPU_INSTANCE_IP:8000/transcribe/file - File transcription"
echo "   POST http://$GPU_INSTANCE_IP:8000/transcribe/s3 - S3 transcription"
echo ""
echo -e "${BLUE}📋 Quick Test Commands:${NC}"
echo "   curl http://$GPU_INSTANCE_IP:8000/"
echo "   curl http://$GPU_INSTANCE_IP:8000/health"
echo ""
echo -e "${YELLOW}📜 Next Steps:${NC}"
echo "1. Run: ./scripts/step-026-deploy-websocket.sh (optional - adds real-time streaming)"
echo "2. Run: ./scripts/step-030-test-system.sh (test the installation)"
echo "3. Upload audio files to test transcription"
echo ""

# Clean up temp files
rm -f /tmp/rnnt-ctl.sh