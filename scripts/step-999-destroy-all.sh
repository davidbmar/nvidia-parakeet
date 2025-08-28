#!/bin/bash
set -e

# Production RNN-T Deployment - Step 999: Destroy All Resources
# This script safely removes all AWS resources created by the deployment
# IMPORTANT: S3 buckets are NOT destroyed to protect your data

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

echo -e "${RED}🗑️  Production RNN-T Deployment - Resource Cleanup${NC}"
echo "================================================================"
echo -e "${YELLOW}⚠️  WARNING: This will destroy AWS resources created by this deployment${NC}"
echo -e "${GREEN}✅ SAFE: S3 buckets will NOT be deleted${NC}"
echo ""

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Nothing to clean up."
    exit 0
fi

# Load configuration
source "$ENV_FILE"

# Function to check if resource exists
check_resource_exists() {
    local resource_type="$1"
    local resource_id="$2"
    
    if [ -z "$resource_id" ] || [ "$resource_id" = "" ]; then
        return 1
    fi
    
    case "$resource_type" in
        "instance")
            aws ec2 describe-instances \
                --instance-ids "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "security-group")
            aws ec2 describe-security-groups \
                --group-ids "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "key-pair")
            aws ec2 describe-key-pairs \
                --key-names "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
    
    return $?
}

# Collect all resources
echo -e "${BLUE}📋 Discovering resources from configuration...${NC}"
echo ""

RESOURCES_FOUND=false

echo -e "${CYAN}=== Resources Found ===${NC}"
echo ""

# EC2 Instance
if [ -n "$GPU_INSTANCE_ID" ] && [ "$GPU_INSTANCE_ID" != "" ]; then
    if check_resource_exists "instance" "$GPU_INSTANCE_ID"; then
        INSTANCE_STATE=$(aws ec2 describe-instances \
            --instance-ids "$GPU_INSTANCE_ID" \
            --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text 2>/dev/null)
        echo -e "${YELLOW}📦 EC2 Instance:${NC}"
        echo "   • ID: $GPU_INSTANCE_ID"
        echo "   • Type: $GPU_INSTANCE_TYPE"
        echo "   • State: $INSTANCE_STATE"
        echo "   • Public IP: ${GPU_INSTANCE_IP:-'N/A'}"
        echo ""
        RESOURCES_FOUND=true
    fi
fi

# Security Group
if [ -n "$SECURITY_GROUP_ID" ] && [ "$SECURITY_GROUP_ID" != "" ]; then
    if check_resource_exists "security-group" "$SECURITY_GROUP_ID"; then
        echo -e "${YELLOW}🔒 Security Group:${NC}"
        echo "   • ID: $SECURITY_GROUP_ID"
        echo "   • Name: $SECURITY_GROUP_NAME"
        echo ""
        RESOURCES_FOUND=true
    fi
fi

# Key Pair
if [ -n "$KEY_NAME" ] && [ "$KEY_NAME" != "" ]; then
    if check_resource_exists "key-pair" "$KEY_NAME"; then
        echo -e "${YELLOW}🔑 SSH Key Pair:${NC}"
        echo "   • Name: $KEY_NAME"
        echo "   • Local File: ${SSH_KEY_FILE:-'Not found'}"
        echo ""
        RESOURCES_FOUND=true
    fi
fi

# S3 Bucket (display only, won't delete)
if [ -n "$AUDIO_BUCKET" ] && [ "$AUDIO_BUCKET" != "" ]; then
    if aws s3api head-bucket --bucket "$AUDIO_BUCKET" 2>/dev/null; then
        echo -e "${GREEN}💾 S3 Bucket (WILL NOT BE DELETED):${NC}"
        echo "   • Name: $AUDIO_BUCKET"
        echo "   • Status: Protected from deletion"
        echo ""
    fi
fi

# Lambda Function (if configured)
if [ -n "$LAMBDA_FUNCTION_NAME" ] && [ "$LAMBDA_FUNCTION_NAME" != "" ]; then
    if aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" --region "$AWS_REGION" &>/dev/null; then
        echo -e "${YELLOW}⚡ Lambda Function:${NC}"
        echo "   • Name: $LAMBDA_FUNCTION_NAME"
        echo ""
        RESOURCES_FOUND=true
    fi
fi

# SQS Queue (if configured)
if [ -n "$SQS_QUEUE_URL" ] && [ "$SQS_QUEUE_URL" != "" ]; then
    if aws sqs get-queue-attributes --queue-url "$SQS_QUEUE_URL" --region "$AWS_REGION" &>/dev/null; then
        QUEUE_NAME=$(echo "$SQS_QUEUE_URL" | rev | cut -d'/' -f1 | rev)
        echo -e "${YELLOW}📨 SQS Queue:${NC}"
        echo "   • Name: $QUEUE_NAME"
        echo "   • URL: $SQS_QUEUE_URL"
        echo ""
        RESOURCES_FOUND=true
    fi
fi

if [ "$RESOURCES_FOUND" = false ]; then
    echo -e "${GREEN}✅ No active resources found to clean up.${NC}"
    exit 0
fi

# Confirmation prompt
echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
echo -e "${RED}⚠️  DESTRUCTIVE ACTION WARNING ⚠️${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}This will permanently destroy the above resources.${NC}"
echo -e "${GREEN}Note: S3 buckets will be preserved.${NC}"
echo ""
read -p "Type 'DESTROY' to confirm deletion: " confirmation

