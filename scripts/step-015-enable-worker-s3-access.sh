#!/bin/bash
set -e

# Production RNN-T Deployment - Step 1.5: Enable Worker S3 Access
# This script creates an IAM role that allows the EC2 worker instance to access
# the S3 bucket securely without storing AWS credentials on the instance

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
required_vars=("AWS_REGION" "AWS_ACCOUNT_ID" "AUDIO_BUCKET" "GPU_INSTANCE_ID")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}❌ Required variable $var not set in $ENV_FILE${NC}"
        exit 1
    fi
done

echo -e "${BLUE}🚀 Production RNN-T Deployment - Enable Worker S3 Access${NC}"
echo "================================================================"
echo "AWS Region: $AWS_REGION"
echo "Account ID: $AWS_ACCOUNT_ID"
echo "S3 Bucket: $AUDIO_BUCKET"
echo "Instance ID: $GPU_INSTANCE_ID"
echo ""

# Define role and policy names
IAM_ROLE_NAME="${IAM_ROLE_NAME:-rnnt-s3-access-role}"
IAM_POLICY_NAME="${IAM_POLICY_NAME:-rnnt-s3-read-policy}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-rnnt-instance-profile}"

echo -e "${GREEN}=== Step 1: Creating IAM Role ===${NC}"

# Check if role already exists (IAM is global, no region needed)
if aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  IAM role already exists: $IAM_ROLE_NAME${NC}"
    ROLE_EXISTS=true
else
    echo "Creating IAM role: $IAM_ROLE_NAME"
    
    # Create trust policy for EC2
    TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)
    
    # Create the role
    aws iam create-role \
        --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --description "Role for RNN-T instances to access S3 model bucket" >/dev/null
    
    echo -e "${GREEN}✅ IAM role created${NC}"
    ROLE_EXISTS=false
fi

echo -e "${GREEN}=== Step 2: Creating IAM Policy ===${NC}"

# Check if policy exists
POLICY_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:policy/$IAM_POLICY_NAME"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  IAM policy already exists: $IAM_POLICY_NAME${NC}"
    POLICY_EXISTS=true
else
    echo "Creating IAM policy for S3 bucket access: $AUDIO_BUCKET"
    
    # Create policy for S3 access (read-only to specific bucket)
    S3_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${AUDIO_BUCKET}",
        "arn:aws:s3:::${AUDIO_BUCKET}/*"
      ]
    }
  ]
}
EOF
)
    
    # Create the policy
    POLICY_ARN=$(aws iam create-policy \
        --policy-name "$IAM_POLICY_NAME" \
        --policy-document "$S3_POLICY" \
        --description "Read access to RNN-T model bucket ($AUDIO_BUCKET)" \
        --query 'Policy.Arn' \
        --output text)
    
    echo -e "${GREEN}✅ IAM policy created${NC}"
    POLICY_EXISTS=false
fi

# Attach policy to role
echo -e "${GREEN}=== Step 3: Attaching Policy to Role ===${NC}"

# Check if policy is already attached
ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
    --role-name "$IAM_ROLE_NAME" \
    --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyArn" \
    --output text)

if [ -n "$ATTACHED_POLICIES" ]; then
    echo -e "${YELLOW}⚠️  Policy already attached to role${NC}"
else
    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "$POLICY_ARN"
    
    echo -e "${GREEN}✅ Policy attached to role${NC}"
fi

echo -e "${GREEN}=== Step 4: Creating Instance Profile ===${NC}"

# Create instance profile if it doesn't exist
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Instance profile already exists: $INSTANCE_PROFILE_NAME${NC}"
else
    echo "Creating instance profile: $INSTANCE_PROFILE_NAME"
    
    # Create instance profile
    aws iam create-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
    
    echo -e "${GREEN}✅ Instance profile created${NC}"
fi

# Check if role is in instance profile
PROFILE_ROLES=$(aws iam get-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --query "InstanceProfile.Roles[?RoleName=='$IAM_ROLE_NAME'].RoleName" \
    --output text)

if [ -n "$PROFILE_ROLES" ]; then
    echo -e "${YELLOW}⚠️  Role already in instance profile${NC}"
