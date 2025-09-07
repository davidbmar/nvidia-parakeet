#!/bin/bash
#
# RIVA-047: Deploy NVIDIA NIM Container from S3
# This script loads the NVIDIA NIM Parakeet container from S3 and deploys for ASR
#
# Prerequisites:
# - NIM container in S3 (from riva-046)
# - GPU instance with NVIDIA drivers
#
# Next script: riva-060-test-riva-connectivity.sh (updated for NIM)

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "047" "Deploy NVIDIA NIM Container from S3" "Loading and starting Parakeet ASR service"

# Validate all prerequisites
validate_prerequisites

# Configuration
CONTAINER_IMAGE="nvcr.io/nim/nvidia/parakeet-1-1b-rnnt-multilingual:latest"
CONTAINER_NAME="parakeet-nim-asr"
S3_BUCKET="dbm-cf-2-web"
S3_PREFIX="riva-containers/nvidia-nim"
S3_LOCATION="s3://${S3_BUCKET}/${S3_PREFIX}/parakeet-1-1b-rnnt-multilingual/container.tar"

print_step_header "1" "Check Container Availability"

echo "   📦 Checking for NIM container..."
NIM_AVAILABLE=$(run_remote "docker images | grep -q 'parakeet-1-1b-rnnt-multilingual' && echo 'true' || echo 'false'")

if [[ "$NIM_AVAILABLE" == "false" ]]; then
    echo "   ⚠️  NIM container not found locally - loading from S3..."
    
    run_remote "
        echo 'Checking available disk space...'
        AVAILABLE_GB=\$(df / | tail -1 | awk '{print int(\$4/1024/1024)}')
        echo \"Available space: \${AVAILABLE_GB}GB\"
        
        if [ \$AVAILABLE_GB -lt 30 ]; then
            echo '⚠️  Limited disk space - using streaming approach'
            
            # Stream from S3 directly to Docker load
            echo 'Streaming container from S3...'
            aws s3 cp ${S3_LOCATION} - --region us-east-2 | docker load
            
            echo '✅ Container loaded via streaming'
        else
            echo '✅ Sufficient space - downloading then loading'
            
            # Download then load
            aws s3 cp ${S3_LOCATION} /tmp/nim-container.tar --region us-east-2
            docker load < /tmp/nim-container.tar
            rm -f /tmp/nim-container.tar
            
            echo '✅ Container loaded from temporary download'
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
    echo 'Container status:'
    docker ps | grep ${CONTAINER_NAME} || echo 'Container may still be starting...'
"

print_step_header "4" "Monitor Startup"

echo "   ⏳ Monitoring NIM service startup..."
run_remote "
    echo 'Waiting for NIM service to initialize (this may take 2-5 minutes)...'
    
    # Monitor logs for startup completion with timeout
    timeout 300s bash -c '
        while true; do
            if docker logs ${CONTAINER_NAME} 2>&1 | tail -20 | grep -E \"(Server started|ready|listening|model.*loaded)\"; then
                echo \"🎉 NIM service appears to be ready!\"
                break
            elif docker logs ${CONTAINER_NAME} 2>&1 | tail -5 | grep -E \"(error|failed|exit)\"; then
                echo \"❌ Detected startup error\"
                docker logs ${CONTAINER_NAME} | tail -10
                break
            else
                echo \"Still starting... \$(date)\"
                sleep 10
            fi
        done
    ' || echo 'Timeout reached - service may still be initializing'
    
    echo ''
    echo 'Final container status:'
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
    echo 'Testing HTTP health endpoint (may take additional time to respond)...'
    
    # Wait a bit more for service to fully initialize
    sleep 30
    
    # Test health endpoints with longer timeout
    for i in {1..10}; do
        echo \"Health check attempt \$i/10...\"
        
        if timeout 30s curl -s http://localhost:8000/health >/dev/null 2>&1; then
            echo '✅ HTTP health check passed'
            break
        elif [ \$i -eq 10 ]; then
            echo '⚠️  HTTP health check still not ready after 10 attempts'
            echo 'Service may need more time to fully initialize'
            echo 'Recent container logs:'
            docker logs --tail 10 ${CONTAINER_NAME}
        else
            echo 'Waiting 15 seconds before retry...'
            sleep 15
        fi
    done
    
    echo ''
    echo 'Testing basic API endpoint...'
    timeout 30s curl -s http://localhost:8000/v1/models || echo 'Models endpoint may need more time'
"

complete_script_success "047" "NIM_CONTAINER_DEPLOYED_FROM_S3" "./scripts/riva-060-test-riva-connectivity.sh"

echo ""
echo "🎉 RIVA-047 Complete: NVIDIA NIM ASR Service Deployed from S3!"
echo "============================================================="
echo "✅ NIM container loaded from S3 backup"
echo "✅ Parakeet ASR model container running"
echo "✅ Service startup monitored"
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
echo "💡 Note: NIM containers can take 5-10 minutes to fully initialize"
echo "   Wait for full startup before testing transcription functionality"
echo ""