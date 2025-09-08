#!/bin/bash
set -e

# NVIDIA Parakeet Riva ASR Deployment - Step 10: Deploy GPU Instance
# This script deploys an AWS EC2 GPU instance for running Riva ASR server

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 NVIDIA Parakeet Riva ASR Deployment - Step 10: Deploy GPU Instance${NC}"
echo "================================================================"

# Check if configuration exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Run: ./scripts/riva-000-setup-configuration.sh"
    exit 1
fi

# Source configuration
source "$ENV_FILE"

# Check if this is AWS deployment
if [ "$DEPLOYMENT_STRATEGY" != "1" ]; then
    echo -e "${YELLOW}⏭️  Skipping GPU instance deployment (Strategy: $DEPLOYMENT_STRATEGY)${NC}"
    echo "This step is only for AWS EC2 deployment (Strategy 1)"
    exit 0
fi

# Validate AWS configuration
if [ -z "$AWS_REGION" ] || [ -z "$AWS_ACCOUNT_ID" ] || [ -z "$GPU_INSTANCE_TYPE" ] || [ -z "$SSH_KEY_NAME" ]; then
    echo -e "${RED}❌ Missing AWS configuration in .env file${NC}"
    exit 1
fi

# Set defaults for EBS configuration if not specified
EBS_VOLUME_SIZE=${EBS_VOLUME_SIZE:-200}
EBS_VOLUME_TYPE=${EBS_VOLUME_TYPE:-gp3}

echo "Configuration:"
echo "  • AWS Region: $AWS_REGION"
echo "  • Account ID: $AWS_ACCOUNT_ID"
echo "  • Instance Type: $GPU_INSTANCE_TYPE"
echo "  • SSH Key: $SSH_KEY_NAME"
echo "  • EBS Volume: ${EBS_VOLUME_SIZE}GB ($EBS_VOLUME_TYPE)"
echo ""

# Check if SSH key exists locally or in AWS
echo -e "${BLUE}🔑 Checking SSH key configuration...${NC}"
SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo -e "${YELLOW}⚠️  SSH key not found locally at: $SSH_KEY_PATH${NC}"
    
    # Check if key exists in AWS
    KEY_EXISTS_IN_AWS=$(aws ec2 describe-key-pairs --key-names "$SSH_KEY_NAME" --region "$AWS_REGION" 2>/dev/null && echo "yes" || echo "no")
    
    if [ "$KEY_EXISTS_IN_AWS" = "yes" ]; then
        echo -e "${YELLOW}Key pair '$SSH_KEY_NAME' exists in AWS but not locally.${NC}"
        echo "Creating new local key pair with different name..."
        
        # Generate new key name with timestamp
        SSH_KEY_NAME="${SSH_KEY_NAME}-$(date +%Y%m%d-%H%M%S)"
        SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
        echo "New key name: $SSH_KEY_NAME"
    fi
    
    # Create new key pair
    echo -e "${BLUE}Creating new SSH key pair...${NC}"
    aws ec2 create-key-pair \
        --key-name "$SSH_KEY_NAME" \
        --query 'KeyMaterial' \
        --output text \
        --region "$AWS_REGION" > "$SSH_KEY_PATH"
    
    if [ $? -eq 0 ]; then
        chmod 400 "$SSH_KEY_PATH"
        echo -e "${GREEN}✅ Created new SSH key: $SSH_KEY_PATH${NC}"
        
        # Update .env with new key name
        sed -i "s/SSH_KEY_NAME=.*/SSH_KEY_NAME=$SSH_KEY_NAME/" "$ENV_FILE"
    else
        echo -e "${RED}❌ Failed to create SSH key pair${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✅ SSH key found: $SSH_KEY_PATH${NC}"
fi
echo ""

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI not installed${NC}"
    echo "Install with: sudo apt-get update && sudo apt-get install awscli"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &>/dev/null; then
    echo -e "${RED}❌ AWS credentials not configured${NC}"
    echo "Run: aws configure"
    exit 1
fi