else
    # Add role to instance profile
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$IAM_ROLE_NAME"
    
    echo -e "${GREEN}✅ Role added to instance profile${NC}"
fi

echo -e "${GREEN}=== Step 5: Attaching IAM Role to EC2 Instance ===${NC}"

# Check if instance already has an IAM role
CURRENT_PROFILE=$(aws ec2 describe-instances \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query "Reservations[0].Instances[0].IamInstanceProfile.Arn" \
    --output text 2>/dev/null || echo "none")

if [[ "$CURRENT_PROFILE" == *"$INSTANCE_PROFILE_NAME"* ]]; then
    echo -e "${YELLOW}⚠️  Instance already has the correct IAM role attached${NC}"
elif [ "$CURRENT_PROFILE" != "none" ] && [ "$CURRENT_PROFILE" != "None" ]; then
    echo -e "${YELLOW}⚠️  Instance has a different IAM role: $CURRENT_PROFILE${NC}"
    echo "You may need to manually update or replace the role"
else
    echo "Attaching IAM role to instance: $GPU_INSTANCE_ID"
    
    # Associate IAM instance profile with the instance
    aws ec2 associate-iam-instance-profile \
        --iam-instance-profile Name="$INSTANCE_PROFILE_NAME" \
        --instance-id "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION" >/dev/null
    
    echo -e "${GREEN}✅ IAM role attached to instance${NC}"
    
    # Wait for role to be available
    echo "Waiting for IAM role to propagate (this may take up to 30 seconds)..."
    sleep 10
fi

# Update .env with IAM role information
sed -i "s/IAM_ROLE_NAME=\".*\"/IAM_ROLE_NAME=\"$IAM_ROLE_NAME\"/" "$ENV_FILE" 2>/dev/null || \
    echo "IAM_ROLE_NAME=\"$IAM_ROLE_NAME\"" >> "$ENV_FILE"
sed -i "s/INSTANCE_PROFILE_NAME=\".*\"/INSTANCE_PROFILE_NAME=\"$INSTANCE_PROFILE_NAME\"/" "$ENV_FILE" 2>/dev/null || \
    echo "INSTANCE_PROFILE_NAME=\"$INSTANCE_PROFILE_NAME\"" >> "$ENV_FILE"

# Test S3 access from the instance
echo -e "${GREEN}=== Step 6: Testing S3 Access ===${NC}"
echo "Testing S3 access from the instance..."

# SSH to instance and test S3 access
if [ -n "$SSH_KEY_FILE" ] && [ -f "$SSH_KEY_FILE" ] && [ -n "$GPU_INSTANCE_IP" ]; then
    TEST_RESULT=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
        "aws s3 ls s3://$AUDIO_BUCKET/ --region $AWS_REGION 2>&1 | head -1" 2>/dev/null || echo "failed")
    
    if [[ "$TEST_RESULT" == *"failed"* ]] || [[ "$TEST_RESULT" == *"Unable to locate credentials"* ]]; then
        echo -e "${YELLOW}⚠️  S3 access test failed. The role may need a moment to propagate.${NC}"
        echo "   Wait 30 seconds and try: aws s3 ls s3://$AUDIO_BUCKET/"
    else
        echo -e "${GREEN}✅ S3 access confirmed! Instance can access bucket: $AUDIO_BUCKET${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Cannot test S3 access (SSH not configured)${NC}"
fi

# Final summary
echo ""
echo -e "${GREEN}🎉 IAM Role Setup Complete!${NC}"
echo "================================================================"
echo "Role Name: $IAM_ROLE_NAME"
echo "Policy: $IAM_POLICY_NAME"
echo "Instance Profile: $INSTANCE_PROFILE_NAME"
echo "S3 Bucket Access: $AUDIO_BUCKET (read-only)"
echo ""
echo -e "${BLUE}🔒 Security Benefits:${NC}"
echo "• No AWS credentials stored on the instance"
echo "• Access limited to specific S3 bucket only"
echo "• Credentials automatically rotated by AWS"
echo "• Can be revoked instantly if needed"
echo ""
echo -e "${YELLOW}📜 Next Steps:${NC}"
echo "1. Run: ./scripts/step-020-install-rnnt-server.sh"
echo "   (The server will now use the IAM role for S3 access)"
echo ""