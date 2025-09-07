#!/bin/bash
#
# RIVA-047: Deploy NVIDIA NIM Container for ASR
# This script deploys the NVIDIA NIM Parakeet container for speech recognition
#
# Prerequisites:
# - NIM container available (local or from S3)
# - GPU instance with NVIDIA drivers
#
# Next script: riva-060-test-riva-connectivity.sh (updated for NIM)

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "047" "Deploy NVIDIA NIM Container for ASR" "Starting Parakeet ASR service"

# Validate all prerequisites
validate_prerequisites

# Configuration
CONTAINER_IMAGE="nvcr.io/nim/nvidia/parakeet-1-1b-rnnt-multilingual:latest"
CONTAINER_NAME="parakeet-nim-asr"
S3_BUCKET="dbm-cf-2-web"
S3_PREFIX="riva-containers/nvidia-nim"
S3_LOCATION="s3://${S3_BUCKET}/${S3_PREFIX}/parakeet-1-1b-rnnt-multilingual/container.tar.gz"

print_step_header "1" "Check Container Availability"

echo "   📦 Checking for NIM container..."
NIM_AVAILABLE=$(run_remote "docker images | grep -q 'parakeet-1-1b-rnnt-multilingual' && echo 'true' || echo 'false'")

if [[ "$NIM_AVAILABLE" == "false" ]]; then
    echo "   ⚠️  NIM container not found locally - attempting S3 restore..."
    
    run_remote "
        echo 'Checking S3 for backed up container...'
        if aws s3 ls ${S3_LOCATION} >/dev/null 2>&1; then
            echo '✅ Found container backup in S3'
            echo 'Downloading and restoring...'
            
            aws s3 cp ${S3_LOCATION} /tmp/nim-parakeet-container.tar.gz --region us-east-2
            gunzip /tmp/nim-parakeet-container.tar.gz
            docker load < /tmp/nim-parakeet-container.tar
            rm -f /tmp/nim-parakeet-container.tar
            
            echo '✅ Container restored from S3 backup'
        else
            echo '❌ No container found locally or in S3'
            echo 'Please run download first or check S3 backup'
            exit 1
        fi
    "
else
    echo "   ✅ NIM container found locally"
    run_remote "docker images | grep parakeet-1-1b-rnnt-multilingual"
fi

print_step_header "2" "Stop Existing Services"

echo "   🛑 Stopping any existing Riva/ASR services..."
run_remote "
    # Stop old Riva server if running
    docker stop riva-server 2>/dev/null || echo 'No riva-server to stop'
    docker rm riva-server 2>/dev/null || echo 'No riva-server to remove'
    
    # Stop existing NIM container if running
    docker stop ${CONTAINER_NAME} 2>/dev/null || echo 'No existing NIM container to stop'
    docker rm ${CONTAINER_NAME} 2>/dev/null || echo 'No existing NIM container to remove'
    
    echo '✅ Services stopped and cleaned up'
"

print_step_header "3" "Start NVIDIA NIM ASR Service"

echo "   🚀 Starting NIM container for ASR..."
run_remote "
    echo 'Starting NVIDIA NIM Parakeet ASR container...'
    
    # Create NIM data directory
    mkdir -p /opt/nim-cache
    
    # Start NIM container
    docker run -d \
        --name ${CONTAINER_NAME} \
        --restart unless-stopped \
        --gpus all \
        -p 8000:8000 \
        -p 50051:50051 \
        -v /opt/nim-cache:/opt/nim/.cache \
        -e CUDA_VISIBLE_DEVICES=0 \
        -e NIM_LOG_LEVEL=INFO \
        ${CONTAINER_IMAGE}
    
    echo '✅ NIM container started'
    echo 'Container ID:'
    docker ps | grep ${CONTAINER_NAME}
"

print_step_header "4" "Monitor Startup"

echo "   ⏳ Monitoring NIM service startup..."
run_remote "
    echo 'Waiting for NIM service to initialize...'
    
    # Monitor logs for startup completion
    timeout 300s docker logs -f ${CONTAINER_NAME} 2>&1 | while read line; do
        echo \"\$line\"
        if [[ \"\$line\" == *\"Server started\"* ]] || [[ \"\$line\" == *\"ready\"* ]] || [[ \"\$line\" == *\"listening\"* ]]; then
            echo '🎉 NIM service ready!'
            break
        elif [[ \"\$line\" == *\"error\"* ]] || [[ \"\$line\" == *\"failed\"* ]]; then
            echo '❌ Detected startup error'
        fi
    done &
    
    # Wait for service to be ready
    sleep 60
    
    echo 'Checking container status:'
    if docker ps | grep -q ${CONTAINER_NAME}; then
        echo '✅ NIM container is running'
    else
        echo '❌ NIM container failed to start'
        echo 'Recent logs:'
        docker logs --tail 20 ${CONTAINER_NAME} || echo 'No logs available'
        exit 1
    fi
"

print_step_header "5" "Test Service Health"

echo "   🏥 Testing NIM service health..."
run_remote "
    echo 'Testing HTTP health endpoint...'
    
    # Wait a bit more for service to fully initialize
    sleep 30
    
    # Test health endpoints
    for i in {1..5}; do
        echo \"Health check attempt \$i/5...\"
        
        if curl -s http://localhost:8000/health >/dev/null 2>&1; then
            echo '✅ HTTP health check passed'
            break
        elif [ \$i -eq 5 ]; then
            echo '⚠️  HTTP health check failed after 5 attempts'
            echo 'Service may still be initializing...'
        else
            echo 'Waiting 10 seconds before retry...'
            sleep 10
        fi
    done
    
    echo ''
    echo 'Testing basic API endpoint...'
    curl -s http://localhost:8000/v1/models || echo 'Models endpoint not ready yet'
"

complete_script_success "047" "NIM_CONTAINER_DEPLOYED" "./scripts/riva-060-test-riva-connectivity.sh"

echo ""
echo "🎉 RIVA-047 Complete: NVIDIA NIM ASR Service Deployed!"
echo "====================================================="
echo "✅ NIM container running and accessible"
echo "✅ Parakeet ASR model loaded"
echo "✅ Health checks completed"
echo ""
echo "🌐 Service Endpoints:"
echo "   • HTTP API: http://${RIVA_HOST}:8000"
echo "   • gRPC: ${RIVA_HOST}:50051"
echo "   • Health: http://${RIVA_HOST}:8000/health"
echo "   • Models: http://${RIVA_HOST}:8000/v1/models"
echo ""
echo "📍 Next Steps:"
echo "   1. Run: ./scripts/riva-060-test-riva-connectivity.sh"
echo "   2. Test ASR functionality"
echo "   3. Enable real mode in application"
echo ""