#!/bin/bash
set -e

# Production RNN-T Deployment - Step 1: Deploy GPU Instance
# This script creates and configures a GPU instance for RNN-T transcription

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
required_vars=("AWS_REGION" "AWS_ACCOUNT_ID" "GPU_INSTANCE_TYPE")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}❌ Required variable $var not set in $ENV_FILE${NC}"
        exit 1
    fi
done

echo -e "${BLUE}🚀 Production RNN-T Deployment - GPU Instance Setup${NC}"
echo "================================================================"
echo "AWS Region: $AWS_REGION"
echo "Instance Type: $GPU_INSTANCE_TYPE"
echo "Account ID: $AWS_ACCOUNT_ID"
echo ""

# Function to run AWS CLI with error handling
aws_cmd() {
    local cmd="$*"
    echo -e "${BLUE}🔧 Running: aws $cmd${NC}"
    if ! aws $cmd; then
        echo -e "${RED}❌ AWS command failed: $cmd${NC}"
        exit 1
    fi
}

# Function to wait for instance state
wait_for_instance_state() {
    local instance_id="$1"
    local desired_state="$2"
    local timeout="${3:-300}"  # 5 minutes default
    
    echo -e "${YELLOW}⏳ Waiting for instance $instance_id to reach state: $desired_state${NC}"
    
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local current_state=$(aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text)
        
        echo "   Current state: $current_state (${elapsed}s elapsed)"
        
        if [ "$current_state" = "$desired_state" ]; then
            echo -e "${GREEN}✅ Instance reached desired state: $desired_state${NC}"
            return 0
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    echo -e "${RED}❌ Timeout waiting for instance to reach state: $desired_state${NC}"
    return 1
}

# Step 1: Create Key Pair
echo -e "${GREEN}=== Step 1: Creating SSH Key Pair ===${NC}"
if [ -z "$KEY_NAME" ] || [ "$KEY_NAME" = "" ]; then
    KEY_NAME="rnnt-production-key-$(date +%s)"
    echo "Generated key name: $KEY_NAME"
    
    # Update .env file
    sed -i "s/KEY_NAME=\".*\"/KEY_NAME=\"$KEY_NAME\"/" "$ENV_FILE"
fi

SSH_KEY_FILE="$PROJECT_ROOT/$KEY_NAME.pem"

# Check if key file exists and validate it
if [ -f "$SSH_KEY_FILE" ]; then
    if [ ! -s "$SSH_KEY_FILE" ]; then
        echo -e "${RED}❌ ERROR: SSH key file exists but is empty (0 bytes): $SSH_KEY_FILE${NC}"
        echo -e "${YELLOW}   This usually happens when key creation failed previously.${NC}"
        echo -e "${YELLOW}   Removing empty file and attempting to recreate...${NC}"
        rm -f "$SSH_KEY_FILE"
    elif ! ssh-keygen -l -f "$SSH_KEY_FILE" >/dev/null 2>&1; then
        echo -e "${RED}❌ ERROR: SSH key file exists but appears corrupted: $SSH_KEY_FILE${NC}"
        echo -e "${YELLOW}   The file is not a valid SSH private key.${NC}"
        echo -e "${YELLOW}   Please remove the file manually and run the script again.${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ Found valid existing SSH key file - REUSING: $SSH_KEY_FILE${NC}"
        chmod 600 "$SSH_KEY_FILE"
    fi
fi

