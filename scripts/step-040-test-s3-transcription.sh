#!/bin/bash
set -e

# Production RNN-T Deployment - Step 4.0: Test S3 Audio Transcription  
# This script tests transcription with the specific S3 audio file

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Test audio file
S3_TEST_AUDIO="s3://dbm-cf-2-web/users/01ebc530-5041-7042-936c-6e516c3a0d20/audio/sessions/1b3fd9db-dfb0-4360-913f-7096d62c1b0a/chunk-002.wav"

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

echo -e "${BLUE}🚀 Production RNN-T Deployment - S3 Audio Transcription Test${NC}"
echo "================================================================"
echo "Target Server: http://$GPU_INSTANCE_IP:8000"
echo "Test Audio: $S3_TEST_AUDIO"
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

# Step 1: Verify server is running
echo -e "${GREEN}=== Step 1: Verifying Server Status ===${NC}"
HEALTH_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "curl -s --connect-timeout 10 http://localhost:8000/health 2>/dev/null || echo 'failed'")

if [[ "$HEALTH_RESPONSE" != *"healthy"* ]]; then
    echo -e "${RED}❌ Server not healthy: $HEALTH_RESPONSE${NC}"
    echo "Run: ./scripts/step-035-verify-rnnt-model.sh first"
    exit 1
fi

echo -e "${GREEN}✅ Server is healthy and ready${NC}"

# Step 2: Check AWS credentials on the instance
echo -e "${GREEN}=== Step 2: Checking AWS Configuration ===${NC}"
AWS_CHECK=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "aws sts get-caller-identity 2>/dev/null || echo 'no-aws-creds'")

if [[ "$AWS_CHECK" == *"no-aws-creds"* ]]; then
    echo -e "${YELLOW}⚠️  AWS credentials not configured on instance${NC}"
    echo "Setting up temporary AWS credentials access..."
    
    # Check if AWS credentials exist locally
    if [ -f ~/.aws/credentials ]; then
        echo -e "${BLUE}📋 Copying AWS credentials to instance...${NC}"
        ssh_cmd "mkdir -p ~/.aws"
        scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ~/.aws/credentials ubuntu@"$GPU_INSTANCE_IP":~/.aws/credentials 2>/dev/null || true
        scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ~/.aws/config ubuntu@"$GPU_INSTANCE_IP":~/.aws/config 2>/dev/null || true
    else
        echo -e "${RED}❌ No AWS credentials found locally${NC}"
        echo "Please configure AWS credentials with: aws configure"
        exit 1
    fi
else
    echo -e "${GREEN}✅ AWS credentials configured${NC}"
fi

# Step 3: Test S3 access from instance
echo -e "${GREEN}=== Step 3: Testing S3 Access ===${NC}"
S3_ACCESS_TEST=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "aws s3 ls '$S3_TEST_AUDIO' 2>/dev/null || echo 'access-failed'")

if [[ "$S3_ACCESS_TEST" == *"access-failed"* ]]; then
    echo -e "${RED}❌ Cannot access S3 file: $S3_TEST_AUDIO${NC}"
    echo "Check AWS permissions and file existence"
    exit 1
fi

echo -e "${GREEN}✅ S3 file accessible: $S3_ACCESS_TEST${NC}"

# Step 4: Test S3 transcription endpoint
echo -e "${GREEN}=== Step 4: Testing S3 Transcription Endpoint ===${NC}"
echo -e "${YELLOW}⏳ Sending S3 transcription request...${NC}"
echo "This may take 30-60 seconds depending on audio length..."

# Create transcription request
TRANSCRIPTION_REQUEST='{
    "s3_uri": "'"$S3_TEST_AUDIO"'",
    "language": "en-US"
}'

echo "Request payload: $TRANSCRIPTION_REQUEST"

# Send transcription request with timeout
TRANSCRIPTION_START=$(date +%s)
TRANSCRIPTION_RESPONSE=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" "
curl -X POST 'http://localhost:8000/transcribe/s3' \\
     -H 'Content-Type: application/json' \\
     -d '$TRANSCRIPTION_REQUEST' \\
     --connect-timeout 30 \\
     --max-time 120 \\
     -s 2>/dev/null || echo 'transcription-failed'
")
TRANSCRIPTION_END=$(date +%s)
TRANSCRIPTION_TIME=$((TRANSCRIPTION_END - TRANSCRIPTION_START))

