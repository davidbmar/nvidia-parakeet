# NVIDIA Parakeet Riva ASR Deployment System

🚀 **One-click deployment of production-ready NVIDIA Parakeet RNNT via Riva ASR**

## What This Delivers

- **Real RNNT Transcription**: NVIDIA Parakeet RNNT model via Riva ASR (not mock responses)
- **GPU Accelerated**: Tesla T4/V100 optimized with NVIDIA Riva inference
- **Ultra-Low Latency**: ~100-300ms partial results, ~800ms final transcription  
- **Word-Level Timestamps**: Precise timing and confidence scores for each word
- **WebSocket Streaming**: Real-time audio streaming with partial/final results
- **Production Logging**: Comprehensive structured logging for debugging and monitoring
- **Multi-Strategy Deployment**: AWS EC2, existing servers, or local development

## Architecture

```
┌─────────────────┐    WebSocket     ┌─────────────────┐    gRPC    ┌─────────────────┐
│   Client Apps   │◄───────────────►│ WebSocket Server│◄──────────►│  NVIDIA Riva    │
│   (Browser/App) │   Audio Stream   │  (Port 8443)    │  Streaming  │ Parakeet RNNT   │
└─────────────────┘                 └─────────────────┘             │  (GPU Worker)   │
                                             │                       └─────────────────┘
                                             ▼
                                    ┌─────────────────┐
                                    │  Structured     │
                                    │  Logging &      │
                                    │  Monitoring     │
                                    └─────────────────┘
```

## Quick Start

### Option 1: Automated Full Deployment (Recommended)
```bash
# Clone and run everything with comprehensive logging
git clone https://github.com/davidbmar/nvidia-parakeet.git
cd nvidia-parakeet

# Run complete deployment with full logging
./scripts/riva-000-run-complete-deployment.sh

# System is ready! 🎉
# Logs available in: ./logs/
```

### Option 2: Step-by-Step Deployment
```bash
# 1. Clone and configure
git clone https://github.com/davidbmar/nvidia-parakeet.git
cd nvidia-parakeet

# 2. Setup configuration (interactive)
./scripts/riva-000-setup-configuration.sh

# 3. Deploy GPU instance (AWS strategy)
./scripts/riva-015-deploy-or-restart-aws-gpu-instance.sh

# 4. Configure security access
./scripts/riva-015-configure-security-access.sh

# 5. Update NVIDIA drivers (if needed)
./scripts/riva-025-transfer-nvidia-drivers.sh

# 6. Setup Riva server with Parakeet model
./scripts/riva-070-setup-traditional-riva-server.sh

# 7. Deploy WebSocket application
./scripts/riva-090-deploy-websocket-asr-application.sh

# 8. Test complete integration
./scripts/riva-100-test-basic-integration.sh

# System is ready! 🎉
# Check logs in: ./logs/ for detailed execution info
```

## Requirements

- **AWS Account**: With EC2 and S3 permissions
- **GPU Instance**: g4dn.xlarge or better (Tesla T4+ GPU)
- **Python 3.10+**: On target instance
- **~5GB Disk**: For model downloads

## 📊 Performance Specs

| Metric | Parakeet RNNT (This System) | Whisper Alternative |
|--------|-----------------------------|--------------------|
| **Partial Latency** | ~100-300ms | N/A (batch only) |
| **Final Latency** | ~800ms | ~1-2 seconds |
| **GPU Memory** | ~4-6GB VRAM | ~4GB VRAM |
| **Throughput** | 50+ concurrent streams | 3-4 concurrent |
| **Real-time Factor** | 0.1-0.3 (streaming) | 0.3-0.5 (batch) |

## 📋 Comprehensive Logging & Debugging

This system includes a **production-grade logging framework** for easy troubleshooting:

### 🔍 **Log File Structure**
```
logs/
├── riva-000-setup-configuration_20250906_143022_pid12345.log
├── riva-025-transfer-nvidia-drivers_20250906_144530_pid12346.log
├── riva-040-setup-riva-server_20250906_145012_pid12347.log
└── check-driver-status_20250906_150203_pid12348.log
```

### 📈 **Structured Logging Features**
- **Timestamps**: Millisecond precision for all operations
- **Sections**: Clear organization (Configuration, Connectivity, Driver Check, etc.)
- **Command Tracking**: Every command executed with timing and output
- **Error Context**: Full stack traces with actionable error information
- **Resource Monitoring**: CPU, memory, and GPU usage tracking

