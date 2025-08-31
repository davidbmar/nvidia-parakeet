#!/bin/bash
set -e

# Production RNN-T Deployment - Step 2: Install RNN-T Server
# This script installs and configures the RNN-T transcription server
#
# ===============================================================================
# INTELLIGENT MODEL CACHING SYSTEM
# ===============================================================================
# This script implements a 3-tier caching system for optimal deployment speed:
#
# 1. LOCAL CACHE (FASTEST - ~2 seconds)
#    - Checks: /opt/rnnt/models/asr-conformer-transformerlm-librispeech/
#    - If found: Skips all downloads, uses existing model
#    - Speed: Instant startup
#
# 2. S3 CACHE (FAST - ~5 seconds)  
#    - Checks: s3://AUDIO_BUCKET/bintarball/rnnt/model.tar.gz
#    - If found: Downloads 449 bytes, extracts to local cache
#    - Speed: Very fast deployment
#
# 3. HUGGINGFACE FALLBACK (SLOW - ~5 minutes)
#    - Downloads: 1.5GB from speechbrain/asr-conformer-transformerlm-librispeech
#    - Auto-uploads: Creates S3 cache for future deployments
#    - Speed: Slow first time, fast for everyone after
#
# DEPLOYMENT SCENARIOS:
# - First deployment: Local❌ → S3❌ → HuggingFace✅ → Auto-upload to S3✅
# - Second deployment: Local❌ → S3✅ → Download from S3✅ (FAST!)  
# - Re-run deployment: Local✅ → Skip everything✅ (INSTANT!)
#
# This creates a self-optimizing system where the first person to deploy
# creates the S3 cache, and everyone else benefits from fast deployments.
# ===============================================================================

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

