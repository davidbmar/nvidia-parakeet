#!/usr/bin/env python3
"""
Production HTTPS WebSocket Server for RNN-T Transcription
Integrates all our performance fixes and optimizations

Features:
- SSL/HTTPS support with self-signed certificates
- WebSocket transcription with our optimized components
- Static file serving for web UI
- Real SpeechBrain RNN-T transcription
- Performance monitoring and logging
"""

import ssl
import asyncio
import logging
import sys
import os
from pathlib import Path

# Add project root to Python path
PROJECT_ROOT = Path(__file__).parent
sys.path.insert(0, str(PROJECT_ROOT))

# FastAPI imports
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse, JSONResponse
import uvicorn

# Our optimized WebSocket components
from websocket.websocket_handler import WebSocketHandler

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('/opt/rnnt/logs/https-server.log', mode='a')
    ]
)
logger = logging.getLogger(__name__)

# Create FastAPI app
app = FastAPI(
    title="RNN-T Production HTTPS Server",
    description="Production WebSocket server for real-time speech transcription",
    version="1.0.0"
)

# Global WebSocket handler
websocket_handler = None

@app.on_event("startup")
async def startup_event():
    """Initialize services on startup"""
    global websocket_handler
    
    logger.info("🚀 Starting RNN-T HTTPS Server with optimized components...")
    
    # Create logs directory
    os.makedirs('/opt/rnnt/logs', exist_ok=True)
    
    # Initialize WebSocket handler with our fixes
    try:
        websocket_handler = WebSocketHandler()
        logger.info("✅ WebSocket handler initialized with optimizations")
    except Exception as e:
        logger.error(f"❌ Failed to initialize WebSocket handler: {e}")
        sys.exit(1)
    
    logger.info("🎉 Server startup complete - ready for transcription!")

@app.get("/")
async def root():
    """Root endpoint"""
    return {
        "service": "RNN-T Production HTTPS Server", 
        "status": "active",
        "version": "1.0.0",
        "features": [
            "Real-time WebSocket transcription",
            "SpeechBrain RNN-T model",
            "Mixed precision inference (2x speedup)", 
            "Enhanced VAD with ZCR",
            "CUDA memory optimization",
            "SSL/HTTPS support"
        ]
    }

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    try:
        # Check if model is loaded
        model_status = "loaded" if websocket_handler and websocket_handler.asr_model else "not_loaded"
        
        return {
            "status": "healthy",
            "model_status": model_status,
            "websocket_handler": "active" if websocket_handler else "inactive"
        }
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return {"status": "unhealthy", "error": str(e)}

@app.get("/ws/status")
async def websocket_status():
    """WebSocket status endpoint"""
    return {
        "websocket_endpoint": "/ws/transcribe",
        "protocol": "WSS (WebSocket Secure)",
        "status": "active" if websocket_handler else "inactive",
        "active_connections": len(websocket_handler.active_connections) if websocket_handler else 0
    }

@app.websocket("/ws/transcribe")
async def websocket_transcribe(websocket: WebSocket):
    """WebSocket endpoint for real-time transcription"""
    if not websocket_handler:
        logger.error("WebSocket handler not initialized")
        await websocket.close(code=1011, reason="Server not ready")
        return
    
    # Extract client ID from query params
    client_id = websocket.query_params.get('client_id', f'client_{id(websocket)}')
    
    logger.info(f"🔌 WebSocket connection attempt: {client_id}")
    
    try:
        # Accept connection
        await websocket.accept()
        logger.info(f"✅ WebSocket connected: {client_id}")
        
        # Handle the WebSocket session using our optimized handler
        await websocket_handler.handle_websocket(websocket, client_id)
        
    except WebSocketDisconnect:
        logger.info(f"🔌 WebSocket disconnected: {client_id}")
    except Exception as e:
        logger.error(f"❌ WebSocket error for {client_id}: {e}")
        try:
            await websocket.close(code=1011, reason="Server error")
        except:
            pass

# Mount static files for web UI
if os.path.exists('/opt/rnnt/static'):
    app.mount("/static", StaticFiles(directory="/opt/rnnt/static"), name="static")
    logger.info("📁 Static files mounted at /static")

# Serve main UI at /static/index.html
@app.get("/ui", response_class=HTMLResponse)
async def serve_ui():
    """Serve the main transcription UI"""
    ui_path = Path("/opt/rnnt/static/index.html")
    if ui_path.exists():
        return HTMLResponse(ui_path.read_text())
    else:
        return HTMLResponse("""
        <html>
            <body>
                <h1>RNN-T Transcription Server</h1>
                <p>Server is running but UI files not found.</p>
                <p>WebSocket endpoint: <code>wss://server/ws/transcribe</code></p>
            </body>
        </html>
        """)

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    """Global exception handler"""
    logger.error(f"Global exception: {exc}")
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error", "detail": str(exc)}
    )

if __name__ == "__main__":
    # SSL Configuration
    ssl_cert_path = "/opt/rnnt/server.crt"
    ssl_key_path = "/opt/rnnt/server.key"
    
    if not os.path.exists(ssl_cert_path) or not os.path.exists(ssl_key_path):
        logger.error(f"❌ SSL certificates not found:")
        logger.error(f"   Certificate: {ssl_cert_path}")
        logger.error(f"   Key: {ssl_key_path}")
        logger.error("Run the HTTPS setup script first!")
        sys.exit(1)
    
    logger.info(f"🔒 SSL Certificate: {ssl_cert_path}")
    logger.info(f"🔑 SSL Key: {ssl_key_path}")
    
    # Start HTTPS server
    try:
        logger.info("🚀 Starting HTTPS server on port 443...")
        uvicorn.run(
            "rnnt-https-server:app",
            host="0.0.0.0",
            port=443,
            ssl_keyfile=ssl_key_path,
            ssl_certfile=ssl_cert_path,
            ssl_version=ssl.PROTOCOL_TLS_SERVER,
            ssl_cert_reqs=ssl.CERT_NONE,
            log_level="info",
            access_log=True,
            loop="asyncio"
        )
    except Exception as e:
        logger.error(f"❌ Failed to start HTTPS server: {e}")
        sys.exit(1)