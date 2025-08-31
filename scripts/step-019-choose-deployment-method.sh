#!/bin/bash
set -e

# Production RNN-T Deployment - Step 1.9: Choose Deployment Method
# This script helps you choose between direct installation and Docker deployment

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
    echo "Run: ./scripts/step-000-setup-configuration.sh first"
    exit 1
fi

source "$ENV_FILE"

echo -e "${BLUE}🚀 Production RNN-T Deployment - Choose Deployment Method${NC}"
echo "================================================================"
echo ""
echo -e "${YELLOW}You have TWO deployment options for the RNN-T server:${NC}"
echo ""

# Option A: Direct Installation
echo -e "${GREEN}📦 Option A: Direct Installation (Recommended)${NC}"
echo "┌─────────────────────────────────────────────────────────┐"
echo "│ • Installs Python, PyTorch, and dependencies directly  │"
echo "│ • Runs as a systemd service on the host OS            │"
echo "│ • Faster startup and better GPU performance           │"
echo "│ • Easier debugging and development                     │"
echo "│ • Lower memory overhead                               │"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo -e "${BLUE}✅ Best for:${NC} Development, testing, maximum performance"
echo -e "${BLUE}⚠️  Note:${NC} Installs dependencies system-wide"
echo ""

# Option B: Docker Deployment
echo -e "${CYAN}🐳 Option B: Docker Container${NC}"
echo "┌─────────────────────────────────────────────────────────┐"
echo "│ • Packages everything in an isolated Docker container  │"
echo "│ • Reproducible and portable deployments               │"
echo "│ • Clean environment separation                         │"
echo "│ • Easy to version control and rollback                │"
echo "│ • Industry standard for production                     │"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo -e "${BLUE}✅ Best for:${NC} Production deployments, team environments"
echo -e "${BLUE}⚠️  Note:${NC} Slightly higher resource usage, Docker required"
echo ""

# Performance comparison
echo -e "${YELLOW}📊 Quick Comparison:${NC}"
echo "┌────────────────┬──────────────────┬──────────────────┐"
echo "│ Aspect         │ Direct Install   │ Docker Container │"
echo "├────────────────┼──────────────────┼──────────────────┤"
echo "│ Performance    │ Fastest          │ ~2-5% overhead   │"
echo "│ Memory Usage   │ Lower            │ Higher           │"
echo "│ Setup Time     │ 5-10 minutes     │ 10-15 minutes    │"
echo "│ Isolation      │ System-wide      │ Containerized    │"
echo "│ Portability    │ Instance-specific│ Runs anywhere    │"
echo "│ Debugging      │ Easier           │ More complex     │"
echo "│ Production     │ Good             │ Industry standard│"
echo "└────────────────┴──────────────────┴──────────────────┘"
echo ""

# Interactive choice
echo -e "${YELLOW}🤔 Which deployment method would you like to use?${NC}"
echo ""
echo "1) Direct Installation (Recommended for development/testing)"
echo "2) Docker Container (Recommended for production)"
echo "3) Show me more details about each option"
echo "4) Exit and decide later"
echo ""