# Function to wait for package manager lock to be released
wait_for_apt_lock() {
    echo -e "${YELLOW}⏳ Checking for package manager availability...${NC}"
    local max_wait=600  # 10 minutes maximum
    local max_stuck=120  # 2 minutes without progress = likely stuck
    local waited=0
    local last_process=""
    local last_activity=""
    local stuck_time=0
    
    while [ $waited -lt $max_wait ]; do
        # Check what's holding the lock
        LOCK_INFO=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
            "sudo lsof /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null | grep -v COMMAND | head -1" 2>/dev/null || echo "")
        
        if [ -n "$LOCK_INFO" ]; then
            # Extract process name and PID
            PROCESS_NAME=$(echo "$LOCK_INFO" | awk '{print $1}')
            PROCESS_PID=$(echo "$LOCK_INFO" | awk '{print $2}')
            
            # Check for activity - look at CPU usage and dpkg status
            ACTIVITY_CHECK=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
                "ps aux | grep -E \"PID.*${PROCESS_PID}|${PROCESS_PID}.*\" | grep -v grep | awk '{print \$3}' | head -1" 2>/dev/null || echo "0")
            
            # Get current dpkg status to see if packages are being processed
            DPKG_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
                "sudo tail -1 /var/log/dpkg.log 2>/dev/null | cut -c1-100" 2>/dev/null || echo "")
            
            # Check if anything changed
            CURRENT_ACTIVITY="${DPKG_STATUS}"
            if [ "$CURRENT_ACTIVITY" = "$last_activity" ]; then
                stuck_time=$((stuck_time + 5))
            else
                stuck_time=0
                last_activity="$CURRENT_ACTIVITY"
            fi
            
            if [ "$last_process" != "$PROCESS_NAME-$PROCESS_PID" ]; then
                echo -e "\n${YELLOW}⚠️  Package manager is locked by: ${PROCESS_NAME} (PID: ${PROCESS_PID})${NC}"
                last_process="$PROCESS_NAME-$PROCESS_PID"
                
                # Check if it's unattended-upgrades
                if [[ "$PROCESS_NAME" == *"unattended"* ]]; then
                    # Count how many packages need updating
                    PACKAGE_COUNT=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
                        "grep 'Packages that will be upgraded:' /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null | tail -1 | wc -w" 2>/dev/null || echo "0")
                    if [ "$PACKAGE_COUNT" -gt 10 ]; then
                        echo -e "${YELLOW}   Installing security updates ($(($PACKAGE_COUNT-5)) packages)...${NC}"
                        echo -e "${BLUE}   This may take 5-10 minutes for a fresh instance${NC}"
                    fi
                fi
            fi
            
            # Show current package being processed if available
            if [ -n "$DPKG_STATUS" ] && [ "$stuck_time" -eq 0 ]; then
                CURRENT_PKG=$(echo "$DPKG_STATUS" | grep -oE "(install|configure|unpack) [a-z0-9-]+" | head -1 || echo "")
                if [ -n "$CURRENT_PKG" ]; then
                    echo -ne "\r   Processing: $CURRENT_PKG... ($(($waited/60))m $(($waited%60))s elapsed)     "
                fi
            fi
            
            # Check if process seems stuck
            if [ $stuck_time -ge $max_stuck ]; then
                echo -e "\n${RED}⚠️  Process appears stuck - no activity for 2 minutes${NC}"
                echo -e "${YELLOW}   Last status: $DPKG_STATUS${NC}"
                echo -e "${YELLOW}   Options:${NC}"
                echo "   1. Wait a bit longer (sometimes dpkg is slow)"
                echo "   2. Kill the process: sudo kill -9 $PROCESS_PID"
                echo "   3. Reboot and retry: aws ec2 reboot-instances --instance-ids $GPU_INSTANCE_ID"
                
                read -t 30 -p "   Continue waiting? (Y/n, auto-continues in 30s): " -n 1 response || response="y"
                echo
                if [[ ! "$response" =~ ^[Yy]$ ]] && [ -n "$response" ]; then
                    return 1
                fi
                stuck_time=0  # Reset stuck counter if user wants to continue
            fi
            
            # Show progress indicator
            if [ $stuck_time -gt 30 ]; then
                echo -ne "\r   ⚠️  No activity for ${stuck_time}s ($(($waited/60))m total)        "
            fi
            
            sleep 5
            waited=$((waited + 5))
        else
            if [ $waited -gt 0 ]; then
                echo -e "\n${GREEN}✅ Package manager is now available!${NC}"
            else
                echo -e "${GREEN}✅ Package manager is available${NC}"
            fi
            return 0
        fi
    done
    
    echo -e "\n${RED}❌ Package manager still locked after 10 minutes${NC}"
    return 1
}

# Function to run apt-get commands with lock checking
apt_cmd() {
    wait_for_apt_lock
    ssh_cmd "$@"
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
apt_cmd "sudo apt-get update && sudo apt-get upgrade -y"
apt_cmd "sudo apt-get install -y python3-pip python3-venv python3-dev build-essential"
apt_cmd "sudo apt-get install -y ffmpeg libsndfile1 git curl wget"

# Install AWS CLI if not present
ssh_cmd "which aws || (curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o awscliv2.zip && unzip awscliv2.zip && sudo ./aws/install)"

# Step 3: NVIDIA Driver Setup (if needed)
echo -e "${GREEN}=== Step 3: NVIDIA Driver Setup ===${NC}"
NVIDIA_CHECK=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "nvidia-smi || echo 'not-found'" 2>/dev/null)
if [[ "$NVIDIA_CHECK" == *"not-found"* ]]; then
    echo "Installing NVIDIA drivers..."
    apt_cmd "sudo apt-get install -y ubuntu-drivers-common"
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

# Check if model already exists locally
if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "[ -d '/opt/rnnt/models/asr-conformer-transformerlm-librispeech' ]" 2>/dev/null; then
    echo -e "${GREEN}✅ Model already cached locally${NC}"
    echo "💾 Model location: /opt/rnnt/models/asr-conformer-transformerlm-librispeech"
    echo "⚡ Skipping download - using existing cache"