# Create key if file doesn't exist
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo -e "${BLUE}🔧 Creating new SSH key pair: $KEY_NAME${NC}"
    
    # Check if key exists in AWS first
    if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  Key pair already exists in AWS but local file is missing${NC}"
        echo -e "${YELLOW}   Deleting AWS key pair to recreate with local file...${NC}"
        aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$AWS_REGION"
        echo -e "${GREEN}✅ Deleted existing AWS key pair${NC}"
    fi
    
    # Create new key pair with proper error handling
    echo "   Creating key pair in AWS..."
    KEY_MATERIAL=$(aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --region "$AWS_REGION" \
        --query 'KeyMaterial' \
        --output text 2>&1)
    
    if [ $? -eq 0 ] && [ -n "$KEY_MATERIAL" ] && [[ ! "$KEY_MATERIAL" =~ "error" ]]; then
        echo "$KEY_MATERIAL" > "$SSH_KEY_FILE"
        chmod 600 "$SSH_KEY_FILE"
        
        # Verify the key was written correctly
        if [ -s "$SSH_KEY_FILE" ] && ssh-keygen -l -f "$SSH_KEY_FILE" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ SSH key created successfully: $SSH_KEY_FILE${NC}"
        else
            echo -e "${RED}❌ ERROR: Failed to write valid SSH key to file${NC}"
            rm -f "$SSH_KEY_FILE"
            aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$AWS_REGION" >/dev/null 2>&1
            exit 1
        fi
    else
        echo -e "${RED}❌ ERROR: Failed to create SSH key pair in AWS${NC}"
        if [[ "$KEY_MATERIAL" =~ "InvalidKeyPair.Duplicate" ]]; then
            echo -e "${YELLOW}   Key pair already exists in AWS. Try running the destroy script first.${NC}"
        else
            echo -e "${YELLOW}   AWS Error: $KEY_MATERIAL${NC}"
        fi
        rm -f "$SSH_KEY_FILE"  # Remove any empty file created
        exit 1
    fi
fi

# Update .env with key file path
sed -i "s|SSH_KEY_FILE=\".*\"|SSH_KEY_FILE=\"$SSH_KEY_FILE\"|" "$ENV_FILE"

# Step 2: Create Security Group
echo -e "${GREEN}=== Step 2: Creating Security Group ===${NC}"
if [ -z "$SECURITY_GROUP_ID" ] || [ "$SECURITY_GROUP_ID" = "" ]; then
    SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-rnnt-production-sg}"
    
    # Check if security group already exists
    echo "Checking for existing security group: $SECURITY_GROUP_NAME"
    EXISTING_SG_ID=$(aws ec2 describe-security-groups \
        --group-names "$SECURITY_GROUP_NAME" \
        --region "$AWS_REGION" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_SG_ID" ] && [ "$EXISTING_SG_ID" != "" ] && [ "$EXISTING_SG_ID" != "None" ]; then
        echo -e "${YELLOW}⚠️  Security group already exists: $EXISTING_SG_ID${NC}"
        SECURITY_GROUP_ID="$EXISTING_SG_ID"
    else
        echo "Creating new security group: $SECURITY_GROUP_NAME"
        SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name "$SECURITY_GROUP_NAME" \
            --description "Production RNN-T Transcription Server" \
            --region "$AWS_REGION" \
            --query 'GroupId' \
            --output text)
    fi
    
    echo -e "${GREEN}✅ Security group ready: $SECURITY_GROUP_ID${NC}"
    
    # Check and add SSH rule if not exists
    echo "Checking SSH access rule..."
    if ! aws ec2 describe-security-group-rules \
        --group-ids "$SECURITY_GROUP_ID" \
        --region "$AWS_REGION" \
        --query "SecurityGroupRules[?FromPort==\`22\`]" \
        --output text 2>/dev/null | grep -q "22"; then
        echo "Adding SSH access rule..."
        aws ec2 authorize-security-group-ingress \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region "$AWS_REGION" 2>/dev/null || echo "   SSH rule may already exist"
    else
        echo "   SSH rule already exists"
    fi
    
    # Check and add RNN-T server rule if not exists
    echo "Checking RNN-T server access rule (port 8000)..."
    if ! aws ec2 describe-security-group-rules \
        --group-ids "$SECURITY_GROUP_ID" \
        --region "$AWS_REGION" \
        --query "SecurityGroupRules[?FromPort==\`8000\`]" \
        --output text 2>/dev/null | grep -q "8000"; then
        echo "Adding RNN-T server access rule (port 8000)..."
        aws ec2 authorize-security-group-ingress \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port 8000 \
            --cidr 0.0.0.0/0 \
            --region "$AWS_REGION" 2>/dev/null || echo "   RNN-T rule may already exist"
    else
        echo "   RNN-T rule already exists"
    fi
    
    # Update .env file
    sed -i "s/SECURITY_GROUP_ID=\".*\"/SECURITY_GROUP_ID=\"$SECURITY_GROUP_ID\"/" "$ENV_FILE"
    sed -i "s/SECURITY_GROUP_NAME=\".*\"/SECURITY_GROUP_NAME=\"$SECURITY_GROUP_NAME\"/" "$ENV_FILE"
