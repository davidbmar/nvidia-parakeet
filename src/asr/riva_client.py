#!/usr/bin/env python3
"""
NVIDIA Riva ASR Client Wrapper
Provides a thin wrapper around Riva client SDK for streaming transcription
Maintains compatibility with existing WebSocket JSON contract
"""

import os
import asyncio
import logging
import time
from typing import AsyncGenerator, Dict, Any, Optional, List, Tuple
from datetime import datetime
import numpy as np
import grpc
from dataclasses import dataclass
from enum import Enum

try:
    import riva.client
    from riva.client.proto import riva_asr_pb2, riva_asr_pb2_grpc
except ImportError:
    raise ImportError(
        "Riva client not installed. Run: pip install nvidia-riva-client"
    )

logger = logging.getLogger(__name__)


class TranscriptionEventType(Enum):
    """Types of transcription events"""
    PARTIAL = "partial"
    FINAL = "transcription"
    ERROR = "error"


@dataclass
class RivaConfig:
    """Riva ASR configuration"""
    host: str = os.getenv("RIVA_HOST", "localhost")
    port: int = int(os.getenv("RIVA_PORT", "50051"))
    ssl: bool = os.getenv("RIVA_SSL", "false").lower() == "true"
    ssl_cert: Optional[str] = os.getenv("RIVA_SSL_CERT")
    api_key: Optional[str] = os.getenv("RIVA_API_KEY")
    
    # Model settings
    model: str = os.getenv("RIVA_MODEL", "conformer_en_US_parakeet_rnnt")
    language_code: str = os.getenv("RIVA_LANGUAGE_CODE", "en-US")
    enable_punctuation: bool = os.getenv("RIVA_ENABLE_AUTOMATIC_PUNCTUATION", "true").lower() == "true"
    enable_word_offsets: bool = os.getenv("RIVA_ENABLE_WORD_TIME_OFFSETS", "true").lower() == "true"
    
    # Connection settings
    timeout_ms: int = int(os.getenv("RIVA_TIMEOUT_MS", "5000"))
    max_retries: int = int(os.getenv("RIVA_MAX_RETRIES", "3"))
    retry_delay_ms: int = int(os.getenv("RIVA_RETRY_DELAY_MS", "1000"))
    
    # Performance settings
    max_batch_size: int = int(os.getenv("RIVA_MAX_BATCH_SIZE", "8"))
    chunk_size_bytes: int = int(os.getenv("RIVA_CHUNK_SIZE_BYTES", "8192"))
    enable_partials: bool = os.getenv("RIVA_ENABLE_PARTIAL_RESULTS", "true").lower() == "true"
    partial_interval_ms: int = int(os.getenv("RIVA_PARTIAL_RESULT_INTERVAL_MS", "300"))


