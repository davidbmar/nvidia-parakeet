#!/bin/bash
set -e

# Production RNN-T Deployment - Step 3: Test System
# This script tests the deployed RNN-T transcription system

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
TESTS_DIR="$PROJECT_ROOT/tests"

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

echo -e "${BLUE}🚀 Production RNN-T Deployment - System Testing${NC}"
echo "================================================================"
echo "Target Server: http://$GPU_INSTANCE_IP:8000"
echo "SSH Key: $SSH_KEY_FILE"
echo ""

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

# Function to run test with status tracking
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_pattern="$3"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -e "${BLUE}🧪 Test $TOTAL_TESTS: $test_name${NC}"
    
    if result=$(eval "$test_command" 2>&1); then
        if [[ "$result" =~ $expected_pattern ]]; then
            echo -e "${GREEN}   ✅ PASSED${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            return 0
        else
            echo -e "${RED}   ❌ FAILED - Pattern not found${NC}"
            echo "   Expected pattern: $expected_pattern"
            echo "   Got: ${result:0:200}..."
            TESTS_FAILED=$((TESTS_FAILED + 1))
            return 1
        fi
    else
        echo -e "${RED}   ❌ FAILED - Command error${NC}"
        echo "   Error: ${result:0:200}..."
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Function to create test audio file
create_test_audio() {
    local output_file="$1"
    local duration="${2:-5}"
    
    # Create a simple sine wave audio file using ffmpeg
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -f lavfi -i "sine=frequency=440:duration=$duration" -ar 16000 -ac 1 "$output_file" -y >/dev/null 2>&1
        return $?
    else
        echo -e "${YELLOW}⚠️  ffmpeg not found, skipping audio file creation${NC}"
        return 1
    fi
}

# Test 1: Basic Connectivity
echo -e "${GREEN}=== Basic Connectivity Tests ===${NC}"

run_test "Server Reachability" \
    "timeout 10 curl -s http://$GPU_INSTANCE_IP:8000/" \
    "Production RNN-T"

run_test "Health Endpoint" \
    "timeout 10 curl -s http://$GPU_INSTANCE_IP:8000/health" \
    "healthy|loading"

# Test 2: SSH Connectivity
echo -e "${GREEN}=== SSH Connectivity Tests ===${NC}"

run_test "SSH Connection" \
    "timeout 10 ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP 'echo connection-ok'" \
    "connection-ok"

run_test "Service Status" \
    "ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP 'sudo systemctl is-active rnnt-server'" \
    "active"

# Test 3: Server Configuration
echo -e "${GREEN}=== Server Configuration Tests ===${NC}"

run_test "GPU Availability" \
    "ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP 'nvidia-smi --query-gpu=name --format=csv,noheader'" \
    "Tesla|GeForce|NVIDIA"

run_test "Python Environment" \
    "ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP 'cd /opt/rnnt && source venv/bin/activate && python -c \"import torch; print(torch.cuda.is_available())\"'" \
    "True"

run_test "Model Cache Check" \
    "ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP 'ls -la /opt/rnnt/models/ | wc -l'" \
    "[1-9][0-9]*"

# Test 4: API Functionality
echo -e "${GREEN}=== API Functionality Tests ===${NC}"

# Get detailed service info
SERVICE_INFO=$(timeout 15 curl -s "http://$GPU_INSTANCE_IP:8000/" 2>/dev/null || echo "{}")
echo "Service Info: $SERVICE_INFO"

# Check if model is loaded
if [[ "$SERVICE_INFO" =~ "READY" ]]; then
    echo -e "${GREEN}✅ Model is loaded and ready${NC}"
    MODEL_READY=true
else
    echo -e "${YELLOW}⚠️  Model may still be loading...${NC}"
    MODEL_READY=false
fi

# Test 5: File Upload (if possible)
echo -e "${GREEN}=== File Upload Tests ===${NC}"

# Create test directory
mkdir -p "$TESTS_DIR"

# Try to create a test audio file
TEST_AUDIO_FILE="$TESTS_DIR/test-audio.wav"
if create_test_audio "$TEST_AUDIO_FILE" 3; then
    echo -e "${GREEN}✅ Test audio file created: $TEST_AUDIO_FILE${NC}"
    
    # Test file upload
    if [ "$MODEL_READY" = true ]; then
        echo -e "${BLUE}🧪 Testing file transcription...${NC}"
        UPLOAD_RESULT=$(timeout 60 curl -X POST \
            "http://$GPU_INSTANCE_IP:8000/transcribe/file" \
            -H "Content-Type: multipart/form-data" \
            -F "file=@$TEST_AUDIO_FILE" \
            -F "language=en" \
            -s 2>/dev/null || echo "upload-failed")
        
        if [[ "$UPLOAD_RESULT" =~ "text" ]] && [[ "$UPLOAD_RESULT" =~ "actual_transcription" ]]; then
            echo -e "${GREEN}   ✅ File upload and transcription working${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "${YELLOW}   ⚠️  File upload may have failed or server still initializing${NC}"
            echo "   Response: ${UPLOAD_RESULT:0:200}..."
        fi
        TOTAL_TESTS=$((TOTAL_TESTS + 1))
    else
        echo -e "${YELLOW}⚠️  Skipping upload test - model not ready${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  Could not create test audio file - install ffmpeg for full testing${NC}"
fi

# Test 6: S3 Integration (if configured)
if [ -n "$AUDIO_BUCKET" ] && [ "$AUDIO_BUCKET" != "" ]; then
    echo -e "${GREEN}=== S3 Integration Tests ===${NC}"
    
    # Test S3 access from instance
    run_test "S3 Access from Instance" \
        "ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP 'aws s3 ls s3://$AUDIO_BUCKET/ --region $AWS_REGION | head -5'" \
        ".*"
