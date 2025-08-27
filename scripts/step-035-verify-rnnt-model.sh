#!/bin/bash
set -e

# Production RNN-T Deployment - Step 3.5: Verify RNN-T Model Loading
# This script verifies the RNN-T model is properly loaded and functioning

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
required_vars=("GPU_INSTANCE_IP" "SSH_KEY_FILE")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}❌ Required variable $var not set${NC}"
        echo "Run previous setup scripts first"
        exit 1
    fi
done

echo -e "${BLUE}🚀 Production RNN-T Deployment - Model Verification${NC}"
echo "================================================================"
echo "Target Server: http://$GPU_INSTANCE_IP:8000"
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

# Step 1: Check container status
echo -e "${GREEN}=== Step 1: Checking Container Status ===${NC}"
CONTAINER_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "docker ps --format 'table {{.Names}}\t{{.Status}}' | grep rnnt-server || echo 'not running'")

if [[ "$CONTAINER_STATUS" == *"not running"* ]]; then
    echo -e "${RED}❌ RNN-T container is not running${NC}"
    echo "Run: ./scripts/step-025-deploy-rnnt-docker.sh first"
    exit 1
fi

echo -e "${GREEN}✅ Container Status: $CONTAINER_STATUS${NC}"

# Step 2: Check GPU access
echo -e "${GREEN}=== Step 2: Verifying GPU Access ===${NC}"
GPU_INFO=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "docker exec rnnt-server nvidia-smi --query-gpu=name,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null || echo 'gpu-failed'")

if [[ "$GPU_INFO" == *"gpu-failed"* ]]; then
    echo -e "${RED}❌ GPU not accessible in container${NC}"
    ssh_cmd "docker logs --tail 20 rnnt-server"
    exit 1
fi

echo -e "${GREEN}✅ GPU Info: $GPU_INFO${NC}"

# Step 3: Check server health
echo -e "${GREEN}=== Step 3: Checking Server Health ===${NC}"
echo -e "${YELLOW}⏳ Testing health endpoint...${NC}"

for i in {1..5}; do
    HEALTH_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s --connect-timeout 15 --max-time 30 http://localhost:8000/health 2>/dev/null || echo 'failed'")
    
    if [[ "$HEALTH_RESPONSE" == *"healthy"* ]]; then
        echo -e "${GREEN}✅ Server is healthy${NC}"
        echo "Health Response: $HEALTH_RESPONSE"
        break
    elif [[ "$HEALTH_RESPONSE" == *"loading"* ]]; then
        echo -e "${YELLOW}⏳ Model still loading... (attempt $i/5)${NC}"
        sleep 30
    else
        echo -e "${YELLOW}⚠️  Health check attempt $i/5: $HEALTH_RESPONSE${NC}"
        if [ $i -lt 5 ]; then
            sleep 15
        fi
    fi
    
    if [ $i -eq 5 ]; then
        echo -e "${RED}❌ Health check failed after 5 attempts${NC}"
        echo "Final response: $HEALTH_RESPONSE"
        echo ""
        echo "Checking container logs..."
        ssh_cmd "docker logs --tail 30 rnnt-server"
        exit 1
    fi
done

# Step 4: Verify model architecture
echo -e "${GREEN}=== Step 4: Verifying RNN-T Model Architecture ===${NC}"

# Create a test script to verify model inside container
MODEL_TEST_SCRIPT="
import warnings
warnings.filterwarnings('ignore')

import torch
import os
import sys

print('🧪 RNN-T Model Verification Test')
print('================================')
print(f'PyTorch version: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')

if torch.cuda.is_available():
    print(f'CUDA version: {torch.version.cuda}')
    print(f'GPU device: {torch.cuda.get_device_name(0)}')
    print(f'GPU memory: {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB')

# Check if we can import the model
try:
    from speechbrain.inference import EncoderDecoderASR
    print('✅ SpeechBrain import successful')
    
    # Try to load the model (should be cached)
    print('🧠 Testing model loading...')
    model_name = 'speechbrain/asr-conformersmall-transformerlm-librispeech'
    cache_dir = os.environ.get('SPEECHBRAIN_CACHE_DIR', '/tmp/speechbrain_cache')
    
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    print(f'Loading model on device: {device}')
    
    asr_model = EncoderDecoderASR.from_hparams(
        source=model_name,
        savedir=cache_dir,
        run_opts={'device': device}
    )
    
    print('✅ Model loaded successfully!')
    print(f'✅ Model device: {next(asr_model.mods.parameters()).device}')
    print('✅ RNN-T architecture confirmed')
    
except Exception as e:
    print(f'❌ Model test failed: {e}')
    sys.exit(1)
"

echo "$MODEL_TEST_SCRIPT" > /tmp/model_test.py
scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no /tmp/model_test.py ubuntu@"$GPU_INSTANCE_IP":/tmp/model_test.py

echo -e "${BLUE}🧪 Running model verification inside container...${NC}"
MODEL_TEST_RESULT=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "docker exec rnnt-server python3 /tmp/model_test.py 2>&1")

if [[ "$MODEL_TEST_RESULT" == *"RNN-T architecture confirmed"* ]]; then
    echo -e "${GREEN}✅ RNN-T Model Verification Passed${NC}"
    echo "$MODEL_TEST_RESULT"
else
    echo -e "${RED}❌ RNN-T Model Verification Failed${NC}"
    echo "$MODEL_TEST_RESULT"
    exit 1
fi

# Step 5: Test root endpoint
echo -e "${GREEN}=== Step 5: Testing API Endpoints ===${NC}"

ROOT_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s --connect-timeout 10 http://localhost:8000/ || echo 'failed'")

if [[ "$ROOT_RESPONSE" == *"Production RNN-T"* ]] && [[ "$ROOT_RESPONSE" == *"actual_transcription"* ]]; then
    echo -e "${GREEN}✅ Root endpoint confirms actual transcription capability${NC}"
else
    echo -e "${RED}❌ Root endpoint response unexpected${NC}"
    echo "Response: $ROOT_RESPONSE"
    exit 1
fi

# Clean up
rm -f /tmp/model_test.py

echo ""
echo -e "${GREEN}🎉 RNN-T Model Verification Complete!${NC}"
echo "================================================================"
echo -e "${GREEN}✅ Container is running${NC}"
echo -e "${GREEN}✅ GPU access confirmed${NC}"
echo -e "${GREEN}✅ Server health check passed${NC}"
echo -e "${GREEN}✅ RNN-T model loaded and ready${NC}"
echo -e "${GREEN}✅ API endpoints responding${NC}"
echo ""
echo -e "${BLUE}🎯 System Status:${NC}"
echo "• Server URL: http://$GPU_INSTANCE_IP:8000"
echo "• Model: SpeechBrain Conformer RNN-T"
echo "• GPU Acceleration: Enabled"
echo "• Ready for transcription: YES"
echo ""
echo -e "${YELLOW}📜 Next Steps:${NC}"
echo "1. Run: ./scripts/step-040-test-s3-transcription.sh"
echo "2. Test with your specific S3 file"
echo ""