class RivaASRClient:
    """
    Thin wrapper around Riva ASR client for streaming transcription
    Maintains compatibility with existing WebSocket JSON contract
    """
    
    def __init__(self, config: Optional[RivaConfig] = None):
        """
        Initialize Riva ASR client
        
        Args:
            config: Riva configuration (uses env vars if not provided)
        """
        self.config = config or RivaConfig()
        self.auth = None
        self.asr_service = None
        self.connected = False
        self.segment_id = 0
        
        # Metrics
        self.total_audio_duration = 0.0
        self.total_segments = 0
        self.last_partial_time = 0
        
        logger.info(f"RivaASRClient initialized for {self.config.host}:{self.config.port}")
    
    async def connect(self) -> bool:
        """
        Connect to Riva server
        
        Returns:
            True if connected successfully
        """
        try:
            # Create authentication
            uri = f"{self.config.host}:{self.config.port}"
            
            if self.config.ssl:
                # SSL connection
                if self.config.ssl_cert:
                    with open(self.config.ssl_cert, 'rb') as f:
                        creds = grpc.ssl_channel_credentials(f.read())
                    self.auth = riva.client.Auth(uri=uri, use_ssl=True, ssl_cert=creds)
                else:
                    self.auth = riva.client.Auth(uri=uri, use_ssl=True)
            else:
                # Insecure connection
                self.auth = riva.client.Auth(uri=uri, use_ssl=False)
            
            # Add API key if provided
            if self.config.api_key:
                self.auth.metadata = [('authorization', f'Bearer {self.config.api_key}')]
            
            # Create ASR service
            self.asr_service = riva.client.ASRService(self.auth)
            
            # Test connection by listing models
            await self._list_models()
            
            self.connected = True
            logger.info(f"Connected to Riva server at {uri}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to connect to Riva: {e}")
            self.connected = False
            return False
    
    async def _list_models(self) -> List[str]:
        """
        List available ASR models on Riva server
        
        Returns:
            List of model names
        """
        try:
            response = await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: self.asr_service.stub.ListModels(
                    riva_asr_pb2.ListModelsRequest()
                )
            )
            models = [model.name for model in response.models]
            logger.info(f"Available Riva models: {models}")
            return models
        except Exception as e:
            logger.error(f"Failed to list models: {e}")
            raise
    
    async def stream_transcribe(
        self,
        audio_iterator: AsyncGenerator[bytes, None],
        sample_rate: int = 16000,
        enable_partials: bool = True,
        hotwords: Optional[List[str]] = None
    ) -> AsyncGenerator[Dict[str, Any], None]:
        """
        Stream audio for transcription and yield partial/final results
        
        Args:
            audio_iterator: Async generator yielding audio chunks
            sample_rate: Audio sample rate in Hz
            enable_partials: Whether to emit partial results
            hotwords: Optional list of hotwords to boost
            
        Yields:
            Dict containing transcription events in existing JSON format
        """
        if not self.connected:
            if not await self.connect():
                yield self._create_error_event("Not connected to Riva server")
                return
        
        try:
            # Create streaming config
            config = riva.client.StreamingRecognitionConfig(
                config=riva.client.RecognitionConfig(
                    encoding=riva.client.AudioEncoding.LINEAR_PCM,
                    language_code=self.config.language_code,
                    model=self.config.model,
                    sample_rate_hertz=sample_rate,
                    max_alternatives=1,
                    enable_automatic_punctuation=self.config.enable_punctuation,
                    enable_word_time_offsets=self.config.enable_word_offsets,
                    verbatim_transcripts=False,
                    profanity_filter=False,
                    # speech_contexts for hotwords if provided
                    speech_contexts=[
                        riva.client.SpeechContext(phrases=hotwords, boost=10.0)
                    ] if hotwords else None
                ),
                interim_results=enable_partials and self.config.enable_partials
            )
            
            # Create audio generator with retry logic
            audio_gen = self._audio_generator_with_retry(audio_iterator, sample_rate)
            
            # Start streaming recognition
            start_time = time.time()
            
            async for response in self._stream_recognize(audio_gen, config):
                # Process each response
                event = await self._process_response(response, start_time)
                if event:
                    yield event
                    
        except grpc.RpcError as e:
            logger.error(f"gRPC error during streaming: {e}")
            yield self._create_error_event(f"Riva streaming error: {e.details()}")
        except Exception as e:
            logger.error(f"Unexpected error during streaming: {e}")
            yield self._create_error_event(str(e))
    
    async def _audio_generator_with_retry(
        self,
        audio_iterator: AsyncGenerator[bytes, None],
        sample_rate: int
    ) -> AsyncGenerator[bytes, None]:
        """
        Wrap audio iterator with retry logic and chunking
        
        Args:
            audio_iterator: Original audio iterator
            sample_rate: Sample rate for timing calculations
            
        Yields:
            Audio chunks sized for optimal Riva processing
        """
        buffer = bytearray()
        chunk_size = self.config.chunk_size_bytes
        audio_start_time = time.time()
        
        async for audio_chunk in audio_iterator:
            # Add to buffer
            buffer.extend(audio_chunk)
            
            # Yield chunks of optimal size
            while len(buffer) >= chunk_size:
                yield bytes(buffer[:chunk_size])
                buffer = buffer[chunk_size:]
                
                # Update metrics
                samples_processed = chunk_size // 2  # Assuming 16-bit audio
                duration = samples_processed / sample_rate
                self.total_audio_duration += duration
        
        # Yield remaining buffer
        if buffer:
            yield bytes(buffer)
            samples_processed = len(buffer) // 2
            duration = samples_processed / sample_rate
            self.total_audio_duration += duration
    
    async def _stream_recognize(
        self,
        audio_generator: AsyncGenerator[bytes, None],
        config: riva.client.StreamingRecognitionConfig
    ) -> AsyncGenerator[Any, None]:
        """
        Perform streaming recognition with Riva
        
        Args:
            audio_generator: Audio chunk generator
            config: Streaming recognition config
            
        Yields:
            Recognition responses from Riva
        """
        # Create request generator
        async def request_generator():
            # First request contains config
            yield riva_asr_pb2.StreamingRecognizeRequest(
                streaming_config=config._to_proto()
            )
            
            # Subsequent requests contain audio
            async for audio_chunk in audio_generator:
                yield riva_asr_pb2.StreamingRecognizeRequest(
                    audio_content=audio_chunk
                )
        
        # Convert async generator to sync for gRPC
        request_iter = self._async_to_sync_generator(request_generator())
        
        # Perform streaming recognition
        responses = self.asr_service.stub.StreamingRecognize(request_iter)
        
        # Yield responses
        for response in responses:
            yield response
    
    def _async_to_sync_generator(self, async_gen):
        """Convert async generator to sync generator for gRPC"""
        loop = asyncio.get_event_loop()
        while True:
            try:
                future = asyncio.ensure_future(async_gen.__anext__())
                yield loop.run_until_complete(future)
            except StopAsyncIteration:
                break
    
    async def _process_response(
        self,
        response: Any,
        start_time: float
    ) -> Optional[Dict[str, Any]]:
        """
        Process Riva response into our JSON format
        
        Args:
            response: Riva StreamingRecognizeResponse
            start_time: Stream start time for latency calculation
            
        Returns:
            Event dict or None if no results
        """
        if not response.results:
            return None
        
        # Get first result (we only request 1 alternative)
        result = response.results[0]
        
        if not result.alternatives:
            return None
        
        alternative = result.alternatives[0]
        transcript = alternative.transcript.strip()
        
        if not transcript:
            return None
        
        # Determine if partial or final
        is_final = result.is_final
        current_time = time.time()
        
        # Rate limit partials
        if not is_final and self.config.enable_partials:
            if (current_time - self.last_partial_time) * 1000 < self.config.partial_interval_ms:
                return None
            self.last_partial_time = current_time
        
        # Extract word timings if available
        words = []
        if self.config.enable_word_offsets and alternative.words:
            for word_info in alternative.words:
                words.append({
                    'word': word_info.word,
                    'start': word_info.start_time,
                    'end': word_info.end_time,
                    'confidence': word_info.confidence if hasattr(word_info, 'confidence') else 0.95
                })
        
        # Create event
        event_type = TranscriptionEventType.FINAL if is_final else TranscriptionEventType.PARTIAL
        
        event = {
            'type': event_type.value,
            'segment_id': self.segment_id,
            'text': transcript,
            'is_final': is_final,
            'timestamp': datetime.utcnow().isoformat(),
            'processing_time_ms': round((current_time - start_time) * 1000, 2)
        }
        
        # Add words for final results
        if is_final:
            event['words'] = words
            event['confidence'] = alternative.confidence if hasattr(alternative, 'confidence') else 0.95
            self.segment_id += 1
            self.total_segments += 1
        
        logger.debug(f"Transcription event: type={event_type.value}, text='{transcript[:50]}...'")
        
        return event
    
    def _create_error_event(self, error_message: str) -> Dict[str, Any]:
        """
        Create error event
        
        Args:
            error_message: Error description
            
        Returns:
            Error event dict
        """
        return {
            'type': TranscriptionEventType.ERROR.value,
            'error': error_message,
            'segment_id': self.segment_id,
            'timestamp': datetime.utcnow().isoformat()
        }
    
    async def transcribe_file(self, file_path: str, sample_rate: int = 16000) -> Dict[str, Any]:
        """
        Transcribe an audio file (offline/batch mode)
        
        Args:
            file_path: Path to audio file
            sample_rate: Sample rate of audio
            
        Returns:
            Final transcription result
        """
        if not self.connected:
            if not await self.connect():
                return self._create_error_event("Not connected to Riva server")
        
        try:
            import soundfile as sf
            
            # Read audio file
            audio, file_sr = sf.read(file_path, dtype='int16')
            
            # Resample if needed
            if file_sr != sample_rate:
                import scipy.signal
                audio = scipy.signal.resample(audio, int(len(audio) * sample_rate / file_sr))
                audio = audio.astype(np.int16)
            
            # Convert to bytes
            audio_bytes = audio.tobytes()
            
            # Create config
            config = riva.client.RecognitionConfig(
                encoding=riva.client.AudioEncoding.LINEAR_PCM,
                language_code=self.config.language_code,
                model=self.config.model,
                sample_rate_hertz=sample_rate,
                max_alternatives=1,
                enable_automatic_punctuation=self.config.enable_punctuation,
                enable_word_time_offsets=self.config.enable_word_offsets
            )
            
            # Perform offline recognition
            start_time = time.time()
            response = await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: self.asr_service.offline_recognize(audio_bytes, config)
            )
            
            # Process response
            if response.results and response.results[0].alternatives:
                alternative = response.results[0].alternatives[0]
                transcript = alternative.transcript.strip()
                
                # Extract words
                words = []
                if alternative.words:
                    for word_info in alternative.words:
                        words.append({
                            'word': word_info.word,
                            'start': word_info.start_time,
                            'end': word_info.end_time,
                            'confidence': word_info.confidence if hasattr(word_info, 'confidence') else 0.95
                        })
                
                return {
                    'type': TranscriptionEventType.FINAL.value,
                    'segment_id': self.segment_id,
                    'text': transcript,
                    'is_final': True,
                    'words': words,
                    'confidence': alternative.confidence if hasattr(alternative, 'confidence') else 0.95,
                    'duration': len(audio) / sample_rate,
                    'processing_time_ms': round((time.time() - start_time) * 1000, 2),
                    'timestamp': datetime.utcnow().isoformat()
                }
            else:
                return {
                    'type': TranscriptionEventType.FINAL.value,
                    'segment_id': self.segment_id,
                    'text': "",
                    'is_final': True,
                    'words': [],
                    'timestamp': datetime.utcnow().isoformat()
                }
                
        except Exception as e:
            logger.error(f"File transcription error: {e}")
            return self._create_error_event(str(e))
    
    async def close(self):
        """Close connection to Riva server"""
        self.connected = False
        self.auth = None
        self.asr_service = None
        logger.info("RivaASRClient connection closed")
    
    def get_metrics(self) -> Dict[str, Any]:
        """
        Get client metrics
        
        Returns:
            Dict with metrics
        """
        return {
            'connected': self.connected,
            'total_audio_duration_s': round(self.total_audio_duration, 2),
            'total_segments': self.total_segments,
            'current_segment_id': self.segment_id,
            'host': f"{self.config.host}:{self.config.port}",
            'model': self.config.model
        }