echo ""
echo -e "${BLUE}📊 Transcription completed in ${TRANSCRIPTION_TIME}s${NC}"
echo ""

# Step 5: Analyze transcription results
echo -e "${GREEN}=== Step 5: Analyzing Transcription Results ===${NC}"

if [[ "$TRANSCRIPTION_RESPONSE" == *"transcription-failed"* ]]; then
    echo -e "${RED}❌ Transcription request failed${NC}"
    echo "Response: $TRANSCRIPTION_RESPONSE"
    
    # Check container logs for errors
    echo ""
    echo "Checking container logs for errors..."
    ssh_cmd "docker logs --tail 20 rnnt-server"
    exit 1
fi

# Check if response contains actual transcription
if [[ "$TRANSCRIPTION_RESPONSE" == *"\"text\":"* ]] && [[ "$TRANSCRIPTION_RESPONSE" == *"actual_transcription\":true"* ]]; then
    echo -e "${GREEN}✅ Transcription successful!${NC}"
    
    # Pretty print the JSON response
    echo -e "${BLUE}📝 Transcription Results:${NC}"
    echo "$TRANSCRIPTION_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$TRANSCRIPTION_RESPONSE"
    
    # Extract key information
    TRANSCRIBED_TEXT=$(echo "$TRANSCRIPTION_RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(f\"Text: {data.get('text', 'N/A')}\")
    print(f\"Confidence: {data.get('confidence', 'N/A')}\")
    print(f\"Processing Time: {data.get('processing_time_ms', 'N/A')}ms\")
    print(f\"Audio Duration: {data.get('audio_duration_s', 'N/A')}s\")
    print(f\"Real-time Factor: {data.get('real_time_factor', 'N/A')}\")
    print(f\"GPU Accelerated: {data.get('gpu_accelerated', 'N/A')}\")
    word_count = len(data.get('words', []))
    print(f\"Words with timestamps: {word_count}\")
except:
    print('Could not parse JSON response')
" 2>/dev/null)
    
    echo ""
    echo -e "${BLUE}📊 Summary:${NC}"
    echo "$TRANSCRIBED_TEXT"
    
else
    echo -e "${RED}❌ Invalid transcription response${NC}"
    echo "Response: $TRANSCRIPTION_RESPONSE"
    exit 1
fi

# Step 6: Save results
echo -e "${GREEN}=== Step 6: Saving Results ===${NC}"
RESULTS_DIR="$PROJECT_ROOT/results"
mkdir -p "$RESULTS_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_FILE="$RESULTS_DIR/transcription_test_$TIMESTAMP.json"

echo "$TRANSCRIPTION_RESPONSE" | python3 -m json.tool > "$RESULTS_FILE" 2>/dev/null || echo "$TRANSCRIPTION_RESPONSE" > "$RESULTS_FILE"

echo -e "${GREEN}✅ Results saved to: $RESULTS_FILE${NC}"

# Step 7: Performance metrics
echo -e "${GREEN}=== Step 7: Performance Analysis ===${NC}"
echo -e "${BLUE}🎯 Performance Metrics:${NC}"
echo "• Total request time: ${TRANSCRIPTION_TIME}s"
echo "• S3 audio file: $S3_TEST_AUDIO"
echo "• Architecture: SpeechBrain Conformer RNN-T"  
echo "• GPU accelerated: $(echo "$TRANSCRIPTION_RESPONSE" | grep -o '\"gpu_accelerated\":[^,}]*' | cut -d':' -f2 || echo 'unknown')"

echo ""
echo -e "${GREEN}🎉 S3 Audio Transcription Test Complete!${NC}"
echo "================================================================"
echo -e "${GREEN}✅ Server is operational${NC}"
echo -e "${GREEN}✅ S3 access working${NC}"
echo -e "${GREEN}✅ RNN-T transcription successful${NC}"
echo -e "${GREEN}✅ Results saved locally${NC}"
echo ""
echo -e "${BLUE}🎯 Ready for production use!${NC}"
echo "• API endpoint: http://$GPU_INSTANCE_IP:8000/transcribe/s3"
echo "• Results file: $RESULTS_FILE" 
echo ""
echo -e "${YELLOW}📜 Next Steps:${NC}"
echo "1. Review transcription accuracy in $RESULTS_FILE"
echo "2. Test with additional audio files"
echo "3. Monitor GPU utilization and performance"
echo ""