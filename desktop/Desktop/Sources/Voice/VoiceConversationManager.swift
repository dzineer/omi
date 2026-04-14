import Foundation
import Combine

/// Orchestrates the full voice conversation loop:
/// User speaks -> AppState transcribes (LocalSTTService) -> VoiceConversationManager
/// sends transcript to ChatProvider -> AI responds -> LocalTTSService speaks response
///
/// Does NOT manage its own STT — hooks into AppState's existing transcription pipeline.
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
    @Published var speakEnabled = false
    @Published var lastTranscript = ""

    // MARK: - Dependencies

    private var chatProvider: ChatProvider?
    private var appState: AppState?
    private var ttsService: LocalTTSService?

    private var lastMessageCount = 0
    private var pendingUserMessage = false

    // MARK: - Init

    init() {
        log("VoiceConversationManager: Initialized")
    }

    func configure(chatProvider: ChatProvider) {
        self.chatProvider = chatProvider
    }

    func connectToAppState(_ appState: AppState) {
        self.appState = appState
    }

    // MARK: - Voice Loop Control

    /// Start voice conversation mode (mic input → Claude → text response in chat)
    func start() async {
        guard !isActive else { return }

        ttsService = LocalTTSService()
        isActive = true
        state = .listening

        appState?.onVoiceTranscript = { [weak self] text in
            Task { @MainActor in
                await self?.handleTranscript(text)
            }
        }

        log("VoiceConversationManager: Started — waiting for transcripts from AppState")
    }

    func stop() async {
        guard isActive else { return }

        appState?.onVoiceTranscript = nil
        isActive = false
        state = .idle
        pendingUserMessage = false

        await ttsService?.stop()
        ttsService = nil

        log("VoiceConversationManager: Stopped")
    }

    /// Toggle speaker output on/off
    func toggleSpeak() {
        speakEnabled.toggle()
        log("VoiceConversationManager: Speak \(speakEnabled ? "enabled" : "disabled")")
        if !speakEnabled {
            // Stop any current speech
            ttsService?.stop()
            if state == .speaking {
                state = .listening
            }
        }
    }

    // MARK: - Internal Flow

    private func handleTranscript(_ text: String) async {
        guard isActive else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Ignore transcripts while AI is speaking (feedback prevention)
        if state == .speaking {
            log("VoiceConversationManager: Ignoring transcript during speech (feedback prevention)")
            return
        }

        lastTranscript = text
        state = .thinking
        log("VoiceConversationManager: Transcript received: \(text.prefix(100))")

        guard let chatProvider = chatProvider else {
            log("VoiceConversationManager: No ChatProvider configured")
            state = .listening
            return
        }

        lastMessageCount = chatProvider.messages.count
        pendingUserMessage = true

        await chatProvider.sendMessage(text)
        await waitForAIResponse()
    }

    private func waitForAIResponse() async {
        guard let chatProvider = chatProvider, pendingUserMessage else { return }

        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)

            guard isActive, pendingUserMessage else { return }

            if chatProvider.messages.count > lastMessageCount && !chatProvider.isSending {
                if let lastMessage = chatProvider.messages.last, lastMessage.sender == .ai {
                    let responseText = lastMessage.text
                    pendingUserMessage = false

                    if !responseText.isEmpty && speakEnabled {
                        log("VoiceConversationManager: AI responded (\(responseText.count) chars), speaking...")
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

    private func speakResponse(_ text: String) async {
        guard isActive, speakEnabled else {
            state = .listening
            return
        }

        state = .speaking

        let speakableText = SpeechTextFilter.filterForSpeech(text)
        guard !speakableText.isEmpty else {
            log("VoiceConversationManager: Nothing speakable after filtering")
            state = .listening
            return
        }

        log("VoiceConversationManager: Speaking response (\(speakableText.count) chars after filter)...")

        if let tts = ttsService {
            await tts.speak(speakableText)

            // Wait for TTS to finish
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