async def test_riva_client():
    """Test function for RivaASRClient"""
    import tempfile
    
    # Initialize client
    client = RivaASRClient()
    
    # Connect to server
    if not await client.connect():
        print("Failed to connect to Riva server")
        return
    
    # Generate test audio
    sample_rate = 16000
    duration = 3
    t = np.linspace(0, duration, int(sample_rate * duration))
    audio = (np.sin(2 * np.pi * 440 * t) * 32767 * 0.3).astype(np.int16)
    
    # Save to temp file
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
        import soundfile as sf
        sf.write(f.name, audio, sample_rate)
        temp_path = f.name
    
    # Test file transcription
    print("Testing file transcription...")
    result = await client.transcribe_file(temp_path, sample_rate)
    print(f"Result: {result}")
    
    # Test streaming
    print("\nTesting streaming transcription...")
    
    async def audio_generator():
        # Yield audio in chunks
        chunk_size = 4096
        for i in range(0, len(audio) * 2, chunk_size):
            yield audio[i//2:i//2 + chunk_size//2].tobytes()
            await asyncio.sleep(0.1)  # Simulate real-time
    
    async for event in client.stream_transcribe(audio_generator(), sample_rate):
        print(f"Event: {event}")
    
    # Get metrics
    print(f"\nMetrics: {client.get_metrics()}")
    
    # Close connection
    await client.close()
    
    # Clean up
    os.unlink(temp_path)


if __name__ == "__main__":
    # Run test
    asyncio.run(test_riva_client())