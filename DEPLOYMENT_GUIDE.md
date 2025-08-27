# Production RNN-T Deployment Guide

This guide provides step-by-step instructions to deploy a production-ready RNN-T (Recurrent Neural Network Transducer) speech transcription system on AWS GPU instances.

## 🎯 What This Deployment Does

- Deploys **actual SpeechBrain Conformer RNN-T model** (NOT mocks)
- Provides real-time speech transcription with GPU acceleration
- Supports both file upload and S3 audio transcription
- Includes word-level timestamps and confidence scores
- Production-ready with health checks and monitoring

## 📋 Prerequisites

- AWS Account with GPU instance permissions
- AWS CLI configured with credentials
- SSH key pair for EC2 access
- Python 3.8+ locally (for configuration scripts)

## 🚀 Quick Start (Complete Deployment)

For a fully automated deployment, run:

```bash
./scripts/step-000-run-complete-deployment.sh
```

This will execute all steps in sequence. For manual control, follow the step-by-step guide below.

## 📝 Step-by-Step Manual Deployment

### Step 000: Configuration Setup
```bash
./scripts/step-000-setup-configuration.sh
```
- Creates `.env` configuration file
- Collects AWS credentials and preferences
- Sets up deployment parameters

### Step 010: Deploy GPU Instance  
```bash
./scripts/step-010-deploy-gpu-instance.sh
```
- Launches AWS GPU instance (g4dn.xlarge recommended)
- Configures security groups and networking
- Sets up SSH access

### Step 020: Install RNN-T Server (Systemd Option)
```bash
./scripts/step-020-install-rnnt-server.sh
```
- Installs dependencies on GPU instance
- Downloads SpeechBrain RNN-T model
- Sets up systemd service
- **Alternative to Docker deployment**

### Step 025: Deploy RNN-T Docker (Recommended)
```bash
./scripts/step-025-deploy-rnnt-docker.sh
```
- Builds CUDA-enabled Docker container
- Deploys containerized RNN-T service
- Includes GPU passthrough and model caching
- **Recommended over systemd deployment**

### Step 035: Verify RNN-T Model
```bash
./scripts/step-035-verify-rnnt-model.sh
```
- Verifies GPU access and model loading
- Confirms RNN-T architecture
- Tests API endpoints
- Validates health checks

### Step 040: Test S3 Transcription
```bash
./scripts/step-040-test-s3-transcription.sh
```
- Tests with specific S3 audio file: `s3://dbm-cf-2-web/users/01ebc530-5041-7042-936c-6e516c3a0d20/audio/sessions/1b3fd9db-dfb0-4360-913f-7096d62c1b0a/chunk-002.wav`
- Demonstrates real RNN-T transcription
- Saves results with performance metrics

## 🔧 Script Spacing and Extensibility

Scripts are spaced by 5 numbers (000, 005, 010, 015, 020, 025, 030, 035, 040) to allow insertion of additional steps if needed during debugging or enhancement.

## 📊 API Endpoints

Once deployed, your RNN-T service provides:

### Health Check
```bash
GET http://YOUR-INSTANCE-IP:8000/health
```

### File Transcription
```bash
POST http://YOUR-INSTANCE-IP:8000/transcribe/file
Content-Type: multipart/form-data
Body: file=@your-audio.wav
```

### S3 Transcription
```bash
POST http://YOUR-INSTANCE-IP:8000/transcribe/s3
Content-Type: application/json
{
    "s3_uri": "s3://bucket/path/to/audio.wav",
    "language": "en-US"
}
```

## 🎛️ Service Management

### Docker Deployment Management
```bash
# On the GPU instance
cd ~/rnnt-deploy
./rnnt-ctl.sh {start|stop|restart|status|logs|health|rebuild}
```

### Systemd Deployment Management  
```bash
# On the GPU instance
cd /opt/rnnt
./rnnt-server-ctl.sh {start|stop|restart|status|logs|health}
```

## 🧪 Testing Your Deployment

### Test with curl
```bash
# Health check
curl http://YOUR-INSTANCE-IP:8000/health

# File transcription
curl -X POST 'http://YOUR-INSTANCE-IP:8000/transcribe/file' \
     -F 'file=@test-audio.wav'

# S3 transcription
curl -X POST 'http://YOUR-INSTANCE-IP:8000/transcribe/s3' \
     -H 'Content-Type: application/json' \
     -d '{
       "s3_uri": "s3://your-bucket/audio.wav",
       "language": "en-US"
     }'
```

## 🔍 Troubleshooting

### Check Container Logs
```bash
ssh -i your-key.pem ubuntu@YOUR-INSTANCE-IP
docker logs rnnt-server
```

### Verify GPU Access
```bash
ssh -i your-key.pem ubuntu@YOUR-INSTANCE-IP
docker exec rnnt-server nvidia-smi
```

### Model Loading Issues
```bash
# Check if model cache exists
docker exec rnnt-server ls -la /tmp/speechbrain_cache/

# Restart container to reload model
docker restart rnnt-server
```

## 💰 Cost Considerations

- **g4dn.xlarge**: ~$0.526/hour (recommended for development/testing)
- **g4dn.2xlarge**: ~$0.752/hour (better performance)
- **p3.2xlarge**: ~$3.06/hour (highest performance)

Remember to stop instances when not in use!

## 🔒 Security Notes

- Scripts automatically configure security groups for port 8000
- SSH access required for deployment
- AWS credentials are temporarily copied to instance
- Consider VPC deployment for production

## 📈 Performance

- **Real-time Factor**: Typically 0.1-0.3 (GPU accelerated)
- **Model**: SpeechBrain Conformer RNN-T (~1.5GB)
- **GPU Memory**: ~4-6GB during transcription
- **Cold Start**: 2-3 minutes for first transcription

## 🎉 Success Criteria

Your deployment is successful when:
- ✅ Health endpoint returns "healthy" status
- ✅ GPU acceleration is enabled
- ✅ S3 transcription test completes
- ✅ Response includes `"actual_transcription": true`
- ✅ Word-level timestamps are provided

## 📞 Support

If you encounter issues:
1. Check the specific step script that failed
2. Review container/service logs
3. Verify AWS permissions and quotas
4. Ensure GPU drivers are properly installed

---

**Note**: This deployment uses **real RNN-T transcription** with SpeechBrain, not mock responses. The system will actually transcribe your audio with high accuracy using GPU acceleration.