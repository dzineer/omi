import SwiftUI

/// Knowledge page — local Eidetic Memory graph browser.
/// Shows rooms, memory cards, stats, search, and manual save.
struct KnowledgePage: View {
    @ObservedObject var viewModel: KnowledgeViewModel
    @State private var newMemoryText = ""
    @State private var showSaveSheet = false
    @State private var selectedRoom: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with stats
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Search bar
            searchBar
                .padding(.horizontal, 20)

            Divider()
                .padding(.top, 12)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Graph visualization
                    if !viewModel.graphRooms.isEmpty {
                        graphSection
                    }

                    // Rooms chips
                    if !viewModel.rooms.isEmpty {
                        roomsSection
                    }

                    // Memory cards
                    if viewModel.isSearching || viewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.top, 40)
                    } else if viewModel.memories.isEmpty && viewModel.nodeCount == 0 {
                        emptyStateView
                            .padding(.top, 40)
                    } else if viewModel.memories.isEmpty && !viewModel.searchQuery.isEmpty {
                        emptySearchView
                            .padding(.top, 40)
                    } else {
                        memoriesGrid
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.loadStatus()
            await viewModel.loadGraph()
            if viewModel.memories.isEmpty {
                await viewModel.loadAll()
            }
        }
    }

    // MARK: - Graph Visualization

    @State private var selectedNodeDetail: KnowledgeGraphView.GraphMemoryNode?

    private var graphSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Knowledge Graph")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(VibeAIColors.textSecondary)
                Spacer()
                Text("\(viewModel.graphNodes.count) nodes, \(viewModel.graphRooms.count) rooms")
                    .font(.system(size: 11))
                    .foregroundColor(VibeAIColors.textTertiary)
            }

            KnowledgeGraphView(
                rooms: viewModel.graphRooms.map { room in
                    KnowledgeGraphView.GraphRoom(
                        id: room.id,
                        name: room.name,
                        count: room.count,
                        nodes: viewModel.graphNodes
                            .filter { $0.room == room.name }
                            .map { KnowledgeGraphView.GraphMemoryNode(id: $0.id, payload: $0.payload, kind: $0.kind) },
                        color: roomColor(room.name)
                    )
                },
                selectedRoom: selectedRoom,
                onSelectRoom: { room in
                    selectedRoom = room
                },
                onSelectNode: { node in
                    selectedNodeDetail = node
                }
            )
            .frame(height: 300)
            .background(VibeAIColors.backgroundSecondary.opacity(0.5))
            .cornerRadius(12)

            // Node detail popover
            if let node = selectedNodeDetail {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.payload)
                            .font(.system(size: 12))
                            .foregroundColor(VibeAIColors.textPrimary)
                        Text(node.kind)
                            .font(.system(size: 10))
                            .foregroundColor(VibeAIColors.purplePrimary)
                    }
                    Spacer()
                    Button(action: { selectedNodeDetail = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(VibeAIColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(VibeAIColors.backgroundSecondary)
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Knowledge")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(VibeAIColors.textPrimary)

                Text("Your local memory graph")
                    .font(.system(size: 13))
                    .foregroundColor(VibeAIColors.textTertiary)
            }

            Spacer()

            // Stats pills
            HStack(spacing: 8) {
                statPill(icon: "brain.fill", value: "\(viewModel.nodeCount)", label: "memories", color: .purple)
                statPill(icon: "point.3.connected.trianglepath.dotted", value: "\(viewModel.edgeCount)", label: "links", color: .blue)
                statPill(icon: "arrow.triangle.branch", value: "\(viewModel.embeddingCount)", label: "vectors", color: .green)
                statPill(icon: "folder.fill", value: "\(viewModel.rooms.count)", label: "rooms", color: .orange)
            }

            // Add button
            Button(action: { showSaveSheet.toggle() }) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(VibeAIColors.purplePrimary)
            }
            .buttonStyle(.plain)
            .help("Save new knowledge")
            .popover(isPresented: $showSaveSheet) {
                savePopover
            }
        }
    }

    private func statPill(icon: String, value: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color.opacity(0.8))
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(VibeAIColors.textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(VibeAIColors.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Search

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
                    Task { await viewModel.loadAll() }
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

    // MARK: - Rooms Section

    private var roomsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rooms")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(VibeAIColors.textSecondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                // "All" room
                roomCard(name: "All", count: viewModel.nodeCount, icon: "square.grid.2x2.fill", color: .gray, isSelected: selectedRoom == nil) {
                    selectedRoom = nil
                }

                ForEach(viewModel.rooms, id: \.self) { room in
                    roomCard(name: room.capitalized, count: nil, icon: roomIcon(room), color: roomColor(room), isSelected: selectedRoom == room) {
                        selectedRoom = room
                    }
                }
            }
        }
    }

    private func roomCard(name: String, count: Int?, icon: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .white : color)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isSelected ? .white : VibeAIColors.textPrimary)
                    if let count = count {
                        Text("\(count) items")
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? .white.opacity(0.7) : VibeAIColors.textTertiary)
                    }
                }

                Spacer()
            }
            .padding(10)
            .background(isSelected ? color : VibeAIColors.backgroundSecondary)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func roomIcon(_ room: String) -> String {
        switch room.lowercased() {
        case "architecture", "design": return "building.2.fill"
        case "testing", "tests": return "checkmark.shield.fill"
        case "planning", "plan": return "map.fill"
        case "learning", "education": return "book.fill"
        case "general": return "circle.grid.3x3.fill"
        case "code", "engineering": return "chevron.left.forwardslash.chevron.right"
        case "voice", "audio": return "waveform"
        case "memory", "knowledge": return "brain.fill"
        default: return "folder.fill"
        }
    }

    private func roomColor(_ room: String) -> Color {
        switch room.lowercased() {
        case "architecture", "design": return .blue
        case "testing", "tests": return .green
        case "planning", "plan": return .orange
        case "learning", "education": return .purple
        case "general": return .gray
        case "code", "engineering": return .cyan
        case "voice", "audio": return .pink
        case "memory", "knowledge": return .indigo
        default: return .secondary
        }
    }

    // MARK: - Memory Cards Grid

    private var memoriesGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selectedRoom != nil ? "\(selectedRoom!.capitalized)" : "All Knowledge")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(VibeAIColors.textSecondary)

                Spacer()

                Text("\(filteredMemories.count) items")
                    .font(.system(size: 12))
                    .foregroundColor(VibeAIColors.textTertiary)
            }

            LazyVStack(spacing: 8) {
                ForEach(filteredMemories) { item in
                    memoryCard(item)
                }
            }
        }
    }

    private var filteredMemories: [KnowledgeViewModel.KnowledgeItem] {
        guard let room = selectedRoom else { return viewModel.memories }
        return viewModel.memories.filter { $0.alias?.lowercased().contains(room.lowercased()) == true }
    }

    private func memoryCard(_ item: KnowledgeViewModel.KnowledgeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.payload)
                .font(.system(size: 13))
                .foregroundColor(VibeAIColors.textPrimary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                // Kind badge
                Text(item.kind)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(kindColor(item.kind))
                    .cornerRadius(4)

                // Source/alias
                if let alias = item.alias {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 9))
                        .foregroundColor(VibeAIColors.textTertiary)
                    Text(alias)
                        .font(.system(size: 10))
                        .foregroundColor(VibeAIColors.textTertiary)
                }

                Spacer()

                // Relevance score
                if item.score > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 9))
                        Text(String(format: "%.0f%%", min(item.score * 100, 100)))
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundColor(VibeAIColors.textTertiary)
                }
            }
        }
        .padding(12)
        .background(VibeAIColors.backgroundSecondary)
        .cornerRadius(10)
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind.lowercased() {
        case "concept": return .purple
        case "fact": return .blue
        case "decision": return .orange
        case "preference": return .green
        case "insight": return .cyan
        case "question": return .pink
        case "room": return .gray
        default: return .secondary
        }
    }

    // MARK: - Empty States

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.fill")
                .font(.system(size: 48))
                .foregroundColor(VibeAIColors.textTertiary.opacity(0.5))

            Text("Your knowledge graph is empty")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(VibeAIColors.textSecondary)

            Text("Start a voice conversation or chat with the AI.\nKnowledge is automatically extracted and stored here.")
                .font(.system(size: 13))
                .foregroundColor(VibeAIColors.textTertiary)
                .multilineTextAlignment(.center)

            Button("Add Knowledge Manually") {
                showSaveSheet = true
            }
            .buttonStyle(.borderedProminent)
            .tint(VibeAIColors.purplePrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptySearchView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(VibeAIColors.textTertiary.opacity(0.5))
            Text("No results for \"\(viewModel.searchQuery)\"")
                .font(.system(size: 14))
                .foregroundColor(VibeAIColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Save Popover

    private var savePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Knowledge")
                .font(.system(size: 15, weight: .semibold))

            Text("Add a fact, preference, or insight to your knowledge graph.")
                .font(.system(size: 12))
                .foregroundColor(VibeAIColors.textTertiary)

            TextEditor(text: $newMemoryText)
                .font(.system(size: 13))
                .frame(width: 320, height: 100)
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
                .foregroundColor(VibeAIColors.textSecondary)

                Button("Save") {
                    Task {
                        let saved = await viewModel.save(text: newMemoryText)
                        if saved {
                            newMemoryText = ""
                            showSaveSheet = false
                            await viewModel.loadAll()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(VibeAIColors.purplePrimary)
                .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
