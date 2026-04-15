import Foundation

/// ViewModel for the Knowledge page — powered by local Eidetic Memory graph.
/// Calls the Rust backend endpoints: /api/memory/query, /api/memory/status, /api/memory/save
@MainActor
class KnowledgeViewModel: ObservableObject {

    // MARK: - Published State

    @Published var memories: [KnowledgeItem] = []
    @Published var rooms: [String] = []
    @Published var nodeCount: Int = 0
    @Published var edgeCount: Int = 0
    @Published var embeddingCount: Int = 0
    @Published var searchQuery: String = ""
    @Published var isLoading = false
    @Published var isSearching = false
    @Published var errorMessage: String?

    // MARK: - Types

    struct KnowledgeItem: Identifiable {
        let id: String
        let kind: String
        let payload: String
        let score: Float
        let alias: String?

        var roomName: String? {
            alias?.components(separatedBy: ":").first
        }
    }

    struct StatusResponse: Decodable {
        let ok: Bool
        let nodes: Int?
        let edges: Int?
        let embeddings: Int?
        let rooms: [String]?
        let error: String?
    }

    struct QueryResponse: Decodable {
        let ok: Bool
        let results: [QueryResult]?
        let error: String?
    }

    struct QueryResult: Decodable {
        let id: String
        let kind: String
        let payload: String
        let score: Float
        let alias: String?
    }

    struct SaveResponse: Decodable {
        let ok: Bool
        let stored: Int?
        let error: String?
    }

    // MARK: - API Base

    private var baseURL: String {
        ProcessInfo.processInfo.environment["OMI_API_URL"] ?? "http://localhost:8080"
    }

    // MARK: - Load Status

    func loadStatus() async {
        do {
            guard let url = URL(string: "\(baseURL)/api/memory/status") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(StatusResponse.self, from: data)

            if response.ok {
                nodeCount = response.nodes ?? 0
                edgeCount = response.edges ?? 0
                embeddingCount = response.embeddings ?? 0
                rooms = response.rooms ?? []
            } else {
                errorMessage = response.error
            }
        } catch {
            logError("KnowledgeViewModel: Failed to load status", error: error)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Load All

    /// Load all memories by querying with a broad term.
    /// Eidetic's recall pipeline returns top results ranked by relevance.
    func loadAll() async {
        isLoading = true
        defer { isLoading = false }

        do {
            guard let url = URL(string: "\(baseURL)/api/memory/query") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": "*",
                "limit": 50,
            ])

            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(QueryResponse.self, from: data)

            if response.ok, let results = response.results {
                memories = results.map { r in
                    KnowledgeItem(id: r.id, kind: r.kind, payload: r.payload, score: r.score, alias: r.alias)
                }
            }
        } catch {
            logError("KnowledgeViewModel: loadAll failed", error: error)
        }
    }

    // MARK: - Search

    func search(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            memories = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            guard let url = URL(string: "\(baseURL)/api/memory/query") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query,
                "limit": 20,
            ])

            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(QueryResponse.self, from: data)

            if response.ok, let results = response.results {
                memories = results.map { r in
                    KnowledgeItem(id: r.id, kind: r.kind, payload: r.payload, score: r.score, alias: r.alias)
                }
            } else {
                errorMessage = response.error
            }
        } catch {
            logError("KnowledgeViewModel: Search failed", error: error)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Save

    func save(text: String, source: String = "manual") async -> Bool {
        do {
            guard let url = URL(string: "\(baseURL)/api/memory/save") else { return false }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "text": text,
                "source": source,
            ])

            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(SaveResponse.self, from: data)

            if response.ok {
                log("KnowledgeViewModel: Saved \(response.stored ?? 0) memories")
                await loadStatus()
                return true
            } else {
                errorMessage = response.error
                return false
            }
        } catch {
            logError("KnowledgeViewModel: Save failed", error: error)
            errorMessage = error.localizedDescription
            return false
        }
    }
}
