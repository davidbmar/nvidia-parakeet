# Troubleshooting Guide - Production RNN-T Server

## Quick Diagnostics

### Server Status Check
```bash
# SSH into your instance
ssh -i your-key.pem ubuntu@your-instance-ip

# Check service status
sudo systemctl status rnnt-server

# View recent logs
sudo journalctl -u rnnt-server -n 50
```

### Health Check
```bash
# Test server response
curl http://your-instance-ip:8000/health

# Test basic connectivity
curl http://your-instance-ip:8000/
```

## Common Issues and Solutions

### 1. Server Won't Start

#### Symptoms
- `systemctl status rnnt-server` shows "failed"
- No response from server endpoints
- Service keeps restarting

#### Diagnosis
```bash
# Check detailed logs
sudo journalctl -u rnnt-server -f

# Check if port is in use
sudo netstat -tlnp | grep :8000

# Verify Python environment
cd /opt/rnnt && source venv/bin/activate && python --version
```

#### Solutions

**Missing Dependencies:**
```bash
cd /opt/rnnt
source venv/bin/activate
pip install -r requirements.txt
```

**GPU Driver Issues:**
```bash
# Check GPU
nvidia-smi

# Reinstall drivers if needed
sudo ubuntu-drivers autoinstall
sudo reboot
```

**Permission Issues:**
```bash
sudo chown -R ubuntu:ubuntu /opt/rnnt
sudo chmod +x /opt/rnnt/rnnt-server.py
```

### 2. Model Loading Fails

#### Symptoms
- Health endpoint shows `"model_loaded": false`
- Transcription requests return 503 errors
- Logs show model download/loading errors

#### Diagnosis
```bash
# Check model directory
ls -la /opt/rnnt/models/

# Test model loading manually
cd /opt/rnnt
source venv/bin/activate
python -c "from speechbrain.inference import EncoderDecoderASR; print('Import OK')"
```

#### Solutions

**Network/Download Issues:**
```bash
# Clear model cache and retry
rm -rf /opt/rnnt/models/*
sudo systemctl restart rnnt-server
```

**Memory Issues:**
```bash
# Check available memory
free -h

# Check GPU memory
nvidia-smi

# Consider using CPU mode temporarily
export CUDA_VISIBLE_DEVICES=""
sudo systemctl restart rnnt-server
```

**SpeechBrain Version Issues:**
```bash
cd /opt/rnnt
source venv/bin/activate
pip uninstall speechbrain
pip install speechbrain>=1.0.0
```

### 3. Transcription Fails

#### Symptoms
- Server starts but transcription requests fail
- 500 errors on `/transcribe/file` endpoint
- Audio files not processing

#### Diagnosis
```bash
# Test with simple audio file
curl -X POST 'http://localhost:8000/transcribe/file' \
     -F 'file=@test.wav' -v

# Check audio file format
file test.wav

# Test audio preprocessing
cd /opt/rnnt && source venv/bin/activate
python -c "import torchaudio; print(torchaudio.load('test.wav'))"
```

#### Solutions

**Audio Format Issues:**
```bash
# Convert to supported format
ffmpeg -i input.mp3 -ar 16000 -ac 1 output.wav
```

**CUDA/GPU Issues:**
```bash
# Force CPU mode
export CUDA_VISIBLE_DEVICES=""

# Or check CUDA installation
python -c "import torch; print(torch.cuda.is_available())"
```

**Memory/Timeout Issues:**
```bash
# Check GPU memory during transcription
watch nvidia-smi

# Increase timeout in client request
curl --max-time 120 ...
```

### 4. Performance Issues

#### Symptoms
- Very slow transcription
- High CPU/GPU usage
- Memory leaks

#### Diagnosis
```bash
# Monitor resources
htop
nvidia-smi

# Check server logs for timing
sudo journalctl -u rnnt-server | grep "processing_time"

# Test with small audio file
# Create 1-second test file
ffmpeg -f lavfi -i "sine=frequency=440:duration=1" test-1s.wav
```

#### Solutions

**GPU Not Utilized:**
```bash
# Verify CUDA setup
python -c "import torch; print(torch.cuda.get_device_name(0))"

# Check environment
env | grep CUDA
```

**Model Not Cached:**
```bash
# Pre-load model
cd /opt/rnnt
python download_model.py
```

**Insufficient Resources:**
```bash
# Check instance type
curl -s http://169.254.169.254/latest/meta-data/instance-type

# Consider upgrading to larger instance
```

### 5. S3 Integration Issues

#### Symptoms
- S3 transcription fails
- Permission errors accessing S3
- Files not found

#### Diagnosis
```bash
# Test S3 access
aws s3 ls s3://your-bucket/

# Check AWS credentials
aws configure list

# Test IAM permissions
aws iam get-user
```

#### Solutions

**Missing Permissions:**
```bash
# Attach IAM role with S3 permissions
aws iam attach-role-policy --role-name your-role \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
```

**Wrong Region:**
```bash
# Check S3 bucket region
aws s3api get-bucket-location --bucket your-bucket

# Update AWS_REGION in .env
```

**Credentials Issues:**
```bash
# Use IAM role instead of keys
# Remove AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from .env
```

### 6. Network/Connectivity Issues

