#!/bin/bash
set -e

# Production RNN-T Deployment - Step 8.0: Run All Tests
# This script runs a comprehensive test suite for the entire RNN-T system

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

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    exit 1
fi

source "$ENV_FILE"

echo -e "${BLUE}🧪 Production RNN-T Deployment - Comprehensive Test Suite${NC}"
echo "================================================================"
echo "Target Instance: $GPU_INSTANCE_IP"
echo "Test Suite Version: 1.0"
echo ""

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Function to run a test and track results
run_test() {
    local test_name="$1"
    local test_script="$2"
    local optional="${3:-false}"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -e "${CYAN}🔍 Test $TOTAL_TESTS: $test_name${NC}"
    
    if [ ! -f "$SCRIPT_DIR/$test_script" ]; then
        if [ "$optional" = "true" ]; then
            echo -e "${YELLOW}⏭️  SKIPPED (script not found: $test_script)${NC}"
            return 0
        else
            echo -e "${RED}❌ FAILED (script not found: $test_script)${NC}"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            return 1
        fi
    fi
    
    if "./$test_script" > /tmp/test_output_$TOTAL_TESTS.log 2>&1; then
        echo -e "${GREEN}✅ PASSED${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        echo -e "${RED}❌ FAILED${NC}"
        echo -e "${YELLOW}   Log: /tmp/test_output_$TOTAL_TESTS.log${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# Test 1: Basic System Test
echo -e "${BLUE}📋 Running Basic System Tests...${NC}"
run_test "System Health Check" "step-050-test-system.sh"

# Test 2: WebSocket Tests (if WebSocket is deployed)
if [ -n "$DEPLOYMENT_METHOD" ]; then
    echo ""
    echo -e "${BLUE}📋 Running WebSocket Tests...${NC}"
    run_test "WebSocket Functionality" "step-055-test-websocket-functionality.sh" true
fi

# Test 3: HTTPS Tests (if HTTPS is enabled)
if [ "$HTTPS_ENABLED" = "true" ]; then
    echo ""
    echo -e "${BLUE}📋 Running HTTPS Tests...${NC}"
    
    echo -e "${CYAN}🔍 Test: HTTPS Connectivity${NC}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    if curl -k -s --connect-timeout 5 "https://$GPU_INSTANCE_IP/health" | grep -q "healthy"; then
        echo -e "${GREEN}✅ PASSED (HTTPS endpoint responding)${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}❌ FAILED (HTTPS endpoint not responding)${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
fi

# Test 4: S3 Integration Tests
echo ""
echo -e "${BLUE}📋 Running S3 Integration Tests...${NC}"
run_test "S3 Transcription" "step-075-test-s3-transcription.sh" true

# Test 5: API Endpoint Tests
echo ""
echo -e "${BLUE}📋 Running API Endpoint Tests...${NC}"

# Basic API tests
api_tests=("/health" "/" "/static/index.html")
base_url="http://$GPU_INSTANCE_IP:8000"

for endpoint in "${api_tests[@]}"; do
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -e "${CYAN}🔍 Test $TOTAL_TESTS: API $endpoint${NC}"
    
    if curl -s --connect-timeout 5 "$base_url$endpoint" > /dev/null; then
        echo -e "${GREEN}✅ PASSED${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}❌ FAILED${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
done

# Test 6: Model Verification
echo ""
echo -e "${BLUE}📋 Running Model Verification...${NC}"
run_test "RNN-T Model Verification" "step-060-verify-rnnt-model.sh" true

# Generate Test Report
echo ""
echo "================================================================"
echo -e "${BLUE}📊 Test Suite Results${NC}"
echo "================================================================"

# Calculate percentages
if [ $TOTAL_TESTS -gt 0 ]; then
    SUCCESS_RATE=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
else
    SUCCESS_RATE=0
fi

echo "Total Tests Run: $TOTAL_TESTS"
echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
echo -e "Failed: ${RED}$FAILED_TESTS${NC}"
echo "Success Rate: $SUCCESS_RATE%"

# Overall status
echo ""
if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}🎉 ALL TESTS PASSED! System is fully functional.${NC}"
    exit_code=0
elif [ $SUCCESS_RATE -ge 80 ]; then
    echo -e "${YELLOW}⚠️  Most tests passed ($SUCCESS_RATE%), but some issues detected.${NC}"
    exit_code=1
else
    echo -e "${RED}❌ CRITICAL: Multiple test failures ($SUCCESS_RATE% success rate)${NC}"
    exit_code=2
fi

echo ""
echo -e "${BLUE}🔍 System Status Summary:${NC}"

# Show which services are running
services=("rnnt-server" "rnnt-websocket" "rnnt-https")
for service in "${services[@]}"; do
    if ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@"$GPU_INSTANCE_IP" \
       "sudo systemctl is-active $service" >/dev/null 2>&1; then
        echo -e "• ${GREEN}$service: ACTIVE${NC}"
    else
        echo -e "• ${YELLOW}$service: INACTIVE${NC}"
    fi
done

echo ""
echo -e "${BLUE}🌐 Access URLs:${NC}"
echo "• HTTP: http://$GPU_INSTANCE_IP:8000"
if [ "$HTTPS_ENABLED" = "true" ]; then
    echo "• HTTPS: https://$GPU_INSTANCE_IP"
fi
echo "• Demo UI: http://$GPU_INSTANCE_IP:8000/static/index.html"
echo ""

if [ $exit_code -gt 0 ]; then
    echo -e "${YELLOW}📋 Troubleshooting:${NC}"
    echo "• Check logs: sudo journalctl -u <service-name> -f"
    echo "• Review test logs: ls /tmp/test_output_*.log"
    echo "• Re-run individual tests: ./scripts/step-XXX-<test-name>.sh"
fi

exit $exit_code