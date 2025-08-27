#!/bin/bash
set -e

# Production RNN-T Deployment - Master Script: Complete Deployment
# This script runs the complete deployment sequence for RNN-T transcription

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Production RNN-T Deployment - Complete Deployment${NC}"
echo "================================================================"
echo "This script will run the complete deployment sequence:"
echo ""
echo "• step-000-setup-configuration.sh    - Configure deployment settings"
echo "• step-010-deploy-gpu-instance.sh    - Deploy AWS GPU instance"
echo "• step-020-install-rnnt-server.sh    - Install RNN-T server (systemd)"
echo "• step-025-deploy-rnnt-docker.sh     - Deploy RNN-T Docker container"
echo "• step-035-verify-rnnt-model.sh      - Verify RNN-T model loading"
echo "• step-040-test-s3-transcription.sh  - Test S3 audio transcription"
echo ""
echo -e "${YELLOW}⚠️  This will take 20-30 minutes to complete${NC}"
echo -e "${YELLOW}⚠️  Requires AWS credentials and permissions${NC}"
echo ""

# Confirm execution
read -p "Proceed with complete deployment? [y/N]: " confirm
if [[ ! $confirm =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

echo ""
echo -e "${GREEN}🎬 Starting deployment sequence...${NC}"

# Function to run step with error handling
run_step() {
    local step_script="$1"
    local step_name="$2"
    
    echo ""
    echo -e "${BLUE}▶️  Running: $step_name${NC}"
    echo "================================================================"
    
    if [ -f "$SCRIPT_DIR/$step_script" ]; then
        if bash "$SCRIPT_DIR/$step_script"; then
            echo -e "${GREEN}✅ $step_name completed successfully${NC}"
        else
            echo -e "${RED}❌ $step_name failed${NC}"
            echo ""
            echo -e "${YELLOW}💡 To resume deployment, fix the issue and run:${NC}"
            echo "   $SCRIPT_DIR/$step_script"
            echo ""
            echo -e "${YELLOW}💡 Or run individual remaining steps:${NC}"
            for remaining_step in "${@:3}"; do
                echo "   $SCRIPT_DIR/$remaining_step"
            done
            exit 1
        fi
    else
        echo -e "${RED}❌ Script not found: $step_script${NC}"
        exit 1
    fi
    
    # Pause between steps
    echo ""
    echo -e "${YELLOW}⏳ Waiting 5 seconds before next step...${NC}"
    sleep 5
}

# Deployment sequence
echo -e "${GREEN}📋 Deployment Progress:${NC}"

run_step "step-000-setup-configuration.sh" "Configuration Setup" \
         "step-010-deploy-gpu-instance.sh" "step-020-install-rnnt-server.sh" \
         "step-025-deploy-rnnt-docker.sh" "step-035-verify-rnnt-model.sh" \
         "step-040-test-s3-transcription.sh"

run_step "step-010-deploy-gpu-instance.sh" "GPU Instance Deployment" \
         "step-020-install-rnnt-server.sh" "step-025-deploy-rnnt-docker.sh" \
         "step-035-verify-rnnt-model.sh" "step-040-test-s3-transcription.sh"

# Choose deployment method
echo ""
echo -e "${YELLOW}🔄 Choose deployment method:${NC}"
echo "1. Systemd service (step-020) - Traditional service deployment"
echo "2. Docker container (step-025) - Container deployment (recommended)"
echo ""
read -p "Choose deployment method [1/2]: " deploy_method

if [[ "$deploy_method" == "1" ]]; then
    run_step "step-020-install-rnnt-server.sh" "RNN-T Server Installation (Systemd)" \
             "step-035-verify-rnnt-model.sh" "step-040-test-s3-transcription.sh"
elif [[ "$deploy_method" == "2" ]]; then
    run_step "step-025-deploy-rnnt-docker.sh" "RNN-T Docker Container Deployment" \
             "step-035-verify-rnnt-model.sh" "step-040-test-s3-transcription.sh"
else
    echo -e "${RED}❌ Invalid choice. Please run step-020 or step-025 manually.${NC}"
    exit 1
fi

run_step "step-035-verify-rnnt-model.sh" "RNN-T Model Verification" \
         "step-040-test-s3-transcription.sh"

run_step "step-040-test-s3-transcription.sh" "S3 Audio Transcription Test"

# Completion summary
echo ""
echo -e "${GREEN}🎉 Complete RNN-T Deployment Successful!${NC}"
echo "================================================================"
echo -e "${GREEN}✅ AWS GPU instance deployed${NC}"
echo -e "${GREEN}✅ RNN-T transcription server running${NC}"
echo -e "${GREEN}✅ SpeechBrain Conformer RNN-T model loaded${NC}"
echo -e "${GREEN}✅ S3 audio transcription tested${NC}"
echo ""
echo -e "${BLUE}🌐 Your RNN-T transcription service is ready!${NC}"
echo ""
echo -e "${YELLOW}📊 Access your deployment:${NC}"
if [ -f "$SCRIPT_DIR/../.env" ]; then
    source "$SCRIPT_DIR/../.env"
    echo "• Server URL: http://${GPU_INSTANCE_IP:-'YOUR-INSTANCE-IP'}:8000"
    echo "• Health Check: http://${GPU_INSTANCE_IP:-'YOUR-INSTANCE-IP'}:8000/health"
fi
echo ""
echo -e "${YELLOW}📜 Next steps:${NC}"
echo "1. Test with additional audio files"
echo "2. Monitor GPU utilization and costs"
echo "3. Set up monitoring and alerting"
echo "4. Configure auto-scaling if needed"
echo ""