while true; do
    read -p "Enter your choice (1-4): " choice
    case $choice in
        1)
            echo ""
            echo -e "${GREEN}✅ You chose: Direct Installation${NC}"
            echo ""
            echo -e "${BLUE}📋 Next steps:${NC}"
            echo "1. Run: ./scripts/step-020-direct-install-server.sh"
            echo "2. Run: ./scripts/step-026-deploy-websocket.sh (optional)"
            echo "3. Run: ./scripts/step-030-test-system.sh"
            echo ""
            echo -e "${YELLOW}💡 Ready to proceed?${NC}"
            read -p "Run the direct installation now? (Y/n): " -n 1 proceed
            echo
            if [[ "$proceed" =~ ^[Yy]$ ]] || [ -z "$proceed" ]; then
                echo -e "${GREEN}🚀 Starting direct installation...${NC}"
                exec "$SCRIPT_DIR/step-020-direct-install-server.sh"
            else
                echo "Run ./scripts/step-020-direct-install-server.sh when ready"
            fi
            break
            ;;
        2)
            echo ""
            echo -e "${CYAN}✅ You chose: Docker Container${NC}"
            echo ""
            echo -e "${BLUE}📋 Next steps:${NC}"
            echo "1. Run: ./scripts/step-020-docker-deploy.sh"
            echo "2. Run: ./scripts/step-026-deploy-websocket.sh (optional)"
            echo "3. Run: ./scripts/step-030-test-system.sh"
            echo ""
            echo -e "${YELLOW}💡 Ready to proceed?${NC}"
            read -p "Run the Docker deployment now? (Y/n): " -n 1 proceed
            echo
            if [[ "$proceed" =~ ^[Yy]$ ]] || [ -z "$proceed" ]; then
                echo -e "${CYAN}🚀 Starting Docker deployment...${NC}"
                exec "$SCRIPT_DIR/step-020-docker-deploy.sh"
            else
                echo "Run ./scripts/step-020-docker-deploy.sh when ready"
            fi
            break
            ;;
        3)
            echo ""
            echo -e "${BLUE}📚 Detailed Comparison:${NC}"
            echo ""
            echo -e "${GREEN}Direct Installation Details:${NC}"
            echo "• Installs Python 3.8+, PyTorch with CUDA support"
            echo "• Downloads SpeechBrain RNN-T model to /opt/rnnt/"
            echo "• Creates systemd service for automatic startup"
            echo "• GPU memory: ~1-2GB for model, rest available for processing"
            echo "• Model loading: ~5-15 seconds depending on cache"
            echo "• API latency: ~100-300ms per audio file"
            echo ""
            echo -e "${CYAN}Docker Container Details:${NC}"
            echo "• Uses NVIDIA Container Toolkit for GPU access"
            echo "• Base image: nvidia/cuda with Python runtime"
            echo "• All dependencies isolated in container"
            echo "• Container overhead: ~100-200MB additional memory"
            echo "• Same model and performance, just containerized"
            echo "• Can be versioned, tagged, and deployed consistently"
            echo ""
            echo -e "${YELLOW}🔄 Choose again:${NC}"
            continue
            ;;
        4)
            echo ""
            echo -e "${YELLOW}👋 No problem! You can run this script again later.${NC}"
            echo ""
            echo "To choose deployment method later, run:"
            echo "   ./scripts/step-019-choose-deployment-method.sh"
            echo ""
            exit 0
            ;;
        *)
            echo "Invalid choice. Please enter 1, 2, 3, or 4."
            continue
            ;;
    esac
done

# Update .env with chosen method
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [ "$choice" = "1" ]; then
    sed -i "s/DEPLOYMENT_METHOD=\".*\"/DEPLOYMENT_METHOD=\"direct\"/" "$ENV_FILE" 2>/dev/null || \
        echo "DEPLOYMENT_METHOD=\"direct\"" >> "$ENV_FILE"
    sed -i "s/DEPLOYMENT_CHOICE_TIME=\".*\"/DEPLOYMENT_CHOICE_TIME=\"$TIMESTAMP\"/" "$ENV_FILE" 2>/dev/null || \
        echo "DEPLOYMENT_CHOICE_TIME=\"$TIMESTAMP\"" >> "$ENV_FILE"
elif [ "$choice" = "2" ]; then
    sed -i "s/DEPLOYMENT_METHOD=\".*\"/DEPLOYMENT_METHOD=\"docker\"/" "$ENV_FILE" 2>/dev/null || \
        echo "DEPLOYMENT_METHOD=\"docker\"" >> "$ENV_FILE"
    sed -i "s/DEPLOYMENT_CHOICE_TIME=\".*\"/DEPLOYMENT_CHOICE_TIME=\"$TIMESTAMP\"/" "$ENV_FILE" 2>/dev/null || \
        echo "DEPLOYMENT_CHOICE_TIME=\"$TIMESTAMP\"" >> "$ENV_FILE"
fi