if [ "$confirmation" != "DESTROY" ]; then
    echo -e "${BLUE}❌ Cleanup cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${RED}🗑️  Starting resource cleanup...${NC}"
echo ""

# Function to safely delete resource
delete_resource() {
    local resource_type="$1"
    local resource_id="$2"
    local resource_name="$3"
    
    echo -n "   Deleting $resource_name..."
    
    case "$resource_type" in
        "instance")
            # First terminate the instance
            aws ec2 terminate-instances \
                --instance-ids "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            
            # Wait for termination
            aws ec2 wait instance-terminated \
                --instance-ids "$resource_id" \
                --region "$AWS_REGION" 2>/dev/null
            ;;
        "security-group")
            # Small delay to ensure instance is fully terminated
            sleep 5
            aws ec2 delete-security-group \
                --group-id "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "key-pair")
            aws ec2 delete-key-pairs \
                --key-names "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "lambda")
            aws lambda delete-function \
                --function-name "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
        "sqs")
            aws sqs delete-queue \
                --queue-url "$resource_id" \
                --region "$AWS_REGION" \
                --output text &>/dev/null
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        echo -e " ${GREEN}✅${NC}"
    else
        echo -e " ${RED}❌ Failed${NC}"
    fi
}

# Delete EC2 Instance first
if [ -n "$GPU_INSTANCE_ID" ] && [ "$GPU_INSTANCE_ID" != "" ]; then
    if check_resource_exists "instance" "$GPU_INSTANCE_ID"; then
        echo -e "${YELLOW}1. Terminating EC2 Instance${NC}"
        delete_resource "instance" "$GPU_INSTANCE_ID" "EC2 Instance $GPU_INSTANCE_ID"
        echo ""
    fi
fi

# Delete Lambda Function
if [ -n "$LAMBDA_FUNCTION_NAME" ] && [ "$LAMBDA_FUNCTION_NAME" != "" ]; then
    if aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" --region "$AWS_REGION" &>/dev/null; then
        echo -e "${YELLOW}2. Deleting Lambda Function${NC}"
        delete_resource "lambda" "$LAMBDA_FUNCTION_NAME" "Lambda $LAMBDA_FUNCTION_NAME"
        echo ""
    fi
fi

# Delete SQS Queue
if [ -n "$SQS_QUEUE_URL" ] && [ "$SQS_QUEUE_URL" != "" ]; then
    if aws sqs get-queue-attributes --queue-url "$SQS_QUEUE_URL" --region "$AWS_REGION" &>/dev/null; then
        echo -e "${YELLOW}3. Deleting SQS Queue${NC}"
        delete_resource "sqs" "$SQS_QUEUE_URL" "SQS Queue"
        echo ""
    fi
fi

# Delete Security Group (after instance is terminated)
if [ -n "$SECURITY_GROUP_ID" ] && [ "$SECURITY_GROUP_ID" != "" ]; then
    if check_resource_exists "security-group" "$SECURITY_GROUP_ID"; then
        echo -e "${YELLOW}4. Deleting Security Group${NC}"
        delete_resource "security-group" "$SECURITY_GROUP_ID" "Security Group $SECURITY_GROUP_ID"
        echo ""
    fi
fi

# Delete Key Pair
if [ -n "$KEY_NAME" ] && [ "$KEY_NAME" != "" ]; then
    if check_resource_exists "key-pair" "$KEY_NAME"; then
        echo -e "${YELLOW}5. Deleting Key Pair${NC}"
        delete_resource "key-pair" "$KEY_NAME" "Key Pair $KEY_NAME"
        echo ""
    fi
fi

# Clean up local SSH key file
if [ -n "$SSH_KEY_FILE" ] && [ -f "$SSH_KEY_FILE" ]; then
    echo -e "${YELLOW}6. Removing local SSH key file${NC}"
    echo -n "   Deleting $SSH_KEY_FILE..."
    rm -f "$SSH_KEY_FILE"
    echo -e " ${GREEN}✅${NC}"
    echo ""
fi

# Clear .env file entries
echo -e "${YELLOW}7. Clearing configuration${NC}"
echo -n "   Resetting .env file..."
sed -i 's/GPU_INSTANCE_ID=".*"/GPU_INSTANCE_ID=""/' "$ENV_FILE"
sed -i 's/GPU_INSTANCE_IP=".*"/GPU_INSTANCE_IP=""/' "$ENV_FILE"
sed -i 's/SECURITY_GROUP_ID=".*"/SECURITY_GROUP_ID=""/' "$ENV_FILE"
sed -i 's/SSH_KEY_FILE=".*"/SSH_KEY_FILE=""/' "$ENV_FILE"
sed -i 's/SQS_QUEUE_URL=".*"/SQS_QUEUE_URL=""/' "$ENV_FILE"
sed -i 's/DEPLOYMENT_TIMESTAMP=".*"/DEPLOYMENT_TIMESTAMP=""/' "$ENV_FILE"
sed -i 's/CONFIG_VALIDATION_PASSED=".*"/CONFIG_VALIDATION_PASSED=""/' "$ENV_FILE"
echo -e " ${GREEN}✅${NC}"
echo ""

# Summary
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ Cleanup Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "Resources have been destroyed."
echo "Your S3 bucket ($AUDIO_BUCKET) has been preserved."
echo ""
echo -e "${BLUE}To deploy again, run:${NC}"
echo "   ./scripts/step-010-deploy-gpu-instance.sh"
echo ""