# Function to get latest Deep Learning AMI
get_latest_dl_ami() {
    local region="$1"
    aws ec2 describe-images \
        --owners amazon \
        --filters \
            'Name=name,Values=Deep Learning AMI GPU PyTorch*Ubuntu*' \
            'Name=state,Values=available' \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text \
        --region "$region"
}

# Function to create security group
create_security_group() {
    local sg_name="riva-asr-sg-${DEPLOYMENT_ID}"
    local sg_desc="Security group for NVIDIA Parakeet Riva ASR server"
    
    echo -e "${BLUE}🔒 Checking for existing security group: $sg_name${NC}" >&2
    
    # Check if security group already exists
    local sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$sg_name" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "None")
    
    if [ "$sg_id" != "None" ] && [ "$sg_id" != "null" ] && [ -n "$sg_id" ]; then
        echo -e "${YELLOW}Using existing security group: $sg_id${NC}" >&2
        echo "$sg_id"
        return 0
    fi
    
    # Create new security group
    echo -e "${BLUE}Creating new security group: $sg_name${NC}" >&2
    sg_id=$(aws ec2 create-security-group \
        --group-name "$sg_name" \
        --description "$sg_desc" \
        --query 'GroupId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null)
    
    if [ -z "$sg_id" ]; then
        echo -e "${RED}❌ Failed to create security group${NC}"
        return 1
    fi
    
    echo "Security Group ID: $sg_id" >&2
    
    # Add rules
    echo "Adding security group rules..." >&2
    
    # SSH access
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" &>/dev/null
    
    # Riva gRPC port
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port "$RIVA_PORT" \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" &>/dev/null
    
    # Riva HTTP port
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port "$RIVA_HTTP_PORT" \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" &>/dev/null
    
    # WebSocket app port
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port "$APP_PORT" \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" &>/dev/null
    
    # Metrics port (if enabled)
    if [ "$METRICS_ENABLED" = "true" ]; then
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --protocol tcp \
            --port "$METRICS_PORT" \
            --cidr 0.0.0.0/0 \
            --region "$AWS_REGION" &>/dev/null
    fi
    
    echo "$sg_id"
}

# Function to create user data script
create_user_data() {
    cat << 'EOF'
#!/bin/bash
set -e

# Update system
apt-get update
apt-get install -y htop nvtop git python3-pip docker.io

# Add ubuntu user to docker group
usermod -aG docker ubuntu

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Install NVIDIA Container Toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
apt-get install -y nvidia-container-toolkit

# Configure Docker for NVIDIA runtime
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# Create directories
mkdir -p /opt/riva/{logs,models,certs,config}
chown -R ubuntu:ubuntu /opt/riva

# Mark initialization complete
echo "$(date): GPU instance initialization complete" > /opt/riva/init-complete
EOF
}

# Main deployment
echo -e "${BLUE}🔍 Checking existing instances...${NC}"

# Check if instance already exists
EXISTING_INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:DeploymentId,Values=$DEPLOYMENT_ID" "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "None")

if [ "$EXISTING_INSTANCE" != "None" ] && [ "$EXISTING_INSTANCE" != "null" ]; then
    echo -e "${YELLOW}⚠️  Found existing instance: $EXISTING_INSTANCE${NC}"
    
    # Get instance state
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --instance-ids "$EXISTING_INSTANCE" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text \
        --region "$AWS_REGION")
    
    echo "Instance state: $INSTANCE_STATE"
    
    if [ "$INSTANCE_STATE" = "stopped" ]; then
        echo -e "${YELLOW}Starting existing instance...${NC}"
        aws ec2 start-instances --instance-ids "$EXISTING_INSTANCE" --region "$AWS_REGION" &>/dev/null
        
        # Wait for running state
        echo "Waiting for instance to start..."
        aws ec2 wait instance-running --instance-ids "$EXISTING_INSTANCE" --region "$AWS_REGION"
    fi
    
    # Get instance IP
    INSTANCE_IP=$(aws ec2 describe-instances \
        --instance-ids "$EXISTING_INSTANCE" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text \
        --region "$AWS_REGION")
    
    # Update .env file
    sed -i "s/RIVA_HOST=.*/RIVA_HOST=$INSTANCE_IP/" "$ENV_FILE"
    sed -i "s/GPU_INSTANCE_ID=.*/GPU_INSTANCE_ID=$EXISTING_INSTANCE/" "$ENV_FILE"
    sed -i "s/GPU_INSTANCE_IP=.*/GPU_INSTANCE_IP=$INSTANCE_IP/" "$ENV_FILE"
    
    echo -e "${GREEN}✅ Using existing instance: $EXISTING_INSTANCE${NC}"
    echo "Instance IP: $INSTANCE_IP"
    exit 0
