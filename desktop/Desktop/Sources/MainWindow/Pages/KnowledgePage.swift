import SwiftUI

/// Knowledge page — local Eidetic Memory graph browser.
/// Search, browse by room, view stats, and manually save memories.
struct KnowledgePage: View {
    @ObservedObject var viewModel: KnowledgeViewModel
    @State private var newMemoryText = ""
    @State private var showSaveSheet = false
    @State private var selectedRoom: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Stats header
            statsHeader
                .padding(.horizontal, 20)
                .padding(.top, 16)

            // Search bar
            searchBar
                .padding(.horizontal, 20)
                .padding(.top, 12)

            // Room filter chips
            if !viewModel.rooms.isEmpty {
                roomChips
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            // Results
            if viewModel.isSearching {
                Spacer()
                ProgressView()
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if viewModel.memories.isEmpty && !viewModel.searchQuery.isEmpty {
                Spacer()
                emptySearchView
                Spacer()
            } else if viewModel.memories.isEmpty {
                Spacer()
                emptyStateView
                Spacer()
            } else {
                resultsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.loadStatus()
        }
    }

    // MARK: - Stats Header

    private var statsHeader: some View {
        HStack(spacing: 16) {
            Text("Knowledge")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(VibeAIColors.textPrimary)

            Spacer()

            HStack(spacing: 12) {
                statBadge(count: viewModel.nodeCount, label: "memories", icon: "brain.fill")
                statBadge(count: viewModel.rooms.count, label: "rooms", icon: "folder.fill")
                statBadge(count: viewModel.embeddingCount, label: "vectors", icon: "arrow.triangle.branch")
            }

            Button(action: { showSaveSheet.toggle() }) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(VibeAIColors.purplePrimary)
            }
            .buttonStyle(.plain)
            .help("Save a new memory")
            .popover(isPresented: $showSaveSheet) {
                savePopover
            }
        }
    }

    private func statBadge(count: Int, label: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(VibeAIColors.textTertiary)
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(VibeAIColors.textSecondary)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(VibeAIColors.textTertiary)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(VibeAIColors.textTertiary)

            TextField("Search your knowledge...", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit {
                    Task { await viewModel.search(viewModel.searchQuery) }
                }

            if !viewModel.searchQuery.isEmpty {
                Button(action: {
                    viewModel.searchQuery = ""
                    viewModel.memories = []
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(VibeAIColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(VibeAIColors.backgroundSecondary)
        .cornerRadius(10)
    }

    // MARK: - Room Filter Chips

    private var roomChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                roomChip(name: "All", isSelected: selectedRoom == nil) {
                    selectedRoom = nil
                }
                ForEach(viewModel.rooms, id: \.self) { room in
                    roomChip(name: room.capitalized, isSelected: selectedRoom == room) {
                        selectedRoom = room
                    }
                }
            }
        }
    }

    private func roomChip(name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : VibeAIColors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? VibeAIColors.purplePrimary : VibeAIColors.backgroundSecondary)
                .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(filteredMemories) { item in
                    memoryRow(item)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    private var filteredMemories: [KnowledgeViewModel.KnowledgeItem] {
        guard let room = selectedRoom else { return viewModel.memories }
        return viewModel.memories.filter { $0.alias?.contains(room) == true }
    }

    private func memoryRow(_ item: KnowledgeViewModel.KnowledgeItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.payload)
                .font(.system(size: 13))
                .foregroundColor(VibeAIColors.textPrimary)
                .lineLimit(3)

            HStack(spacing: 8) {
                Text(item.kind)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(VibeAIColors.purplePrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(VibeAIColors.purplePrimary.opacity(0.15))
                    .cornerRadius(4)

                if let alias = item.alias {
                    Text(alias)
                        .font(.system(size: 10))
                        .foregroundColor(VibeAIColors.textTertiary)
                }

                Spacer()

                Text(String(format: "%.0f%%", item.score * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(VibeAIColors.textTertiary)
            }
        }
        .padding(10)
        .background(VibeAIColors.backgroundSecondary)
        .cornerRadius(8)
    }

    // MARK: - Empty States

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.fill")
                .font(.system(size: 40))
                .foregroundColor(VibeAIColors.textTertiary)
            Text("Your knowledge graph is empty")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(VibeAIColors.textSecondary)
            Text("Conversations are automatically saved here.\nYou can also add memories manually.")
                .font(.system(size: 13))
                .foregroundColor(VibeAIColors.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var emptySearchView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundColor(VibeAIColors.textTertiary)
            Text("No results for \"\(viewModel.searchQuery)\"")
                .font(.system(size: 14))
                .foregroundColor(VibeAIColors.textSecondary)
        }
    }

    // MARK: - Save Popover

    private var savePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Knowledge")
                .font(.system(size: 14, weight: .semibold))

            TextEditor(text: $newMemoryText)
                .font(.system(size: 13))
                .frame(width: 300, height: 100)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(VibeAIColors.backgroundSecondary)
                .cornerRadius(8)

            HStack {
                Spacer()
                Button("Cancel") {
                    showSaveSheet = false
                    newMemoryText = ""
                }
                .buttonStyle(.plain)

                Button("Save") {
                    Task {
                        let saved = await viewModel.save(text: newMemoryText)
                        if saved {
                            newMemoryText = ""
                            showSaveSheet = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
