import Foundation
import Combine

/// Orchestrates the full voice conversation loop:
/// User speaks -> AppState transcribes (LocalSTTService) -> VoiceConversationManager
/// sends transcript to ChatProvider -> AI responds -> LocalTTSService speaks response
///
/// Does NOT manage its own STT — hooks into AppState's existing transcription pipeline.
/// The transcript arrives via the onVoiceTranscript callback that AppState calls.
@MainActor
final class VoiceConversationManager: ObservableObject {

    // MARK: - State

    enum VoiceState: Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    @Published var state: VoiceState = .idle
    @Published var isActive = false
    @Published var lastTranscript = ""

    // MARK: - Dependencies

    private var chatProvider: ChatProvider?
    private var ttsService: LocalTTSService?

    // Track message count to detect new AI responses
    private var lastMessageCount = 0
    private var pendingUserMessage = false

    // MARK: - Init

    init() {
        log("VoiceConversationManager: Initialized")
    }

    private var appState: AppState?

    func configure(chatProvider: ChatProvider) {
        self.chatProvider = chatProvider
    }

    /// Wire to AppState so we receive transcripts from the STT pipeline
    func connectToAppState(_ appState: AppState) {
        self.appState = appState
    }

    // MARK: - Voice Loop Control

    /// Start voice conversation mode.
    /// AppState handles STT — this manager just needs to be active so
    /// transcripts get routed to Claude and responses get spoken.
    func start() async {
        guard !isActive else { return }

        ttsService = LocalTTSService()
        isActive = true
        state = .listening

        // Wire AppState callback so transcripts flow to us
        appState?.onVoiceTranscript = { [weak self] text in
            Task { @MainActor in
                await self?.handleTranscript(text)
            }
        }

        log("VoiceConversationManager: Started — waiting for transcripts from AppState")
    }

    func stop() async {
        guard isActive else { return }

        // Unwire callback
        appState?.onVoiceTranscript = nil

        isActive = false
        state = .idle
        pendingUserMessage = false

        await ttsService?.stop()
        ttsService = nil

        log("VoiceConversationManager: Stopped")
    }

    /// Called by AppState when a transcript is produced (via LocalSTTService).
    /// This is the entry point from the existing transcription pipeline.
    func handleTranscript(_ text: String) async {
        guard isActive else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        lastTranscript = text
        state = .thinking
        log("VoiceConversationManager: Transcript received: \(text.prefix(100))")

        guard let chatProvider = chatProvider else {
            log("VoiceConversationManager: No ChatProvider configured")
            state = .listening
            return
        }

        // Record current message count to detect when AI responds
        lastMessageCount = chatProvider.messages.count
        pendingUserMessage = true

        // Send the transcribed text as a chat message
        await chatProvider.sendMessage(text)

        // Wait for AI response
        await waitForAIResponse()
    }

    /// Poll for the AI response after sending a message
    private func waitForAIResponse() async {
        guard let chatProvider = chatProvider, pendingUserMessage else { return }

        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

            guard isActive, pendingUserMessage else { return }

            if chatProvider.messages.count > lastMessageCount && !chatProvider.isSending {
                if let lastMessage = chatProvider.messages.last, lastMessage.sender == .ai {
                    let responseText = lastMessage.text
                    pendingUserMessage = false

                    if !responseText.isEmpty {
                        log("VoiceConversationManager: AI responded (\(responseText.count) chars)")
                        await speakResponse(responseText)
                    } else {
                        state = .listening
                    }
                    return
                }
            }
        }

        log("VoiceConversationManager: Timeout waiting for AI response")
        pendingUserMessage = false
        state = .listening
    }

    /// Speak the AI response via TTS, then resume listening
    private func speakResponse(_ text: String) async {
        guard isActive else { return }
        state = .speaking

        if let tts = ttsService {
            log("VoiceConversationManager: Speaking response...")
            await tts.speak(text)

            var waitCount = 0
            while await tts.isSpeaking && waitCount < 120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waitCount += 1
                guard isActive, state == .speaking else { return }
            }
        }

        log("VoiceConversationManager: Done speaking, back to listening")
        if isActive {
            state = .listening
        }
    }
}