fi

echo -e "${BLUE}🚀 Launching new GPU instance...${NC}"

# Get latest Deep Learning AMI
echo "Finding latest Deep Learning AMI..."
AMI_ID=$(get_latest_dl_ami "$AWS_REGION")

if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
    echo -e "${RED}❌ Failed to find suitable AMI${NC}"
    exit 1
fi

echo "Using AMI: $AMI_ID"

# Create security group
SG_ID=$(create_security_group)
if [ -z "$SG_ID" ]; then
    echo -e "${RED}❌ Failed to create security group${NC}"
    exit 1
fi

# Create user data
USER_DATA_FILE="/tmp/riva-user-data.sh"
create_user_data > "$USER_DATA_FILE"

# Launch instance
echo -e "${BLUE}🎯 Launching EC2 instance...${NC}"

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --count 1 \
    --instance-type "$GPU_INSTANCE_TYPE" \
    --key-name "$SSH_KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "file://$USER_DATA_FILE" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=riva-asr-${DEPLOYMENT_ID}},{Key=Purpose,Value=ParakeetRivaASR},{Key=DeploymentId,Value=${DEPLOYMENT_ID}},{Key=CreatedBy,Value=riva-deployment-script}]" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":'${EBS_VOLUME_SIZE:-200}',"VolumeType":"'${EBS_VOLUME_TYPE:-gp3}'","DeleteOnTermination":true}}]' \
    --query 'Instances[0].InstanceId' \
    --output text \
    --region "$AWS_REGION")

if [ -z "$INSTANCE_ID" ]; then
    echo -e "${RED}❌ Failed to launch instance${NC}"
    exit 1
fi

echo "Instance ID: $INSTANCE_ID"

# Wait for instance to be running
echo -e "${YELLOW}⏳ Waiting for instance to be running...${NC}"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

# Get public IP
INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text \
    --region "$AWS_REGION")

echo "Instance IP: $INSTANCE_IP"

# Update .env file
sed -i "s/RIVA_HOST=.*/RIVA_HOST=$INSTANCE_IP/" "$ENV_FILE"
echo "GPU_INSTANCE_ID=$INSTANCE_ID" >> "$ENV_FILE"
echo "GPU_INSTANCE_IP=$INSTANCE_IP" >> "$ENV_FILE"
echo "SECURITY_GROUP_ID=$SG_ID" >> "$ENV_FILE"

# Wait for SSH to be available
echo -e "${YELLOW}⏳ Waiting for SSH access...${NC}"
SSH_READY=false
SSH_KEY_PATH="~/.ssh/${SSH_KEY_NAME}.pem"

# Check if SSH key exists
if [ ! -f "$HOME/.ssh/${SSH_KEY_NAME}.pem" ]; then
    echo -e "${YELLOW}⚠️  SSH key not found at $HOME/.ssh/${SSH_KEY_NAME}.pem${NC}"
    echo "Skipping SSH connectivity check. You can still connect manually using:"
    echo "  ssh -i /path/to/${SSH_KEY_NAME}.pem ubuntu@$INSTANCE_IP"
    SSH_READY=skip
