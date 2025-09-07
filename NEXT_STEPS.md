# Getting Real Riva Transcription Working

## Current Status
✅ **riva-055 completed** - System integration tested (but using MOCK mode)  
❌ **Real transcription** - Still using mock responses in WebSocket app

## Next Steps: Execute These Scripts In Order

### **Step 1: Test Riva Connectivity**
```bash
./scripts/riva-060-test-riva-connectivity.sh
```
**What it does**: TESTS direct connection to Riva server and lists available models  
**Expected result**: Should show "conformer_en_US_parakeet_rnnt" in available models  
**Checkpoint**: `RIVA_CONNECTIVITY_TEST=passed` added to .env

### **Step 2: Test File Transcription** 
```bash
./scripts/riva-065-test-file-transcription.sh
```
**What it does**: TESTS offline transcription of audio files using real Riva  
**Expected result**: Should transcribe synthetic audio and show performance metrics  
**Checkpoint**: `RIVA_FILE_TRANSCRIPTION_TEST=passed` added to .env

### **Step 3: Test Streaming Transcription**
```bash  
./scripts/riva-070-test-streaming-transcription.sh
```
**What it does**: TESTS real-time streaming with partial → final results  
**Expected result**: Should show progressive partial results from real Riva  
**Checkpoint**: `RIVA_STREAMING_TEST=passed` added to .env

### **Step 4: Enable Real Riva Mode**
```bash
./scripts/riva-075-enable-real-riva-mode.sh
```
**What it does**: CONFIGURES WebSocket app to use real Riva (not mock)  
**Changes made**: Updates `mock_mode=True` → `mock_mode=False` in transcription_stream.py  
**Action**: Restarts WebSocket server with real Riva integration  
**Checkpoint**: `RIVA_REAL_MODE_ENABLED=true` added to .env

### **Step 5: Test End-to-End Pipeline**
```bash
./scripts/riva-080-test-end-to-end-transcription.sh  
```
**What it does**: TESTS complete WebSocket → Riva → results pipeline  
**Expected result**: WebSocket uploads return real transcription (not mock phrases)  
**Checkpoint**: `RIVA_END_TO_END_TEST=passed` added to .env

## What Changes From Mock to Real

### Before (Mock Mode)
- WebSocket receives audio → returns fake phrases like "Hello this is a mock transcription"
- No actual Riva processing
- Instant responses with pre-defined text

### After (Real Mode)  
- WebSocket receives audio → sends to Riva via gRPC → returns actual transcription
- Real ASR processing on GPU
- Performance-based response times

## Key Files That Get Modified

1. **websocket/transcription_stream.py:44**
   - `RivaASRClient(mock_mode=True)` → `RivaASRClient(mock_mode=False)`

2. **Environment Configuration**
   - Uses existing .env settings (RIVA_HOST, RIVA_PORT, RIVA_MODEL)
   - No .env changes needed - scripts just add status flags

## Rollback Plan

If real mode has issues, rollback:
```bash
ssh -i ~/.ssh/${SSH_KEY_NAME}.pem ubuntu@${GPU_INSTANCE_IP} \
  'cd /opt/riva-app && cp websocket/transcription_stream.py.backup.mock websocket/transcription_stream.py'
```

## Success Criteria

After all scripts complete:
- ✅ Direct Riva connectivity confirmed
- ✅ File transcription working  
- ✅ Streaming transcription working
- ✅ WebSocket app using real Riva
- ✅ End-to-end pipeline functional
- 🎉 **Real-time transcription is LIVE!**

## Next Execute

Start with:
```bash
./scripts/riva-060-test-riva-connectivity.sh
```

Each script checks the previous step passed before proceeding, so execute in order.