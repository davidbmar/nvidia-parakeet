#!/bin/bash
#
# RIVA-046: Save NIM Container to S3 
# This script saves the downloaded NVIDIA NIM container to S3 for reuse
#
# Prerequisites:
# - NIM container downloaded: parakeet-1-1b-rnnt-multilingual
# - AWS CLI configured with S3 access
#
# Next script: riva-047-deploy-nim-container.sh

set -euo pipefail

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/riva-common-functions.sh"

# Script initialization
print_script_header "046" "Save NIM Container to S3" "Backing up container for reuse"

# Validate all prerequisites
validate_prerequisites

# S3 Configuration
S3_BUCKET="dbm-cf-2-web"
S3_PREFIX="riva-containers/nvidia-nim"
CONTAINER_NAME="parakeet-1-1b-rnnt-multilingual"
S3_LOCATION="s3://${S3_BUCKET}/${S3_PREFIX}/${CONTAINER_NAME}/"
CONTAINER_IMAGE="nvcr.io/nim/nvidia/parakeet-1-1b-rnnt-multilingual:latest"

print_step_header "1" "Check Downloaded Container"

echo "   📦 Verifying NIM container is downloaded..."
run_remote "
    if docker images | grep -q 'parakeet-1-1b-rnnt-multilingual'; then
        echo '✅ NIM container found'
        docker images | grep parakeet-1-1b-rnnt-multilingual
        echo ''
        CONTAINER_SIZE=\$(docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep parakeet-1-1b-rnnt-multilingual | awk '{print \$2}')
        echo \"Container size: \$CONTAINER_SIZE\"
    else
        echo '❌ NIM container not found'
        echo 'Please wait for download to complete or run again'
        exit 1
    fi
"

print_step_header "2" "Export Container to Archive"

echo "   📄 Creating container archive..."
run_remote "
    echo 'Saving container to tar file...'
    docker save ${CONTAINER_IMAGE} > /tmp/nim-parakeet-container.tar
    
    echo 'Compressing archive...'
    gzip /tmp/nim-parakeet-container.tar
    
    echo 'Archive created:'
    ls -lh /tmp/nim-parakeet-container.tar.gz
    
    echo '✅ Container exported successfully'
"

print_step_header "3" "Upload to S3"

echo "   ☁️  Uploading container to S3..."
run_remote "
    echo 'Starting S3 upload...'
    echo 'Target: ${S3_LOCATION}container.tar.gz'
    
    # Upload with progress and metadata
    aws s3 cp /tmp/nim-parakeet-container.tar.gz ${S3_LOCATION}container.tar.gz \
        --metadata 'container=nvidia-nim-parakeet,version=latest,created=$(date -Iseconds)' \
        --storage-class STANDARD_IA \
        --region us-east-2
    
    echo '✅ Upload completed successfully'
"

print_step_header "4" "Verify Upload and Cleanup"

echo "   🔍 Verifying S3 upload..."
run_remote "
    echo 'Checking S3 object...'
    aws s3 ls ${S3_LOCATION} --human-readable
    
    echo 'Getting object metadata...'
    aws s3api head-object \
        --bucket ${S3_BUCKET} \
        --key ${S3_PREFIX}/${CONTAINER_NAME}/container.tar.gz \
        --region us-east-2 | grep -E '(ContentLength|LastModified|Metadata)'
    
    echo ''
    echo 'Cleaning up local files...'
    rm -f /tmp/nim-parakeet-container.tar.gz
    
    echo '✅ Verification complete and cleanup done'
"

complete_script_success "046" "NIM_CONTAINER_BACKED_UP" "./scripts/riva-047-deploy-nim-container.sh"

echo ""
echo "🎉 RIVA-046 Complete: NIM Container Saved to S3!"
echo "================================================="
echo "✅ Container exported and compressed"
echo "✅ Uploaded to S3 with metadata"
echo "✅ Verified and local files cleaned up"
echo ""
echo "📍 S3 Location:"
echo "   ${S3_LOCATION}container.tar.gz"
echo ""
echo "📍 Next Steps:"
echo "   1. Run: ./scripts/riva-047-deploy-nim-container.sh"
echo "   2. Test ASR functionality with deployed NIM"
echo ""