else
    for i in {1..30}; do
        if ssh -i "$HOME/.ssh/${SSH_KEY_NAME}.pem" -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'echo "SSH ready"' &>/dev/null; then
            SSH_READY=true
            echo -e "${GREEN}✅ SSH access confirmed${NC}"
            break
        fi
        echo -n "."
        sleep 10
    done
    echo ""
    
    if [ "$SSH_READY" = "false" ]; then
        echo -e "${YELLOW}⚠️  SSH connection timed out. This could be due to:${NC}"
        echo "  • Security group rules not yet propagated"
        echo "  • Instance still initializing"
        echo "  • Network connectivity issues"
        echo ""
        echo "Instance is running. You can try connecting manually:"
        echo "  ssh -i $HOME/.ssh/${SSH_KEY_NAME}.pem ubuntu@$INSTANCE_IP"
    fi
fi

# Wait for initialization to complete (only if SSH is available)
if [ "$SSH_READY" = "true" ]; then
    echo -e "${YELLOW}⏳ Waiting for instance initialization...${NC}"
    INIT_COMPLETE=false
    for i in {1..60}; do
        if ssh -i "$HOME/.ssh/${SSH_KEY_NAME}.pem" -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'test -f /opt/riva/init-complete' &>/dev/null; then
            echo -e "${GREEN}✅ Instance initialization complete${NC}"
            INIT_COMPLETE=true
            break
        fi
        echo -n "."
        sleep 10
    done
    echo ""
    
    if [ "$INIT_COMPLETE" = "false" ]; then
        echo -e "${YELLOW}⚠️  Initialization check timed out. The instance may still be setting up.${NC}"
    fi
fi

# Test GPU availability (only if SSH is available)
if [ "$SSH_READY" = "true" ]; then
    echo -e "${BLUE}🧪 Testing GPU availability...${NC}"
    GPU_INFO=$(ssh -i "$HOME/.ssh/${SSH_KEY_NAME}.pem" -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@$INSTANCE_IP 'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader' 2>/dev/null || echo "GPU check failed")
    
    if [ "$GPU_INFO" != "GPU check failed" ]; then
        echo "GPU detected: $GPU_INFO"
    else
        echo -e "${YELLOW}⚠️  GPU check failed - this may be normal during boot${NC}"
        echo "You can check GPU status later with:"
        echo "  ssh -i $HOME/.ssh/${SSH_KEY_NAME}.pem ubuntu@$INSTANCE_IP nvidia-smi"
    fi
fi

# Clean up temporary files
rm -f "$USER_DATA_FILE"

echo ""
echo -e "${GREEN}✅ GPU Instance Deployment Complete!${NC}"
echo "================================================================"
echo "Instance Details:"
echo "  • Instance ID: $INSTANCE_ID"
echo "  • Instance Type: $GPU_INSTANCE_TYPE"
echo "  • Public IP: $INSTANCE_IP"
echo "  • Region: $AWS_REGION"
echo "  • Security Group: $SG_ID"
echo ""
echo "SSH Access:"
echo "  ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@$INSTANCE_IP"
echo ""
echo -e "${YELLOW}⚠️  Important Notes:${NC}"
echo "  • If SSH is not working, wait 2-3 minutes for instance to fully initialize"
echo "  • Check instance status: aws ec2 describe-instance-status --instance-ids $INSTANCE_ID --region $AWS_REGION"
echo "  • Check security group: aws ec2 describe-security-groups --group-ids $SG_ID --region $AWS_REGION"
echo ""
echo -e "${YELLOW}💰 Cost Estimate:${NC}"
case $GPU_INSTANCE_TYPE in
    "g4dn.xlarge")
        echo "  ~\$0.526/hour (~\$378/month if running 24/7)"
        ;;
    "g4dn.2xlarge")
        echo "  ~\$0.752/hour (~\$540/month if running 24/7)"
        ;;
    "g5.xlarge")
        echo "  ~\$1.006/hour (~\$722/month if running 24/7)"
        ;;
    "p3.2xlarge")
        echo "  ~\$3.06/hour (~\$2,203/month if running 24/7)"
        ;;
esac
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo "1. Configure security access: ./scripts/riva-015-configure-security-access.sh"
echo "2. Setup Riva server: ./scripts/riva-020-setup-riva-server.sh"
echo "3. Deploy WebSocket app: ./scripts/riva-030-deploy-websocket-app.sh"
echo ""