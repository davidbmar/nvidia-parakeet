#!/bin/bash
set -e

# NVIDIA Parakeet Riva ASR Deployment - Step 17: Download NVIDIA Drivers
# This script downloads NVIDIA drivers and uploads them to S3 for reliable deployment

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

echo -e "${BLUE}📥 NVIDIA Parakeet Riva ASR Deployment - Step 17: Download NVIDIA Drivers${NC}"
echo "================================================================"

# Check if configuration exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $ENV_FILE${NC}"
    echo "Run: ./scripts/riva-000-setup-configuration.sh"
    exit 1
fi

# Source configuration
source "$ENV_FILE"

# Set default values
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_TARGET_VERSION:-550}"
S3_BUCKET="${NVIDIA_DRIVERS_S3_BUCKET:-dbm-cf-2-2b}"
S3_PREFIX="${NVIDIA_DRIVERS_S3_PREFIX:-bintarball/nvidia-parakeet}"
DRIVER_BASE_URL="https://us.download.nvidia.com/tesla"

echo "Configuration:"
echo "  • Driver Version: $NVIDIA_DRIVER_VERSION"
echo "  • S3 Bucket: $S3_BUCKET"
echo "  • S3 Prefix: $S3_PREFIX"
echo "  • S3 Path: s3://$S3_BUCKET/$S3_PREFIX/"
echo "  • AWS Region: $AWS_REGION"
echo ""

# Add configuration to .env if not present
if [ -z "$NVIDIA_DRIVERS_S3_BUCKET" ]; then
    echo "NVIDIA_DRIVERS_S3_BUCKET=$S3_BUCKET" >> "$ENV_FILE"
fi
if [ -z "$NVIDIA_DRIVERS_S3_PREFIX" ]; then
    echo "NVIDIA_DRIVERS_S3_PREFIX=$S3_PREFIX" >> "$ENV_FILE"
fi

# Create temp directory for downloads
TEMP_DIR="/tmp/nvidia-drivers-$$"
mkdir -p "$TEMP_DIR"

echo -e "${BLUE}📋 NVIDIA Driver Files to Download:${NC}"
echo ""

# Define driver files to download
declare -A DRIVER_FILES
DRIVER_FILES["NVIDIA-Linux-x86_64-$NVIDIA_DRIVER_VERSION.run"]="$DRIVER_BASE_URL/$NVIDIA_DRIVER_VERSION/NVIDIA-Linux-x86_64-$NVIDIA_DRIVER_VERSION.run"

# Check if files exist on NVIDIA's servers
echo -e "${CYAN}🔍 Checking NVIDIA download links...${NC}"
for filename in "${!DRIVER_FILES[@]}"; do
    url="${DRIVER_FILES[$filename]}"
    echo -n "  • $filename ... "
    
    if curl -s --head "$url" | grep -q "200 OK"; then
        echo -e "${GREEN}✓ Available${NC}"
    else
        echo -e "${RED}✗ Not found${NC}"
        echo "    URL: $url"
    fi
done

echo ""

# Check S3 bucket access
echo -e "${BLUE}🪣 Checking S3 bucket access: $S3_BUCKET${NC}"

if aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
    echo -e "${GREEN}✓ Bucket accessible${NC}"
else
    echo -e "${RED}❌ Cannot access S3 bucket: $S3_BUCKET${NC}"
    echo "Please ensure:"
    echo "  1. Bucket exists"
    echo "  2. AWS credentials have access to the bucket"
    echo "  3. Bucket name is correct: $S3_BUCKET"
    exit 1
fi

# Download and upload drivers
echo -e "${BLUE}📥 Downloading NVIDIA drivers...${NC}"
echo ""

cd "$TEMP_DIR"

for filename in "${!DRIVER_FILES[@]}"; do
    url="${DRIVER_FILES[$filename]}"
    s3_key="$S3_PREFIX/drivers/v$NVIDIA_DRIVER_VERSION/$filename"
    
    echo -e "${CYAN}Downloading $filename...${NC}"
    
    # Check if already in S3
    if aws s3api head-object --bucket "$S3_BUCKET" --key "$s3_key" &>/dev/null; then
        echo -e "${YELLOW}⚠️  File already exists in S3, skipping download${NC}"
        continue
    fi
    
    # Download file
    echo -n "  📥 Downloading ... "
    if curl -L -o "$filename" "$url" --progress-bar; then
        echo -e "${GREEN}✓${NC}"
        
        # Get file size
        FILE_SIZE=$(du -h "$filename" | cut -f1)
        echo "  📊 Size: $FILE_SIZE"
        
        # Upload to S3
        echo -n "  ☁️  Uploading to S3 ... "
        aws s3 cp "$filename" "s3://$S3_BUCKET/$s3_key"
        echo -e "${GREEN}✓${NC}"
        
        # Clean up local file
        rm "$filename"
        
    else
        echo -e "${RED}✗ Download failed${NC}"
    fi
    
    echo ""
