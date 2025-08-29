#!/usr/bin/env python3
"""
WebSocket Handler for Real-time Audio Streaming
Manages WebSocket connections and message routing
"""

import json
import asyncio
from typing import Dict, Any, Optional
from fastapi import WebSocket, WebSocketDisconnect
import logging
from datetime import datetime

from .audio_processor import AudioProcessor
from .transcription_stream import TranscriptionStream

logger = logging.getLogger(__name__)


class WebSocketHandler:
    """
    Handles WebSocket connections for real-time transcription
    
    Features:
    - Connection lifecycle management
    - Message routing and validation
    - Error handling and recovery
    - Client state management
    """
    
    def __init__(self, asr_model):
        """
        Initialize WebSocket handler
        
        Args:
            asr_model: Loaded RNN-T model for transcription
        """
        self.asr_model = asr_model
        self.active_connections: Dict[str, WebSocket] = {}
        self.connection_states: Dict[str, Dict] = {}
        
        logger.info("WebSocketHandler initialized")
    
    async def connect(self, websocket: WebSocket, client_id: str):
        """
        Handle new WebSocket connection
        
        Args:
            websocket: WebSocket connection
            client_id: Unique client identifier
        """
        await websocket.accept()
        
        # Store connection
        self.active_connections[client_id] = websocket
        
        # Initialize client state
        self.connection_states[client_id] = {
            'connected_at': datetime.utcnow().isoformat(),
            'audio_processor': AudioProcessor(),
            'transcription_stream': TranscriptionStream(
                self.asr_model,
                device='cuda' if torch.cuda.is_available() else 'cpu'
            ),
            'total_audio_duration': 0.0,
            'total_segments': 0,
            'is_recording': False
        }
        
        # Send welcome message
        await self.send_message(websocket, {
            'type': 'connection',
            'status': 'connected',
            'client_id': client_id,
            'message': 'WebSocket connected successfully',
            'protocol_version': '1.0',
            'supported_audio_formats': {
                'sample_rates': [16000, 44100, 48000],
                'encodings': ['pcm16', 'float32'],
                'channels': [1, 2]
            }
        })
        
        logger.info(f"Client {client_id} connected")
    
    async def disconnect(self, client_id: str):
        """
        Handle WebSocket disconnection
        
        Args:
            client_id: Client identifier
        """
        if client_id in self.active_connections:
            del self.active_connections[client_id]
        
        if client_id in self.connection_states:
            state = self.connection_states[client_id]
            logger.info(
                f"Client {client_id} disconnected. "
                f"Duration: {state.get('total_audio_duration', 0):.1f}s, "
                f"Segments: {state.get('total_segments', 0)}"
            )
            del self.connection_states[client_id]
    
    async def handle_message(
        self,
        websocket: WebSocket,
        client_id: str,
        message: bytes
    ):
        """
        Route and handle incoming WebSocket messages
        
        Args:
            websocket: WebSocket connection
            client_id: Client identifier
            message: Raw message bytes
        """
        try:
            # Check if message is JSON control message or binary audio
            if message[:1] == b'{':
                # JSON control message
                await self._handle_control_message(websocket, client_id, message)
            else:
                # Binary audio data
                await self._handle_audio_data(websocket, client_id, message)
                
        except Exception as e:
            logger.error(f"Message handling error for {client_id}: {e}")
            await self.send_error(websocket, str(e))
    
    async def _handle_control_message(
        self,
        websocket: WebSocket,
        client_id: str,
        message: bytes
    ):
        """
        Handle JSON control messages
        
        Args:
            websocket: WebSocket connection
            client_id: Client identifier
            message: JSON message bytes
        """
        try:
            data = json.loads(message.decode('utf-8'))
            message_type = data.get('type')
            
            if message_type == 'start_recording':
                await self._start_recording(websocket, client_id, data)
            
            elif message_type == 'stop_recording':
                await self._stop_recording(websocket, client_id)
            
            elif message_type == 'configure':
                await self._configure_stream(websocket, client_id, data)
            
            elif message_type == 'ping':
                await self.send_message(websocket, {'type': 'pong'})
            
            else:
                logger.warning(f"Unknown message type: {message_type}")
                
        except json.JSONDecodeError as e:
            await self.send_error(websocket, f"Invalid JSON: {e}")
    
    async def _handle_audio_data(
        self,
        websocket: WebSocket,
        client_id: str,
        audio_data: bytes
    ):
        """
        Handle binary audio data
        
        Args:
            websocket: WebSocket connection
            client_id: Client identifier
            audio_data: Raw audio bytes
        """
        state = self.connection_states.get(client_id)
        if not state or not state.get('is_recording'):
            return
        
        try:
            # Process audio chunk
            audio_processor = state['audio_processor']
            transcription_stream = state['transcription_stream']
            
            # Process the audio chunk
            audio_array, is_segment_end = audio_processor.process_chunk(audio_data)
            
            # If segment ended, transcribe it
            if is_segment_end:
                segment = audio_processor.get_segment()
                if segment is not None and len(segment) > 0:
                    # Transcribe segment
                    result = await transcription_stream.transcribe_segment(
                        segment,
                        sample_rate=16000,
                        is_final=True
                    )
                    
                    # Send transcription result
                    await self.send_message(websocket, result)
                    
                    # Update state
                    state['total_segments'] += 1
                    state['total_audio_duration'] += len(segment) / 16000
            
            # Optionally send partial results for long segments
            elif len(audio_processor.current_segment) > 16000:  # > 1 second
                partial_segment = np.array(audio_processor.current_segment)
                result = await transcription_stream.transcribe_segment(
                    partial_segment,
                    sample_rate=16000,
                    is_final=False
                )
                result['type'] = 'partial'
                await self.send_message(websocket, result)
                
        except Exception as e:
            logger.error(f"Audio processing error: {e}")
            await self.send_error(websocket, f"Audio processing failed: {e}")
    
    async def _start_recording(
        self,
        websocket: WebSocket,
        client_id: str,
        config: Dict[str, Any]
    ):
        """
        Start recording session
        
        Args:
            websocket: WebSocket connection
            client_id: Client identifier
            config: Recording configuration
        """
        state = self.connection_states.get(client_id)
        if not state:
            return
        
        # Reset processors
        state['audio_processor'].reset()
        state['transcription_stream'].reset()
        state['is_recording'] = True
        
        # Send confirmation
        await self.send_message(websocket, {
            'type': 'recording_started',
            'timestamp': datetime.utcnow().isoformat(),
            'config': config
        })
        
        logger.info(f"Recording started for {client_id}")
    
    async def _stop_recording(self, websocket: WebSocket, client_id: str):
        """
        Stop recording session
        
        Args:
            websocket: WebSocket connection
            client_id: Client identifier
        """
        state = self.connection_states.get(client_id)
        if not state:
            return
        
        state['is_recording'] = False
        
        # Process any remaining audio
        audio_processor = state['audio_processor']
        segment = audio_processor.get_segment()
        
        if segment is not None and len(segment) > 0:
            transcription_stream = state['transcription_stream']
            result = await transcription_stream.transcribe_segment(
                segment,
                sample_rate=16000,
                is_final=True
            )
            await self.send_message(websocket, result)
        
        # Send final transcript
        full_transcript = state['transcription_stream'].get_full_transcript()
        
        await self.send_message(websocket, {
            'type': 'recording_stopped',
            'final_transcript': full_transcript,
            'total_duration': state['total_audio_duration'],
            'total_segments': state['total_segments'],
            'timestamp': datetime.utcnow().isoformat()
        })
        
        logger.info(f"Recording stopped for {client_id}")
    
    async def _configure_stream(
        self,
        websocket: WebSocket,
        client_id: str,
        config: Dict[str, Any]
    ):
        """
        Configure stream parameters
        
        Args:
            websocket: WebSocket connection
            client_id: Client identifier
            config: Stream configuration
        """
        state = self.connection_states.get(client_id)
        if not state:
            return
        
        # Update audio processor configuration
        processor = state['audio_processor']
        
        if 'sample_rate' in config:
            processor.target_sample_rate = config['sample_rate']
        if 'vad_threshold' in config:
            processor.vad_threshold = config['vad_threshold']
        if 'silence_duration' in config:
            processor.silence_duration_s = config['silence_duration']
        
        await self.send_message(websocket, {
            'type': 'configured',
            'config': config
        })
    
    async def send_message(self, websocket: WebSocket, message: Dict[str, Any]):
        """
        Send JSON message to client
        
        Args:
            websocket: WebSocket connection
            message: Message dictionary
        """
        try:
            await websocket.send_json(message)
        except Exception as e:
            logger.error(f"Failed to send message: {e}")
            # Remove from active connections if send fails
            client_id = None
            for cid, ws in self.active_connections.items():
                if ws == websocket:
                    client_id = cid
                    break
            if client_id and client_id in self.active_connections:
                del self.active_connections[client_id]
    
    async def send_error(self, websocket: WebSocket, error: str):
        """
        Send error message to client
        
        Args:
            websocket: WebSocket connection
            error: Error description
        """
        await self.send_message(websocket, {
            'type': 'error',
            'error': error,
            'timestamp': datetime.utcnow().isoformat()
        })


# Import torch for device checking
import torch
import numpy as np