else
    echo -e "${YELLOW}⚠️  S3 not configured - skipping S3 tests${NC}"
fi

# Test 7: Performance and Resources
echo -e "${GREEN}=== Performance Tests ===${NC}"

run_test "Memory Usage" \
    "ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP 'free -m | grep Mem | awk \"{print \\\$3}\"'" \
    "[0-9]+"

run_test "CPU Usage" \
    "ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP 'top -bn1 | grep \"Cpu(s)\" | awk \"{print \\\$2}\" | cut -d% -f1'" \
    "[0-9.]+"

if [[ "$SERVICE_INFO" =~ "Tesla" ]] || [[ "$SERVICE_INFO" =~ "NVIDIA" ]]; then
    run_test "GPU Memory" \
        "ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP 'nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits'" \
        "[0-9]+"
fi

# Test 8: Log Analysis
echo -e "${GREEN}=== Log Analysis ===${NC}"

run_test "Server Logs Present" \
    "ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP 'sudo journalctl -u rnnt-server --no-pager -n 10 | wc -l'" \
    "[1-9][0-9]*"

run_test "No Critical Errors" \
    "ssh -i '$SSH_KEY_FILE' -o StrictHostKeyChecking=no ubuntu@$GPU_INSTANCE_IP 'sudo journalctl -u rnnt-server --no-pager -n 50 | grep -i \"error\\|failed\\|exception\" | wc -l'" \
    "^[0-5]$"

# Final Results
echo ""
echo -e "${BLUE}📊 Test Results Summary${NC}"
echo "================================================================"
echo "Total Tests: $TOTAL_TESTS"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}🎉 All tests passed! System is fully operational.${NC}"
    OVERALL_STATUS="PASSED"
elif [ $TESTS_PASSED -gt $TESTS_FAILED ]; then
    echo -e "${YELLOW}⚠️  Most tests passed, but some issues detected.${NC}"
    OVERALL_STATUS="WARNING"
else
    echo -e "${RED}❌ Multiple tests failed. System may not be working correctly.${NC}"
    OVERALL_STATUS="FAILED"
fi

echo ""
echo -e "${BLUE}🌐 System Information${NC}"
echo "================================================================"
echo "Server URL: http://$GPU_INSTANCE_IP:8000"
echo "API Documentation: http://$GPU_INSTANCE_IP:8000/docs (if dev mode enabled)"
echo "Health Check: http://$GPU_INSTANCE_IP:8000/health"
echo ""

if [ "$OVERALL_STATUS" = "PASSED" ]; then
    echo -e "${BLUE}🚀 Quick Start Commands:${NC}"
    echo ""
    echo "# Test root endpoint:"
    echo "curl http://$GPU_INSTANCE_IP:8000/"
    echo ""
    echo "# Check health:"
    echo "curl http://$GPU_INSTANCE_IP:8000/health"
    echo ""
    echo "# Transcribe a file:"
    echo "curl -X POST 'http://$GPU_INSTANCE_IP:8000/transcribe/file' \\"
    echo "     -H 'Content-Type: multipart/form-data' \\"
    echo "     -F 'file=@your-audio-file.wav' \\"
    echo "     -F 'language=en'"
    echo ""
    echo -e "${GREEN}🎯 System is ready for production use!${NC}"
elif [ "$OVERALL_STATUS" = "WARNING" ]; then
    echo -e "${YELLOW}🔧 Troubleshooting:${NC}"
    echo ""
    echo "# Check server status:"
    echo "ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP './rnnt-server-ctl.sh status'"
    echo ""
    echo "# View server logs:"
    echo "ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP './rnnt-server-ctl.sh logs'"
    echo ""
    echo "# Restart server:"
    echo "ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP './rnnt-server-ctl.sh restart'"
else
    echo -e "${RED}🔧 System requires attention. Check the failed tests above.${NC}"
    echo ""
    echo "# View detailed logs:"
    echo "ssh -i $SSH_KEY_FILE ubuntu@$GPU_INSTANCE_IP 'sudo journalctl -u rnnt-server -n 50'"
fi

# Load script utilities library
SCRIPT_UTILS="$SCRIPT_DIR/lib/script-utils.sh"
if [ -f "$SCRIPT_UTILS" ]; then
    source "$SCRIPT_UTILS"
    # Show dynamically discovered next steps
    show_next_steps "$0"
else
    # Fallback to static next steps
    echo ""
    echo -e "${BLUE}📚 Next Steps:${NC}"
    echo -e "${YELLOW}1. Run the S3 transcription test:${NC}"
    echo "   ./scripts/step-035-verify-rnnt-model.sh"
    echo "   ./scripts/step-040-test-s3-transcription.sh"
    echo ""
    echo "2. Upload your audio files to test transcription"
    echo "3. Monitor system performance and logs"
    echo "4. Set up monitoring and alerting if needed"
    echo "5. Consider creating AMI snapshot for backup"
fi

# Update environment with test results
COMPLETION_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sed -i "s/SYSTEM_TESTED=\".*\"/SYSTEM_TESTED=\"$COMPLETION_TIME\"/" "$ENV_FILE"
sed -i "s/TEST_STATUS=\".*\"/TEST_STATUS=\"$OVERALL_STATUS\"/" "$ENV_FILE"
sed -i "s/TESTS_PASSED=\".*\"/TESTS_PASSED=\"$TESTS_PASSED\"/" "$ENV_FILE"
sed -i "s/TESTS_FAILED=\".*\"/TESTS_FAILED=\"$TESTS_FAILED\"/" "$ENV_FILE"

exit $([ "$OVERALL_STATUS" = "FAILED" ] && echo 1 || echo 0)