#### Symptoms
- Cannot reach server from outside
- Timeouts on requests
- Connection refused

#### Diagnosis
```bash
# Check if service is listening
sudo netstat -tlnp | grep :8000

# Test local connectivity
curl http://localhost:8000/

# Check security group rules
aws ec2 describe-security-groups --group-ids sg-your-id
```

#### Solutions

**Security Group Issues:**
```bash
# Add inbound rule for port 8000
aws ec2 authorize-security-group-ingress \
    --group-id sg-your-id \
    --protocol tcp \
    --port 8000 \
    --cidr 0.0.0.0/0
```

**Firewall Issues:**
```bash
# Check Ubuntu firewall
sudo ufw status

# Allow port if needed
sudo ufw allow 8000
```

**Server Configuration:**
```bash
# Ensure server binds to all interfaces
grep "host=" /opt/rnnt/rnnt-server.py
# Should show: host="0.0.0.0"
```

## Advanced Debugging

### Enable Debug Logging
```bash
# Edit .env file
echo "LOG_LEVEL=DEBUG" >> /opt/rnnt/.env

# Restart service
sudo systemctl restart rnnt-server

# View debug logs
sudo journalctl -u rnnt-server -f
```

### Manual Server Testing
```bash
# Run server manually for debugging
cd /opt/rnnt
source venv/bin/activate
python rnnt-server.py
```

### Resource Monitoring
```bash
# Real-time monitoring
watch -n 1 'echo "=== CPU/Memory ===" && top -bn1 | head -20 && echo -e "\n=== GPU ===" && nvidia-smi'
```

### Model Testing
```bash
cd /opt/rnnt && source venv/bin/activate

# Test model loading
python -c "
import torch
from speechbrain.inference import EncoderDecoderASR
print('Loading model...')
model = EncoderDecoderASR.from_hparams(
    source='speechbrain/asr-conformer-transformerlm-librispeech',
    savedir='./models/asr-conformer-transformerlm-librispeech'
)
print('Model loaded successfully')
print('CUDA available:', torch.cuda.is_available())
print('Model device:', model.device)
"
```

## Log Analysis

### Important Log Patterns

**Successful Startup:**
```
🚀 Starting Production RNN-T Transcription Server
✅ RNN-T model loaded successfully
Server running on http://0.0.0.0:8000
```

**Model Loading:**
```
Loading SpeechBrain Conformer model
Model download completed successfully
GPU: Tesla T4 (15.0GB)
```

**Transcription Success:**
```
Processing: audio.wav (960044 bytes)
Transcribing 10.0s audio with RNN-T
✅ Transcription: 'HELLO WORLD...' (150ms)
```

**Common Error Patterns:**
```
❌ Model loading failed
CUDA out of memory
Audio preprocessing failed
Connection timeout
```

### Log Locations
- **System Service:** `sudo journalctl -u rnnt-server`
- **Manual Run:** Console output when running directly
- **Application Logs:** `/opt/rnnt/logs/` (if configured)

## Performance Tuning

### GPU Memory Optimization
```bash
# Check GPU memory usage
nvidia-smi

# Clear GPU memory cache
python -c "import torch; torch.cuda.empty_cache()"
```

### Model Optimization
```bash
# Pre-download and cache model
cd /opt/rnnt
source venv/bin/activate
python download_model.py
```

### System Optimization
```bash
# Increase file limits
echo "fs.file-max = 65536" | sudo tee -a /etc/sysctl.conf

# Optimize TCP settings
echo "net.core.somaxconn = 65536" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

## Getting Help

### Information to Collect
Before seeking support, collect:

1. **System Info:**
   ```bash
   # Instance details
   curl -s http://169.254.169.254/latest/meta-data/instance-type
   nvidia-smi
   cat /etc/os-release
   ```

2. **Service Status:**
   ```bash
   sudo systemctl status rnnt-server
   sudo journalctl -u rnnt-server -n 100 --no-pager
   ```

3. **Configuration:**
   ```bash
   # Remove sensitive data first!
   cat /opt/rnnt/.env | grep -v KEY | grep -v SECRET
   ```

4. **Test Results:**
   ```bash
   curl -s http://localhost:8000/health | jq .
   ```

### Support Channels
- Check GitHub issues for similar problems
- Review documentation and API reference
- Test with minimal examples first
- Provide complete error messages and logs

## Preventive Measures

### Regular Maintenance
```bash
# Weekly log cleanup
sudo journalctl --vacuum-time=7d

# Monthly model cache cleanup
rm -rf /opt/rnnt/models/.cache/*

# Monitor disk space
df -h
```

### Backup Strategy
```bash
# Backup configuration
cp /opt/rnnt/.env /opt/rnnt/.env.backup

# Create AMI snapshot for disaster recovery
aws ec2 create-image --instance-id i-your-instance --name rnnt-backup
```

### Monitoring Setup
```bash
# Simple health check script
echo '#!/bin/bash
if ! curl -f http://localhost:8000/health >/dev/null 2>&1; then
    echo "RNN-T server down, restarting..."
    sudo systemctl restart rnnt-server
fi' > /opt/rnnt/health-check.sh

chmod +x /opt/rnnt/health-check.sh

# Add to cron
echo "*/5 * * * * /opt/rnnt/health-check.sh" | crontab -
```