# Check if model exists in S3
elif aws s3 ls "s3://$AUDIO_BUCKET/bintarball/rnnt/model.tar.gz" &>/dev/null; then
    echo -e "${BLUE}📦 Downloading pre-cached model from S3...${NC}"
    echo "S3 Location: s3://$AUDIO_BUCKET/bintarball/rnnt/model.tar.gz"
    
    # Download model from S3
    ssh_cmd "aws s3 cp s3://$AUDIO_BUCKET/bintarball/rnnt/model.tar.gz /opt/rnnt/model.tar.gz --region $AWS_REGION"
    
    # Extract model (clean target first to avoid conflicts)
    ssh_cmd "cd /opt/rnnt && tar -xzf model.tar.gz"
    ssh_cmd "rm -rf /opt/rnnt/models/asr-conformer-transformerlm-librispeech"
    ssh_cmd "mv /opt/rnnt/asr-conformer-transformerlm-librispeech /opt/rnnt/models/"
    ssh_cmd "rm -f /opt/rnnt/model.tar.gz"
    
    echo -e "${GREEN}✅ Model downloaded from S3 successfully${NC}"
    echo "💾 Model cached in: /opt/rnnt/models/"
else
    echo -e "${YELLOW}⚠️  Model not found in S3, downloading from Hugging Face...${NC}"
    echo -e "${YELLOW}⏳ This may take several minutes (downloading ~1.5GB model)...${NC}"
    
    # Create model download script for Hugging Face fallback
    MODEL_DOWNLOAD_SCRIPT="
import warnings
warnings.filterwarnings('ignore')

import os
import torch
from speechbrain.inference import EncoderDecoderASR

print('🔥 Downloading SpeechBrain Conformer RNN-T model from Hugging Face...')
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
    
    echo ""
    echo -e "${BLUE}📦 Auto-uploading model to S3 cache for future deployments...${NC}"
    echo "This ensures subsequent deployments will be much faster (449 bytes vs 1.5GB)"
    
    # Create compressed model archive for S3 upload
    ssh_cmd "cd /opt/rnnt && tar -czf model.tar.gz -C models/ asr-conformer-transformerlm-librispeech"
    
    # Upload to S3 with error handling
    if ssh_cmd "aws s3 cp /opt/rnnt/model.tar.gz s3://$AUDIO_BUCKET/bintarball/rnnt/model.tar.gz --region $AWS_REGION"; then
        echo -e "${GREEN}✅ Model successfully cached in S3${NC}"
        echo "📍 S3 Location: s3://$AUDIO_BUCKET/bintarball/rnnt/model.tar.gz"
        echo "⚡ Future deployments will download from S3 cache (~5 seconds vs ~5 minutes)"
        
        # Clean up temporary archive
        ssh_cmd "rm -f /opt/rnnt/model.tar.gz"
    else
        echo -e "${YELLOW}⚠️  S3 upload failed, but model is cached locally${NC}"
        echo "Future deployments on this instance will still be fast"
        ssh_cmd "rm -f /opt/rnnt/model.tar.gz"
    fi
fi

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

# Step 10: Health Check with Progress Monitoring
echo -e "${GREEN}=== Step 10: Health Check ===${NC}"
echo -e "${YELLOW}⏳ Waiting for server to initialize...${NC}"

