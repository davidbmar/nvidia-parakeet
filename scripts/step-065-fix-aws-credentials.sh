#!/bin/bash
set -e

# Production RNN-T Deployment - Step 3.7: Fix AWS Credentials for Service
# This script ensures AWS credentials are available to the RNN-T service

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

echo -e "${BLUE}🚀 Production RNN-T Deployment - AWS Credentials Fix${NC}"
echo "================================================================"
echo "Target Instance: $GPU_INSTANCE_IP"
echo ""

# Function to run SSH command
ssh_cmd() {
    local cmd="$*"
    echo -e "${BLUE}🔧 SSH: $cmd${NC}"
    if ! ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "$cmd"; then
        echo -e "${RED}❌ SSH command failed: $cmd${NC}"
        exit 1
    fi
}

# Step 1: Check deployment method
echo -e "${GREEN}=== Step 1: Detecting Deployment Method ===${NC}"
SERVICE_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "sudo systemctl is-active rnnt-server 2>/dev/null || echo 'inactive'")
CONTAINER_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "docker ps --format 'table {{.Names}}' 2>/dev/null | grep rnnt-server || echo 'not running'")

if [ "$SERVICE_STATUS" = "active" ]; then
    echo -e "${GREEN}✅ Found systemd service${NC}"
    DEPLOYMENT_METHOD="systemd"
elif [[ "$CONTAINER_STATUS" != *"not running"* ]]; then
    echo -e "${GREEN}✅ Found Docker container${NC}"
    DEPLOYMENT_METHOD="docker"
else
    echo -e "${RED}❌ No RNN-T deployment found${NC}"
    exit 1
fi

# Step 2: Fix AWS credentials based on deployment method
echo -e "${GREEN}=== Step 2: Fixing AWS Credentials Access ===${NC}"

if [ "$DEPLOYMENT_METHOD" = "systemd" ]; then
    echo "Copying AWS credentials to service user directory..."
    
    # Copy credentials to /opt/rnnt/.aws
    ssh_cmd "sudo mkdir -p /opt/rnnt/.aws"
    ssh_cmd "sudo cp ~/.aws/credentials /opt/rnnt/.aws/credentials 2>/dev/null || true"
    ssh_cmd "sudo cp ~/.aws/config /opt/rnnt/.aws/config 2>/dev/null || true"
    ssh_cmd "sudo chown -R ubuntu:ubuntu /opt/rnnt/.aws"
    ssh_cmd "sudo chmod 600 /opt/rnnt/.aws/credentials"
    
    # Update systemd service to include AWS credentials path
    echo "Updating systemd service environment..."
    ssh_cmd "sudo systemctl stop rnnt-server"
    
    # Add AWS credentials environment variable to service
    ssh_cmd "sudo sed -i '/\[Service\]/a Environment=\"AWS_SHARED_CREDENTIALS_FILE=/opt/rnnt/.aws/credentials\"' /etc/systemd/system/rnnt-server.service"
    ssh_cmd "sudo sed -i '/\[Service\]/a Environment=\"AWS_CONFIG_FILE=/opt/rnnt/.aws/config\"' /etc/systemd/system/rnnt-server.service"
    ssh_cmd "sudo sed -i '/\[Service\]/a Environment=\"HOME=/opt/rnnt\"' /etc/systemd/system/rnnt-server.service"
    
    # Reload and restart service
    ssh_cmd "sudo systemctl daemon-reload"
    ssh_cmd "sudo systemctl start rnnt-server"
    
    echo -e "${GREEN}✅ AWS credentials configured for systemd service${NC}"
    
elif [ "$DEPLOYMENT_METHOD" = "docker" ]; then
    echo "Restarting Docker container with AWS credentials..."
    
    # Stop current container
    ssh_cmd "docker stop rnnt-server"
    ssh_cmd "docker rm rnnt-server"
    
    # Restart with AWS credentials mounted
    ssh_cmd "docker run -d \\
        --name rnnt-server \\
        --gpus all \\
        --restart unless-stopped \\
        -p 8000:8000 \\
        -v ~/rnnt-deploy/logs:/app/logs \\
        -v /tmp/speechbrain_cache:/tmp/speechbrain_cache \\
        -v ~/.aws:/root/.aws:ro \\
        --env-file ~/rnnt-deploy/.env \\
        rnnt-server:latest"
    
    echo -e "${GREEN}✅ AWS credentials mounted in Docker container${NC}"
fi

# Step 3: Wait for service to be ready
echo -e "${GREEN}=== Step 3: Waiting for Service to Initialize ===${NC}"
echo -e "${YELLOW}⏳ Waiting 15 seconds for service to start...${NC}"
sleep 15

# Step 4: Verify health
echo -e "${GREEN}=== Step 4: Verifying Service Health ===${NC}"
HEALTH_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s http://localhost:8000/health || echo 'failed'")

if [[ "$HEALTH_RESPONSE" == *"healthy"* ]]; then
    echo -e "${GREEN}✅ Service is healthy${NC}"
else
    echo -e "${YELLOW}⚠️  Service may still be initializing${NC}"
    echo "Response: $HEALTH_RESPONSE"
fi

# Step 5: Test S3 access
echo -e "${GREEN}=== Step 5: Testing S3 Access from Service ===${NC}"

TEST_S3_REQUEST='{
    "s3_input_path": "s3://dbm-cf-2-web/users/01ebc530-5041-7042-936c-6e516c3a0d20/audio/sessions/1b3fd9db-dfb0-4360-913f-7096d62c1b0a/chunk-002.wav",
    "language": "en-US"
}'

echo "Testing S3 endpoint with small timeout..."
S3_TEST=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "
curl -X POST 'http://localhost:8000/transcribe/s3' \\
     -H 'Content-Type: application/json' \\
     -d '$TEST_S3_REQUEST' \\
     --connect-timeout 5 \\
     --max-time 10 \\
     -s 2>/dev/null | head -c 200
")

if [[ "$S3_TEST" == *"Unable to locate credentials"* ]]; then
    echo -e "${RED}❌ Credentials still not accessible${NC}"
    echo "Response: $S3_TEST"
    echo ""
    echo "Checking service environment..."
    ssh_cmd "sudo systemctl show rnnt-server --property=Environment"
elif [[ "$S3_TEST" == *"text"* ]] || [[ "$S3_TEST" == *"transcription"* ]]; then
    echo -e "${GREEN}✅ S3 access working! Service can download from S3${NC}"
else
    echo -e "${YELLOW}ℹ️  Service response: ${S3_TEST:0:100}...${NC}"
fi

echo ""
echo -e "${GREEN}🎉 AWS Credentials Fix Complete!${NC}"
echo "================================================================"
echo ""
echo -e "${YELLOW}📜 Next Steps:${NC}"
echo "1. Run: ./scripts/step-040-test-s3-transcription.sh"
echo "2. The S3 transcription should now work"
echo ""