done

# Create driver deployment script and upload to S3
echo -e "${BLUE}📝 Creating driver deployment script...${NC}"

cat > install-nvidia-driver.sh << 'EOF'
#!/bin/bash
set -e

DRIVER_VERSION="$1"
if [ -z "$DRIVER_VERSION" ]; then
    echo "Usage: $0 <driver_version>"
    exit 1
fi

echo "Installing NVIDIA driver version $DRIVER_VERSION..."

# Download driver from S3
DRIVER_FILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
echo "Downloading $DRIVER_FILE..."

if ! aws s3 cp "s3://@@S3_BUCKET@@/@@S3_PREFIX@@/drivers/v${DRIVER_VERSION}/$DRIVER_FILE" . ; then
    echo "Failed to download driver from S3"
    exit 1
fi

# Make executable
chmod +x "$DRIVER_FILE"

# Stop X server if running
sudo systemctl stop lightdm 2>/dev/null || true
sudo systemctl stop gdm 2>/dev/null || true
sudo systemctl stop xdm 2>/dev/null || true

# Remove old drivers
echo "Removing old NVIDIA drivers..."
sudo apt-get remove --purge -y 'nvidia-*' 'libnvidia-*' '*nvidia*' 2>/dev/null || true
sudo apt-get autoremove -y

# Install new driver
echo "Installing new NVIDIA driver..."
sudo ./"$DRIVER_FILE" \
    --silent \
    --no-questions \
    --accept-license \
    --disable-nouveau \
    --no-cc-version-check \
    --install-libglvnd \
    --no-nvidia-modprobe \
    --no-kernel-module-source

echo "NVIDIA driver installation completed"
echo "Reboot required to load new driver"

# Clean up
rm -f "$DRIVER_FILE"
EOF

# Replace S3 bucket and prefix placeholders
sed -i "s/@@S3_BUCKET@@/$S3_BUCKET/g" install-nvidia-driver.sh
sed -i "s/@@S3_PREFIX@@/$S3_PREFIX/g" install-nvidia-driver.sh

# Upload deployment script to S3
aws s3 cp install-nvidia-driver.sh "s3://$S3_BUCKET/$S3_PREFIX/scripts/install-nvidia-driver.sh"

echo -e "${GREEN}✓ Driver deployment script uploaded${NC}"

# Clean up
cd - > /dev/null
rm -rf "$TEMP_DIR"
rm -f install-nvidia-driver.sh

# Update .env with driver information
sed -i '/^NVIDIA_DRIVERS_S3_LOCATION=/d' "$ENV_FILE"
echo "NVIDIA_DRIVERS_S3_LOCATION=s3://$S3_BUCKET/$S3_PREFIX/drivers/v$NVIDIA_DRIVER_VERSION/" >> "$ENV_FILE"

echo ""
echo -e "${GREEN}✅ NVIDIA Driver Download Complete!${NC}"
echo "================================================================"
echo "Driver Package Summary:"
echo "  • Version: $NVIDIA_DRIVER_VERSION"
echo "  • S3 Bucket: $S3_BUCKET"
echo "  • S3 Location: s3://$S3_BUCKET/$S3_PREFIX/drivers/v$NVIDIA_DRIVER_VERSION/"
echo "  • Install Script: s3://$S3_BUCKET/$S3_PREFIX/scripts/install-nvidia-driver.sh"
echo ""
echo -e "${CYAN}Files available for deployment:${NC}"
for filename in "${!DRIVER_FILES[@]}"; do
    echo "  • $filename"
done
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo "1. Deploy drivers: ./scripts/riva-018-update-nvidia-drivers.sh"
echo "2. Setup Riva server: ./scripts/riva-020-setup-riva-server.sh"
echo ""