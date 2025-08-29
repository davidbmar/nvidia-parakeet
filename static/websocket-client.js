/**
 * WebSocket Client for RNN-T Streaming
 * Manages WebSocket connection and message protocol
 * 
 * Clear, simple implementation for developers to understand and extend
 */

class TranscriptionWebSocket {
    constructor(options = {}) {
        // Configuration
        this.url = options.url || `ws://${window.location.hostname}:8000/ws/transcribe`;
        this.clientId = options.clientId || this.generateClientId();
        this.reconnectDelay = options.reconnectDelay || 1000;
        this.maxReconnectDelay = options.maxReconnectDelay || 30000;
        this.reconnectAttempts = 0;
        
        // Callbacks
        this.onTranscription = options.onTranscription || null;
        this.onPartialTranscription = options.onPartialTranscription || null;
        this.onConnect = options.onConnect || null;
        this.onDisconnect = options.onDisconnect || null;
        this.onError = options.onError || console.error;
        
        // State
        this.ws = null;
        this.isConnected = false;
        this.messageQueue = [];
        this.reconnectTimer = null;
    }
    
    /**
     * Connect to WebSocket server
     */
    connect() {
        try {
            // Create WebSocket connection
            this.ws = new WebSocket(`${this.url}?client_id=${this.clientId}`);
            this.ws.binaryType = 'arraybuffer';
            
            // Connection opened
            this.ws.onopen = () => {
                console.log('WebSocket connected');
                this.isConnected = true;
                this.reconnectAttempts = 0;
                
                // Send queued messages
                this.flushMessageQueue();
                
                // Callback
                if (this.onConnect) {
                    this.onConnect();
                }
            };
            
            // Message received
            this.ws.onmessage = (event) => {
                this.handleMessage(event.data);
            };
            
            // Connection closed
            this.ws.onclose = (event) => {
                console.log('WebSocket disconnected:', event.code, event.reason);
                this.isConnected = false;
                
                if (this.onDisconnect) {
                    this.onDisconnect();
                }
                
                // Attempt reconnection
                this.scheduleReconnect();
            };
            
            // Error occurred
            this.ws.onerror = (error) => {
                console.error('WebSocket error:', error);
                if (this.onError) {
                    this.onError(error);
                }
            };
            
        } catch (error) {
            console.error('Failed to connect:', error);
            this.scheduleReconnect();
        }
    }
    
    /**
     * Disconnect from server
     */
    disconnect() {
        this.isConnected = false;
        
        // Cancel reconnection
        if (this.reconnectTimer) {
            clearTimeout(this.reconnectTimer);
            this.reconnectTimer = null;
        }
        
        // Close WebSocket
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
    }
    
    /**
     * Send audio data to server
     * @param {ArrayBuffer} audioData - PCM16 audio data
     */
    sendAudio(audioData) {
        if (!this.isConnected) {
            // Queue message if not connected
            this.messageQueue.push(audioData);
            return;
        }
        
        try {
            this.ws.send(audioData);
        } catch (error) {
            console.error('Failed to send audio:', error);
            this.messageQueue.push(audioData);
        }
    }
    
    /**
     * Send control message to server
     * @param {Object} message - JSON message object
     */
    sendMessage(message) {
        if (!this.isConnected) {
            this.messageQueue.push(message);
            return;
        }
        
        try {
            this.ws.send(JSON.stringify(message));
        } catch (error) {
            console.error('Failed to send message:', error);
            this.messageQueue.push(message);
        }
    }
    
    /**
     * Start recording session
     * @param {Object} config - Recording configuration
     */
    startRecording(config = {}) {
        this.sendMessage({
            type: 'start_recording',
            timestamp: Date.now(),
            config: {
                sample_rate: config.sampleRate || 16000,
                encoding: config.encoding || 'pcm16',
                language: config.language || 'en',
                ...config
            }
        });
    }
    
    /**
     * Stop recording session
     */
    stopRecording() {
        this.sendMessage({
            type: 'stop_recording',
            timestamp: Date.now()
        });
    }
    
    /**
     * Configure stream parameters
     * @param {Object} config - Stream configuration
     */
    configure(config) {
        this.sendMessage({
            type: 'configure',
            ...config
        });
    }
    
    /**
     * Handle incoming message from server
     * @param {string|ArrayBuffer} data - Message data
     */
    handleMessage(data) {
        try {
            // Parse JSON message
            const message = typeof data === 'string' 
                ? JSON.parse(data) 
                : JSON.parse(new TextDecoder().decode(data));
            
            switch (message.type) {
                case 'connection':
                    console.log('Connection established:', message);
                    break;
                    
                case 'transcription':
                    if (this.onTranscription) {
                        this.onTranscription(message);
                    }
                    break;
                    
                case 'partial':
                    if (this.onPartialTranscription) {
                        this.onPartialTranscription(message);
                    }
                    break;
                    
                case 'error':
                    console.error('Server error:', message.error);
                    if (this.onError) {
                        this.onError(new Error(message.error));
                    }
                    break;
                    
                case 'recording_started':
                    console.log('Recording started');
                    break;
                    
                case 'recording_stopped':
                    console.log('Recording stopped:', message);
                    if (this.onTranscription) {
                        this.onTranscription({
                            type: 'final',
                            text: message.final_transcript,
                            duration: message.total_duration,
                            segments: message.total_segments
                        });
                    }
                    break;
                    
                default:
                    console.log('Unknown message type:', message.type, message);
            }
            
        } catch (error) {
            console.error('Failed to handle message:', error);
        }
    }
    
    /**
     * Schedule reconnection attempt
     */
    scheduleReconnect() {
        // Don't reconnect if manually disconnected
        if (!this.ws) return;
        
        // Calculate delay with exponential backoff
        const delay = Math.min(
            this.reconnectDelay * Math.pow(2, this.reconnectAttempts),
            this.maxReconnectDelay
        );
        
        console.log(`Reconnecting in ${delay}ms...`);
        
        this.reconnectTimer = setTimeout(() => {
            this.reconnectAttempts++;
            this.connect();
        }, delay);
    }
    
    /**
     * Send queued messages
     */
    flushMessageQueue() {
        while (this.messageQueue.length > 0 && this.isConnected) {
            const message = this.messageQueue.shift();
            
            if (message instanceof ArrayBuffer) {
                this.sendAudio(message);
            } else {
                this.sendMessage(message);
            }
        }
    }
    
    /**
     * Generate unique client ID
     * @returns {string} Client ID
     */
    generateClientId() {
        return `client_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
    }
    
    /**
     * Get connection status
     * @returns {boolean} Connection status
     */
    isConnected() {
        return this.isConnected && this.ws && this.ws.readyState === WebSocket.OPEN;
    }
}

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
    module.exports = TranscriptionWebSocket;
}