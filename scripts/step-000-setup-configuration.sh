#!/bin/bash
set -e

# Production RNN-T Deployment - Step 0: Configuration Setup
# This script creates the .env configuration file from user input

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$PROJECT_ROOT/config"
ENV_FILE="$PROJECT_ROOT/.env"
TEMPLATE_FILE="$CONFIG_DIR/.env.template"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Production RNN-T Deployment - Configuration Setup${NC}"
echo "================================================================"
echo "This script will set up your .env configuration file."
echo "You'll need:"
echo "  • AWS Account ID and region"  
echo "  • S3 bucket name for audio storage (optional)"
echo "  • Desired GPU instance type"
echo ""

# Function to prompt for input with default
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local secret="${4:-false}"
    
    if [ "$secret" = "true" ]; then
        echo -n -e "${YELLOW}$prompt${NC}"
        [ -n "$default" ] && echo -n " [$default]"
        echo -n ": "
        read -s value
        echo ""  # New line after hidden input
    else
        echo -n -e "${YELLOW}$prompt${NC}"
        [ -n "$default" ] && echo -n " [$default]"
        echo -n ": "
        read value
    fi
    
    if [ -z "$value" ] && [ -n "$default" ]; then
        value="$default"
    fi
    
    eval "$var_name='$value'"
}

# Function to validate AWS account ID
validate_aws_account_id() {
    if [[ ! $1 =~ ^[0-9]{12}$ ]]; then
        echo -e "${RED}❌ Invalid AWS Account ID. Must be 12 digits.${NC}"
        return 1
    fi
    return 0
}

# Check if template exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${RED}❌ Template file not found: $TEMPLATE_FILE${NC}"
    exit 1
fi

# Check if .env already exists
if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}⚠️  Configuration file already exists: $ENV_FILE${NC}"
    echo -n "Do you want to overwrite it? [y/N]: "
    read overwrite
    if [[ ! $overwrite =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

echo -e "${BLUE}📋 Please provide the following information:${NC}"
echo ""

# AWS Configuration
echo -e "${GREEN}=== AWS Configuration ===${NC}"
prompt_with_default "AWS Region" "us-east-2" AWS_REGION
prompt_with_default "AWS Account ID (12 digits)" "" AWS_ACCOUNT_ID

# Validate AWS Account ID
while ! validate_aws_account_id "$AWS_ACCOUNT_ID"; do
    prompt_with_default "AWS Account ID (12 digits)" "" AWS_ACCOUNT_ID
done

prompt_with_default "S3 Bucket for audio files (optional)" "" AUDIO_BUCKET

echo ""

# GPU Instance Configuration
echo -e "${GREEN}=== GPU Instance Configuration ===${NC}"
echo "Recommended instance types:"
echo "  • g4dn.xlarge  - Tesla T4, 4 vCPU, 16GB RAM (most cost-effective)"
echo "  • g4dn.2xlarge - Tesla T4, 8 vCPU, 32GB RAM (better performance)"
echo "  • p3.2xlarge   - Tesla V100, 8 vCPU, 61GB RAM (highest performance)"
echo ""
prompt_with_default "GPU Instance Type" "g4dn.xlarge" GPU_INSTANCE_TYPE

echo ""

# Optional Configuration
echo -e "${GREEN}=== Optional Configuration ===${NC}"
prompt_with_default "Development mode (enables API docs)" "false" DEV_MODE
prompt_with_default "Log level (DEBUG/INFO/WARNING/ERROR)" "INFO" LOG_LEVEL

echo ""

# Generate timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Create .env file from template
echo -e "${BLUE}📝 Creating configuration file...${NC}"

# Copy template and replace values
cp "$TEMPLATE_FILE" "$ENV_FILE"

# Replace template values with actual values
sed -i "s/AWS_REGION=\".*\"/AWS_REGION=\"$AWS_REGION\"/" "$ENV_FILE"
sed -i "s/AWS_ACCOUNT_ID=\".*\"/AWS_ACCOUNT_ID=\"$AWS_ACCOUNT_ID\"/" "$ENV_FILE"
sed -i "s/AUDIO_BUCKET=\".*\"/AUDIO_BUCKET=\"$AUDIO_BUCKET\"/" "$ENV_FILE"
sed -i "s/GPU_INSTANCE_TYPE=\".*\"/GPU_INSTANCE_TYPE=\"$GPU_INSTANCE_TYPE\"/" "$ENV_FILE"
sed -i "s/DEV_MODE=\".*\"/DEV_MODE=\"$DEV_MODE\"/" "$ENV_FILE"
sed -i "s/LOG_LEVEL=\".*\"/LOG_LEVEL=\"$LOG_LEVEL\"/" "$ENV_FILE"
sed -i "s/DEPLOYMENT_TIMESTAMP=\".*\"/DEPLOYMENT_TIMESTAMP=\"$TIMESTAMP\"/" "$ENV_FILE"

# Mark configuration as validated
sed -i "s/CONFIG_VALIDATION_PASSED=\".*\"/CONFIG_VALIDATION_PASSED=\"true\"/" "$ENV_FILE"

# Set proper permissions
chmod 600 "$ENV_FILE"

echo -e "${GREEN}✅ Configuration file created: $ENV_FILE${NC}"
echo ""
echo -e "${BLUE}📋 Configuration Summary:${NC}"
echo "  • AWS Region: $AWS_REGION"
echo "  • AWS Account: $AWS_ACCOUNT_ID"
echo "  • Audio Bucket: ${AUDIO_BUCKET:-'(not configured)'}"
echo "  • Instance Type: $GPU_INSTANCE_TYPE"
echo "  • Development Mode: $DEV_MODE"
echo "  • Log Level: $LOG_LEVEL"
echo ""

echo -e "${GREEN}🎯 Next Steps:${NC}"
echo "1. Run: ./scripts/step-010-deploy-gpu-instance.sh"
echo "2. Run: ./scripts/step-020-install-rnnt-server.sh"
echo "3. Run: ./scripts/step-030-test-system.sh"
echo ""
echo -e "${BLUE}⚠️  Security Note:${NC}"
echo "• The .env file contains sensitive configuration"
echo "• It's already excluded from git (check .gitignore)"
echo "• Keep this file secure and don't share it"
echo ""

# Show next step
echo -e "${YELLOW}📜 Ready to deploy! Run the next script:${NC}"
echo "   ./scripts/step-010-deploy-gpu-instance.sh"