# Function to check server health and show progress
check_server_health() {
    local max_wait=180  # 3 minutes maximum
    local check_interval=5
    local waited=0
    local last_status=""
    
    while [ $waited -lt $max_wait ]; do
        # Check if service is running
        SERVICE_STATUS=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
            "sudo systemctl is-active rnnt-server 2>/dev/null" || echo "inactive")
        
        if [ "$SERVICE_STATUS" != "active" ]; then
            echo -e "\r   Service status: ${RED}$SERVICE_STATUS${NC} (${waited}s elapsed)"
            sleep $check_interval
            waited=$((waited + check_interval))
            continue
        fi
        
        # Try to get health status
        HEALTH_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
            "curl -s --connect-timeout 3 http://localhost:8000/health 2>/dev/null" || echo "")
        
        if [ -n "$HEALTH_RESPONSE" ] && [[ "$HEALTH_RESPONSE" == *"status"* ]]; then
            # Parse status from JSON response
            if [[ "$HEALTH_RESPONSE" == *'"status":"healthy"'* ]]; then
                echo -e "\n${GREEN}✅ Server is healthy and ready!${NC}"
                
                # Show model info if available
                if [[ "$HEALTH_RESPONSE" == *"model_loaded"* ]]; then
                    MODEL_STATUS=$(echo "$HEALTH_RESPONSE" | grep -o '"model_loaded":[^,]*' | cut -d':' -f2)
                    echo -e "${GREEN}✅ Model loaded: $MODEL_STATUS${NC}"
                fi
                
                # Show GPU info if available
                if [[ "$HEALTH_RESPONSE" == *"gpu_available"* ]]; then
                    GPU_STATUS=$(echo "$HEALTH_RESPONSE" | grep -o '"gpu_available":[^,]*' | cut -d':' -f2)
                    echo -e "${GREEN}✅ GPU available: $GPU_STATUS${NC}"
                fi
                
                return 0
                
            elif [[ "$HEALTH_RESPONSE" == *'"status":"loading"'* ]] || [[ "$HEALTH_RESPONSE" == *'"status":"initializing"'* ]]; then
                STATUS_MSG="Server initializing (loading model)"
                
            else
                # Try to extract any status information
                STATUS_MSG="Server responding but status unclear"
            fi
        else
            # Check server logs for more info about what's happening
            LOG_INFO=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
                "sudo journalctl -u rnnt-server --no-pager -n 1 --since '30 seconds ago' 2>/dev/null | grep -oE '(Loading|Downloading|Initializing|Starting|Model|Error).*' | head -1" || echo "")
            
            if [ -n "$LOG_INFO" ]; then
                STATUS_MSG="$LOG_INFO"
            else
                STATUS_MSG="Server starting up"
            fi
        fi
        
        # Update status if it changed
        if [ "$STATUS_MSG" != "$last_status" ]; then
            echo -e "\n   ${BLUE}Status: $STATUS_MSG${NC}"
            last_status="$STATUS_MSG"
        fi
        
        # Show progress
        local dots=$((waited / check_interval % 4))
        local dot_str=""
        for ((i=0; i<dots; i++)); do dot_str="$dot_str."; done
        printf "\r   Waiting%s (${waited}s elapsed)    " "$dot_str"
        
        sleep $check_interval
        waited=$((waited + check_interval))
    done
    
    echo -e "\n${RED}❌ Server did not become healthy within 3 minutes${NC}"
    echo -e "${YELLOW}   Final response: $HEALTH_RESPONSE${NC}"
    echo -e "${YELLOW}   Check server logs: ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP 'sudo journalctl -u rnnt-server -f'${NC}"
    return 1
}

# Run the health check with progress monitoring
if check_server_health; then
    # Test root endpoint to verify it's working
    echo -e "${BLUE}🔍 Testing API endpoints...${NC}"
    ROOT_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
        "curl -s --connect-timeout 10 http://localhost:8000/ 2>/dev/null || echo 'failed'")
    
    if [[ "$ROOT_RESPONSE" == *"Production RNN-T"* ]]; then
        echo -e "${GREEN}✅ API endpoints responding correctly${NC}"
        
        # Extract and display key info
        if [[ "$ROOT_RESPONSE" == *"model_load_time"* ]]; then
            LOAD_TIME=$(echo "$ROOT_RESPONSE" | grep -o '"model_load_time":"[^"]*"' | cut -d'"' -f4)
            echo -e "${BLUE}📊 Model loaded in: $LOAD_TIME${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  Health check passed but API not fully ready${NC}"
    fi
else
    echo -e "${RED}❌ Server health check failed${NC}"
    echo -e "${YELLOW}   The server may still be starting. Check logs with:${NC}"
    echo "   ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP 'sudo journalctl -u rnnt-server -f'"
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