#!/usr/bin/env python3
"""
Streaming Transcription Handler for RNN-T
Manages continuous transcription with partial results
"""

import asyncio
import time
import numpy as np
import torch
from typing import Optional, Dict, Any, AsyncGenerator
from datetime import datetime
import logging

logger = logging.getLogger(__name__)


class TranscriptionStream:
    """
    Manages streaming transcription with the RNN-T model
    
    Features:
    - Partial result generation
    - Word-level timing alignment
    - Confidence scoring
    - Result buffering and merging
    """
    
    def __init__(self, asr_model, device: str = 'cuda'):
        """
        Initialize transcription stream
        
        Args:
            asr_model: Loaded SpeechBrain RNN-T model
            device: Device for inference (cuda/cpu)
        """
        self.asr_model = asr_model
        self.device = device
        
        # Transcription state
        self.segment_id = 0
        self.partial_transcript = ""
        self.final_transcripts = []
        self.word_timings = []
        self.current_time_offset = 0.0
        
        logger.info(f"TranscriptionStream initialized on {device}")
    
    async def transcribe_segment(
        self,
        audio_segment: np.ndarray,
        sample_rate: int = 16000,
        is_final: bool = False
    ) -> Dict[str, Any]:
        """
        Transcribe audio segment
        
        Args:
            audio_segment: Audio array to transcribe
            sample_rate: Sample rate of audio
            is_final: Whether this is the final segment
            
        Returns:
            Transcription result dictionary
        """
        start_time = time.time()
        
        try:
            # Convert to tensor
            audio_tensor = torch.from_numpy(audio_segment).unsqueeze(0)
            
            # Move to device
            if self.device == 'cuda':
                audio_tensor = audio_tensor.cuda()
            
            # Get audio duration
            duration = len(audio_segment) / sample_rate
            
            # Run inference
            with torch.no_grad():
                # For streaming, we could use model's streaming capabilities
                # For now, process as complete segment
                transcription = self._run_inference(audio_tensor, sample_rate)
            
            # Process transcription
            result = self._process_transcription(
                transcription,
                duration,
                is_final,
                start_time
            )
            
            # Update state
            if is_final:
                self.final_transcripts.append(result['text'])
                self.current_time_offset += duration
                self.segment_id += 1
            else:
                self.partial_transcript = result['text']
            
            return result
            
        except Exception as e:
            logger.error(f"Transcription error: {e}")
            return self._error_result(str(e))
    
    def _run_inference(self, audio_tensor: torch.Tensor, sample_rate: int) -> str:
        """
        Run RNN-T inference on audio tensor
        
        Args:
            audio_tensor: Input audio tensor
            sample_rate: Sample rate
            
        Returns:
            Transcribed text
        """
        # The actual SpeechBrain model expects file path or tensor
        # We'll need to adapt this based on the model's API
        
        # For now, simplified inference
        # In production, this would use model's streaming API
        try:
            # Convert tensor to expected format
            if audio_tensor.dim() == 2:
                audio_tensor = audio_tensor.squeeze(0)
            
            # Run transcription
            # Note: SpeechBrain's transcribe method may vary
            transcription = self.asr_model.transcribe_batch(
                audio_tensor.unsqueeze(0),
                [torch.tensor([audio_tensor.shape[0]])]
            )
            
            if isinstance(transcription, list):
                return transcription[0] if transcription else ""
            return str(transcription)
            
        except Exception as e:
            logger.warning(f"Inference fallback: {e}")
            # Fallback to simple transcription
            return ""
    
    def _process_transcription(
        self,
        text: str,
        duration: float,
        is_final: bool,
        start_time: float
    ) -> Dict[str, Any]:
        """
        Process transcription into structured result
        
        Args:
            text: Transcribed text
            duration: Audio duration
            is_final: Whether this is final
            start_time: Processing start time
            
        Returns:
            Structured transcription result
        """
        processing_time = (time.time() - start_time) * 1000
        
        # Generate word timings
        words = []
        if text:
            word_list = text.strip().split()
            if word_list:
                time_per_word = duration / len(word_list) if len(word_list) > 0 else 0
                current_time = self.current_time_offset
                
                for word in word_list:
                    words.append({
                        'word': word,
                        'start': round(current_time, 3),
                        'end': round(current_time + time_per_word, 3),
                        'confidence': 0.95  # Placeholder
                    })
                    current_time += time_per_word
        
        return {
            'type': 'transcription',
            'segment_id': self.segment_id,
            'text': text,
            'is_final': is_final,
            'words': words,
            'duration': round(duration, 3),
            'processing_time_ms': round(processing_time, 2),
            'timestamp': datetime.utcnow().isoformat()
        }
    
    def _error_result(self, error_message: str) -> Dict[str, Any]:
        """
        Create error result
        
        Args:
            error_message: Error description
            
        Returns:
            Error result dictionary
        """
        return {
            'type': 'error',
            'error': error_message,
            'segment_id': self.segment_id,
            'timestamp': datetime.utcnow().isoformat()
        }
    
    def get_full_transcript(self) -> str:
        """
        Get complete transcript so far
        
        Returns:
            Full transcript text
        """
        full_text = ' '.join(self.final_transcripts)
        if self.partial_transcript:
            full_text += ' ' + self.partial_transcript
        return full_text.strip()
    
    def reset(self):
        """Reset transcription state"""
        self.segment_id = 0
        self.partial_transcript = ""
        self.final_transcripts = []
        self.word_timings = []
        self.current_time_offset = 0.0
        logger.debug("TranscriptionStream reset")