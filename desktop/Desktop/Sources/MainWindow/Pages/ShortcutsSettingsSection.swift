import SwiftUI

/// Settings section for keyboard shortcuts and push-to-talk configuration.
struct ShortcutsSettingsSection: View {
    @ObservedObject private var settings = ShortcutSettings.shared
    @Binding var highlightedSettingId: String?

    init(highlightedSettingId: Binding<String?> = .constant(nil)) {
        self._highlightedSettingId = highlightedSettingId
    }

    var body: some View {
        VStack(spacing: 20) {
            aiModelCard
            backgroundStyleCard
            draggableBarCard
            askVibeAiKeyCard
            pttKeyCard
            pttTranscriptionModeCard
            doubleTapCard
            pttSoundsCard
            referenceCard
        }
    }

    private var aiModelCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Model")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(VibeAIColors.textPrimary)
                Text("Choose the AI model for Ask VibeAi conversations.")
                    .scaledFont(size: 13)
                    .foregroundColor(VibeAIColors.textSecondary)
            }

            HStack(spacing: 12) {
                ForEach(ShortcutSettings.availableModels, id: \.id) { model in
                    aiModelButton(model)
                }
                Spacer()
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(VibeAIColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.model", highlightedSettingId: $highlightedSettingId))
    }

    private func aiModelButton(_ model: (id: String, label: String)) -> some View {
        let isSelected = settings.selectedModel == model.id
        return Button {
            settings.selectedModel = model.id
        } label: {
            Text(model.label)
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(VibeAIColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected
                              ? VibeAIColors.purplePrimary.opacity(0.3)
                              : VibeAIColors.backgroundTertiary.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? VibeAIColors.purplePrimary : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var backgroundStyleCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Background Style")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(VibeAIColors.textPrimary)
                Text(settings.solidBackground
                     ? "Solid dark background"
                     : "Semi-transparent with blur")
                    .scaledFont(size: 13)
                    .foregroundColor(VibeAIColors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $settings.solidBackground)
                .toggleStyle(.switch)
                .tint(VibeAIColors.purplePrimary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(VibeAIColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.background", highlightedSettingId: $highlightedSettingId))
    }

    private var draggableBarCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Draggable Floating Bar")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(VibeAIColors.textPrimary)
                Text("Allow repositioning the floating bar by dragging it.")
                    .scaledFont(size: 13)
                    .foregroundColor(VibeAIColors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $settings.draggableBarEnabled)
                .toggleStyle(.switch)
                .tint(VibeAIColors.purplePrimary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(VibeAIColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.draggable", highlightedSettingId: $highlightedSettingId))
    }

    private var askVibeAiKeyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask VibeAi Shortcut")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(VibeAIColors.textPrimary)
                Text("Global shortcut to open Ask VibeAi from anywhere.")
                    .scaledFont(size: 13)
                    .foregroundColor(VibeAIColors.textSecondary)
            }

            HStack(spacing: 12) {
                ForEach(ShortcutSettings.AskVibeAiKey.allCases, id: \.self) { key in
                    askVibeAiKeyButton(key)
                }
                Spacer()
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(VibeAIColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.shortcut", highlightedSettingId: $highlightedSettingId))
    }

    private func askVibeAiKeyButton(_ key: ShortcutSettings.AskVibeAiKey) -> some View {
        let isSelected = settings.askVibeAiKey == key
        return Button {
            settings.askVibeAiKey = key
        } label: {
            Text(key.rawValue)
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(VibeAIColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected
                              ? VibeAIColors.purplePrimary.opacity(0.3)
                              : VibeAIColors.backgroundTertiary.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? VibeAIColors.purplePrimary : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var pttKeyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Push to Talk")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(VibeAIColors.textPrimary)
                Text("Hold the key to speak, release to send your question to AI.")
                    .scaledFont(size: 13)
                    .foregroundColor(VibeAIColors.textSecondary)
            }

            HStack(spacing: 12) {
                ForEach(ShortcutSettings.PTTKey.allCases, id: \.self) { key in
                    pttKeyButton(key)
                }
                Spacer()
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(VibeAIColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.ptt", highlightedSettingId: $highlightedSettingId))
    }

    private func pttKeyButton(_ key: ShortcutSettings.PTTKey) -> some View {
        let isSelected = settings.pttKey == key
        return Button {
            settings.pttKey = key
        } label: {
            HStack(spacing: 8) {
                Text(key.symbol)
                    .scaledFont(size: 16)
                Text(key.rawValue)
                    .scaledFont(size: 13, weight: .medium)
            }
            .foregroundColor(VibeAIColors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? VibeAIColors.purplePrimary.opacity(0.3)
                          : VibeAIColors.backgroundTertiary.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? VibeAIColors.purplePrimary : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var pttTranscriptionModeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription Mode")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(VibeAIColors.textPrimary)
                Text(settings.pttTranscriptionMode.description)
                    .scaledFont(size: 13)
                    .foregroundColor(VibeAIColors.textSecondary)
            }

            HStack(spacing: 12) {
                ForEach(ShortcutSettings.PTTTranscriptionMode.allCases, id: \.self) { mode in
                    pttTranscriptionModeButton(mode)
                }
                Spacer()
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(VibeAIColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.transcriptionmode", highlightedSettingId: $highlightedSettingId))
    }

    private func pttTranscriptionModeButton(_ mode: ShortcutSettings.PTTTranscriptionMode) -> some View {
        let isSelected = settings.pttTranscriptionMode == mode
        return Button {
            settings.pttTranscriptionMode = mode
        } label: {
            Text(mode.rawValue)
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(VibeAIColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected
                              ? VibeAIColors.purplePrimary.opacity(0.3)
                              : VibeAIColors.backgroundTertiary.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? VibeAIColors.purplePrimary : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var doubleTapCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Double-tap for Locked Mode")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(VibeAIColors.textPrimary)
                Text("Double-tap the push-to-talk key to keep listening hands-free. Tap again to send.")
                    .scaledFont(size: 13)
                    .foregroundColor(VibeAIColors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $settings.doubleTapForLock)
                .toggleStyle(.switch)
                .tint(VibeAIColors.purplePrimary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(VibeAIColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.doubletap", highlightedSettingId: $highlightedSettingId))
    }

    private var pttSoundsCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Push-to-Talk Sounds")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(VibeAIColors.textPrimary)
                Text("Play audio feedback when starting and ending voice input.")
                    .scaledFont(size: 13)
                    .foregroundColor(VibeAIColors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $settings.pttSoundsEnabled)
                .toggleStyle(.switch)
                .tint(VibeAIColors.purplePrimary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(VibeAIColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.pttsounds", highlightedSettingId: $highlightedSettingId))
    }

    private var referenceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .scaledFont(size: 16, weight: .semibold)
                .foregroundColor(VibeAIColors.textPrimary)

            shortcutRow(label: "Ask VibeAi", keys: settings.askVibeAiKey.rawValue)
            shortcutRow(label: "Toggle floating bar", keys: "\u{2318}\\")
            shortcutRow(label: "Push to talk", keys: settings.pttKey.symbol + " hold")
            if settings.doubleTapForLock {
                shortcutRow(label: "Locked listening", keys: settings.pttKey.symbol + " \u{00D7}2")
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(VibeAIColors.backgroundTertiary.opacity(0.5))
        )
    }

    private func shortcutRow(label: String, keys: String) -> some View {
        HStack {
            Text(label)
                .scaledFont(size: 14)
                .foregroundColor(VibeAIColors.textSecondary)
            Spacer()
            Text(keys)
                .scaledMonospacedFont(size: 14, weight: .medium)
                .foregroundColor(VibeAIColors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(VibeAIColors.backgroundTertiary.opacity(0.8))
                .cornerRadius(6)
        }
    }
}