### 🛠️ **Debug Utilities**
```bash
# Quick driver status check with comprehensive logging
./scripts/check-driver-status.sh

# Test logging framework
./scripts/test-logging.sh

# View recent logs
ls -lat logs/ | head -5

# Monitor log in real-time
tail -f logs/riva-*.log
```

### 📊 **Log Analysis**
Each log file contains:
- **Session Info**: Environment, user, host, working directory
- **Section Markers**: Clear start/end indicators for each operation
- **Command Execution**: Full command with timing and exit codes
- **Error Details**: Complete error output with context
- **Final Summary**: Success/failure status with recommendations

## 🔗 API Endpoints

### Riva Health Check
```bash
GET http://your-riva-server:8000/health
```

### WebSocket Streaming (Primary Interface)
```bash
# Connect to WebSocket for real-time streaming
ws://your-websocket-server:8443/ws/transcribe

# Send audio chunks and receive partial/final results
```

### HTTP File Transcription (Alternative)  
```bash
POST http://your-riva-server:8000/v1/asr:recognize
Content-Type: application/json

# Riva gRPC/HTTP API for batch processing
```

### WebSocket Response Format
```json
{
  "type": "partial|final",
  "text": "TRANSCRIBED SPEECH TEXT",
  "confidence": 0.95,
  "words": [
    {
      "word": "TRANSCRIBED", 
      "start_time": 0.0,
      "end_time": 0.5,
      "confidence": 0.95
    }
  ],
  "processing_time_ms": 150,
  "audio_duration_s": 10.0,
  "real_time_factor": 0.1,
  "model": "nvidia-parakeet-rnnt-1.15b",
  "riva_accelerated": true,
  "is_final": false
}
```

## 📁 Directory Structure

```
nvidia-parakeet/
├── scripts/           # Deployment and management scripts
│   ├── common-logging.sh                    # Unified logging framework
│   ├── riva-000-setup-configuration.sh     # Interactive configuration
│   ├── riva-015-deploy-or-restart-aws-gpu-instance.sh     # AWS EC2 GPU deployment
│   ├── riva-025-transfer-nvidia-drivers.sh # NVIDIA driver management
│   ├── riva-070-setup-traditional-riva-server.sh       # Riva server with Parakeet
│   ├── riva-090-deploy-websocket-asr-application.sh    # WebSocket application
│   ├── riva-100-test-basic-integration.sh        # End-to-end testing
│   ├── check-driver-status.sh              # Driver status utility
│   └── test-logging.sh                     # Logging framework test
├── logs/              # Structured log files (auto-generated)
│   └── [script-name]_[timestamp]_pid[pid].log
├── src/               # Application source code
│   └── websocket/     # WebSocket server implementation
├── docs/              # Comprehensive documentation
│   ├── TROUBLESHOOTING.md
│   ├── API_REFERENCE.md
│   └── DEVELOPER_GUIDE.md
└── .env              # Configuration (created by setup script)
```

## 🎯 What Makes This Different

✅ **Real NVIDIA Parakeet**: Actual Riva ASR with Parakeet RNNT model, not mock responses  
✅ **Production Logging**: Comprehensive structured logging for easy debugging  
✅ **Multi-Strategy Deployment**: AWS, existing servers, or local development  
✅ **Streaming Architecture**: Real-time WebSocket with partial/final results  
✅ **Easy Debugging**: Detailed logs show exactly what went wrong and where  
✅ **Automated Setup**: Scripts handle driver installation, Riva deployment, testing  

## 🆘 Troubleshooting & Support

### Quick Debug Steps
1. **Check recent logs**: `ls -lat logs/ | head -5`
2. **Driver status**: `./scripts/check-driver-status.sh`  
3. **View specific failure**: `cat logs/[failed-script]_*.log`
4. **Test logging**: `./scripts/test-logging.sh`

### Documentation
- See `docs/TROUBLESHOOTING.md` for common issues and solutions
- Review `docs/API_REFERENCE.md` for WebSocket API details  
- Check `docs/DEVELOPER_GUIDE.md` for customization options

### Log Analysis
Every script generates detailed logs in `logs/` with:
- Exact commands executed with timing
- Full error output with context
- Section-based organization for easy navigation
- Resource usage and environment information

---

**Built by RNN-T experts for production deployment** 🎯