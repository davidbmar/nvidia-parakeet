#!/usr/bin/env python3
"""
Enhanced RNN-T Server with WebSocket Support
Adds real-time audio streaming capabilities to the production server
"""

import os
import sys
import uuid
from pathlib import Path

# Add parent directory to path for imports
sys.path.append(str(Path(__file__).parent.parent))

# Import original server components but avoid route conflicts
from rnnt_server import (
    app, logger, RNNT_SERVER_PORT, RNNT_SERVER_HOST, RNNT_MODEL_SOURCE,
    MODEL_LOADED, MODEL_LOAD_TIME, LOG_LEVEL, DEV_MODE,
    asr_model, load_model, health_check, transcribe_file, transcribe_s3,
    torch, uvicorn
)

# Import WebSocket components
from websocket.websocket_handler import WebSocketHandler
from fastapi import WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles

# Create WebSocket handler instance
ws_handler = None

@app.on_event("startup")
async def startup_event_enhanced():
    """Enhanced startup with WebSocket support"""
    global ws_handler
    
    logger.info("🚀 Starting Enhanced RNN-T Server with WebSocket Support")
    logger.info(f"Configuration: port={RNNT_SERVER_PORT}, model={RNNT_MODEL_SOURCE}")
    
    # Load model on startup
    await load_model()
    
    # Initialize WebSocket handler
    ws_handler = WebSocketHandler(asr_model)
    logger.info("✅ WebSocket handler initialized")

# Remove the original root route to avoid conflicts
original_routes = app.routes[:]
app.routes.clear()
for route in original_routes:
    if hasattr(route, 'path') and route.path == '/':
        continue  # Skip the original root route
    app.routes.append(route)

# Mount static files for web interface
app.mount("/static", StaticFiles(directory="static"), name="static")
app.mount("/examples", StaticFiles(directory="examples"), name="examples")

@app.get("/")
async def root_enhanced():
    """Enhanced root endpoint with WebSocket info"""
    return {
        "service": "Production RNN-T Server with WebSocket Streaming",
        "version": "2.0.0",
        "model": RNNT_MODEL_SOURCE,
        "status": "READY" if MODEL_LOADED else "LOADING",
        "architecture": "RNN-T Conformer",
        "gpu_available": torch.cuda.is_available(),
        "device": "cuda" if torch.cuda.is_available() else "cpu",
        "model_load_time": f"{MODEL_LOAD_TIME:.1f}s" if MODEL_LOAD_TIME else "not loaded",
        "endpoints": {
            "rest": ["/health", "/transcribe/file", "/transcribe/s3"],
            "websocket": ["/ws/transcribe"],
            "web": ["/static/index.html", "/examples/simple-client.html"]
        },
        "features": {
            "real_time_streaming": True,
            "word_level_timestamps": True,
            "partial_results": True,
            "vad": True
        },
        "note": "Production-ready speech recognition with real-time streaming"
    }

@app.websocket("/ws/transcribe")
async def websocket_endpoint(websocket: WebSocket):
    """
    WebSocket endpoint for real-time audio streaming
    
    Protocol:
    - Binary messages: PCM16 audio data
    - JSON messages: Control commands
    - Responses: JSON transcription results
    """
    client_id = websocket.query_params.get('client_id', str(uuid.uuid4()))
    
    try:
        # Accept connection
        await ws_handler.connect(websocket, client_id)
        
        # Handle messages
        while True:
            try:
                # Receive message (binary or text)
                message = await websocket.receive()
                
                if "bytes" in message:
                    # Binary audio data
                    await ws_handler.handle_message(
                        websocket, 
                        client_id, 
                        message["bytes"]
                    )
                elif "text" in message:
                    # JSON control message
                    await ws_handler.handle_message(
                        websocket,
                        client_id,
                        message["text"].encode('utf-8')
                    )
                    
            except WebSocketDisconnect:
                logger.info(f"WebSocket client {client_id} disconnected")
                break
            except Exception as e:
                logger.error(f"WebSocket message error: {e}")
                # Don't try to send error if connection is closed
                try:
                    await ws_handler.send_error(websocket, str(e))
                except:
                    # Connection already closed, break the loop
                    break
                
    except Exception as e:
        logger.error(f"WebSocket connection error: {e}")
    finally:
        # Clean up connection
        await ws_handler.disconnect(client_id)

@app.get("/demo")
async def demo_redirect():
    """Redirect to demo page"""
    from fastapi.responses import RedirectResponse
    return RedirectResponse(url="/static/index.html")

@app.get("/ws/status")
async def websocket_status():
    """Get WebSocket connection status"""
    if not ws_handler:
        return {"status": "not_initialized"}
    
    return {
        "status": "active",
        "active_connections": len(ws_handler.active_connections),
        "clients": list(ws_handler.active_connections.keys())
    }

# Enhanced health check
@app.get("/health/extended")
async def health_check_extended():
    """Extended health check with WebSocket info"""
    base_health = await health_check()
    
    # Add WebSocket information
    base_health["websocket"] = {
        "enabled": True,
        "handler_ready": ws_handler is not None,
        "active_connections": len(ws_handler.active_connections) if ws_handler else 0
    }
    
    return base_health

if __name__ == "__main__":
    print("=" * 60)
    print("🎯 Enhanced RNN-T Server with WebSocket Streaming")
    print(f"📝 Model: {RNNT_MODEL_SOURCE}")
    print(f"🔥 GPU: {'Available' if torch.cuda.is_available() else 'Not Available'}")
    print(f"🌐 REST API: http://{RNNT_SERVER_HOST}:{RNNT_SERVER_PORT}")
    print(f"🔌 WebSocket: ws://{RNNT_SERVER_HOST}:{RNNT_SERVER_PORT}/ws/transcribe")
    print(f"🖥️ Demo UI: http://{RNNT_SERVER_HOST}:{RNNT_SERVER_PORT}/static/index.html")
    print("=" * 60)
    
    uvicorn.run(
        app, 
        host=RNNT_SERVER_HOST, 
        port=RNNT_SERVER_PORT,
        log_level=LOG_LEVEL.lower(),
        access_log=DEV_MODE
    )