else
    echo -e "${YELLOW}⚠️  Using existing security group: $SECURITY_GROUP_ID${NC}"
fi

# Step 3: Get latest Deep Learning AMI
echo -e "${GREEN}=== Step 3: Finding Deep Learning AMI ===${NC}"
echo "Looking for latest Deep Learning AMI..."

AMI_ID=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners amazon \
    --filters "Name=name,Values=Deep Learning AMI GPU PyTorch*Ubuntu*" \
              "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)

if [ "$AMI_ID" = "None" ] || [ -z "$AMI_ID" ]; then
    echo -e "${YELLOW}⚠️  Deep Learning AMI not found, using Ubuntu 22.04${NC}"
    AMI_ID=$(aws ec2 describe-images \
        --region "$AWS_REGION" \
        --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
                  "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text)
fi

echo -e "${GREEN}✅ Using AMI: $AMI_ID${NC}"

# Step 4: Launch GPU Instance
echo -e "${GREEN}=== Step 4: Launching GPU Instance ===${NC}"

# Check if instance already exists
if [ -n "$GPU_INSTANCE_ID" ] && [ "$GPU_INSTANCE_ID" != "" ]; then
    echo -e "${YELLOW}⚠️  Instance already exists: $GPU_INSTANCE_ID${NC}"
    
    # Check instance state
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "not-found")
    
    if [ "$INSTANCE_STATE" = "not-found" ]; then
        echo -e "${YELLOW}⚠️  Instance not found, creating new one${NC}"
        GPU_INSTANCE_ID=""
    else
        echo "Instance state: $INSTANCE_STATE"
        
        if [ "$INSTANCE_STATE" = "stopped" ]; then
            echo "Starting existing instance..."
            aws ec2 start-instances \
                --instance-ids "$GPU_INSTANCE_ID" \
                --region "$AWS_REGION"
            
            wait_for_instance_state "$GPU_INSTANCE_ID" "running"
        fi
    fi
fi

if [ -z "$GPU_INSTANCE_ID" ] || [ "$GPU_INSTANCE_ID" = "" ]; then
    echo "Launching new $GPU_INSTANCE_TYPE instance..."
    
    # Create user data script for initial setup
    USER_DATA=$(cat <<'EOF'
#!/bin/bash
apt-get update
apt-get install -y python3-pip python3-venv awscli
pip3 install --upgrade pip

# Install NVIDIA drivers if needed
if command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA drivers already installed"
else
    echo "Installing NVIDIA drivers..."
    apt-get install -y ubuntu-drivers-common
    ubuntu-drivers autoinstall
fi

# Create app directory
mkdir -p /opt/rnnt
chown ubuntu:ubuntu /opt/rnnt
EOF
)
    
    # Generate unique instance name with readable timestamp format
    # Format: rnnt-gpu-MM-DD-YY-HHMM (e.g., rnnt-gpu-08-31-25-1430)
    TIMESTAMP=$(date +"%m-%d-%y-%H%M")
    BASE_INSTANCE_NAME="rnnt-gpu"
    FULL_INSTANCE_NAME="${BASE_INSTANCE_NAME}-${TIMESTAMP}"
    echo "Instance name: $FULL_INSTANCE_NAME"
    
    # Update .env file with the full instance name
    sed -i "s/INSTANCE_NAME=\".*\"/INSTANCE_NAME=\"$FULL_INSTANCE_NAME\"/" "$ENV_FILE"
    
    GPU_INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --count 1 \
        --instance-type "$GPU_INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SECURITY_GROUP_ID" \
        --region "$AWS_REGION" \
        --user-data "$USER_DATA" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$FULL_INSTANCE_NAME},{Key=Purpose,Value=speech-transcription}]" \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    echo -e "${GREEN}✅ Instance launched: $GPU_INSTANCE_ID${NC}"
    
    # Update .env file
    sed -i "s/GPU_INSTANCE_ID=\".*\"/GPU_INSTANCE_ID=\"$GPU_INSTANCE_ID\"/" "$ENV_FILE"
    
    # Wait for instance to be running
    wait_for_instance_state "$GPU_INSTANCE_ID" "running"
fi

# Step 5: Get Instance IP
echo -e "${GREEN}=== Step 5: Getting Instance IP ===${NC}"
GPU_INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

if [ "$GPU_INSTANCE_IP" = "None" ] || [ -z "$GPU_INSTANCE_IP" ]; then
    echo -e "${RED}❌ Could not get instance IP address${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Instance IP: $GPU_INSTANCE_IP${NC}"

# Update .env file
sed -i "s/GPU_INSTANCE_IP=\".*\"/GPU_INSTANCE_IP=\"$GPU_INSTANCE_IP\"/" "$ENV_FILE"

# Step 6: Wait for SSH access
echo -e "${GREEN}=== Step 6: Waiting for SSH Access ===${NC}"
echo -e "${YELLOW}⏳ Waiting for SSH to become available...${NC}"

SSH_READY=false
MAX_ATTEMPTS=30
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ] && [ "$SSH_READY" = "false" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    echo "   SSH attempt $ATTEMPT/$MAX_ATTEMPTS..."
    
    if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
           ubuntu@"$GPU_INSTANCE_IP" "echo 'SSH is ready'" >/dev/null 2>&1; then
        SSH_READY=true
        echo -e "${GREEN}✅ SSH access confirmed${NC}"
    else
        sleep 10
    fi
done

if [ "$SSH_READY" = "false" ]; then
    echo -e "${RED}❌ SSH access not available after $MAX_ATTEMPTS attempts${NC}"
    exit 1
fi

# Final summary
echo ""
echo -e "${GREEN}🎉 GPU Instance Deployment Complete!${NC}"
echo "================================================================"
echo "Instance ID: $GPU_INSTANCE_ID"
echo "Instance Type: $GPU_INSTANCE_TYPE"
echo "Public IP: $GPU_INSTANCE_IP"
echo "SSH Key: $SSH_KEY_FILE"
echo ""
echo -e "${BLUE}🔌 Test SSH Connection:${NC}"
echo "   ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP"
echo ""
echo -e "${YELLOW}📜 Next Steps:${NC}"
echo ""
echo -e "${RED}IMPORTANT - Run this first to enable worker S3 access:${NC}"
echo "1. Run: ./scripts/step-015-enable-worker-s3-access.sh"
echo "   ${BLUE}(Enables EC2 worker to access S3 bucket securely via IAM role)${NC}"
echo ""
echo -e "${GREEN}Then choose your deployment method:${NC}"
echo "2. Run: ./scripts/step-020-choose-deployment-method.sh"
echo "   ${BLUE}(Interactive menu to choose between Direct Install or Docker)${NC}"
echo ""
echo -e "${YELLOW}The choice script will guide you through:${NC}"
echo "   • Direct Installation (faster, easier debugging)"
echo "   • Docker Container (isolated, production-ready)"
echo "   • Automatic progression to testing and WebSocket setup"
echo ""

# Update environment with completion timestamp
COMPLETION_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sed -i "s/INSTANCE_DEPLOYED=\".*\"/INSTANCE_DEPLOYED=\"$COMPLETION_TIME\"/" "$ENV_FILE"