import SwiftUI

/// Visual knowledge graph — rooms as large circles with memory nodes orbiting them.
/// Interactive: click room to filter, click node to see details.
struct KnowledgeGraphView: View {
    let rooms: [GraphRoom]
    let selectedRoom: String?
    let onSelectRoom: (String?) -> Void
    let onSelectNode: (GraphMemoryNode) -> Void

    struct GraphRoom: Identifiable {
        let id: String
        var name: String
        var count: Int
        var nodes: [GraphMemoryNode]
        var color: Color
    }

    struct GraphMemoryNode: Identifiable {
        let id: String
        let payload: String
        let kind: String
    }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = min(geo.size.width, geo.size.height) * 0.35
            let roomCount = rooms.count

            ZStack {
                // Draw edges from rooms to center
                ForEach(Array(rooms.enumerated()), id: \.element.id) { index, room in
                    let angle = angleFor(index: index, total: roomCount)
                    let pos = positionFor(angle: angle, radius: radius, center: center)
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: pos)
                    }
                    .stroke(room.color.opacity(0.15), lineWidth: 1)
                }

                // Center hub
                Circle()
                    .fill(VibeAIColors.purplePrimary.opacity(0.3))
                    .frame(width: 60, height: 60)
                    .position(center)
                    .overlay(
                        Text("VibeAi")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .position(center)
                    )

                // Room nodes
                ForEach(Array(rooms.enumerated()), id: \.element.id) { index, room in
                    let angle = angleFor(index: index, total: roomCount)
                    let pos = positionFor(angle: angle, radius: radius, center: center)
                    let isSelected = selectedRoom == room.name

                    // Room circle
                    Button(action: {
                        if isSelected {
                            onSelectRoom(nil)
                        } else {
                            onSelectRoom(room.name)
                        }
                    }) {
                        VStack(spacing: 2) {
                            ZStack {
                                Circle()
                                    .fill(room.color.opacity(isSelected ? 0.8 : 0.3))
                                    .frame(width: roomSize(room.count), height: roomSize(room.count))

                                Text("\(room.count)")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                            }

                            Text(room.name.capitalized)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(isSelected ? room.color : VibeAIColors.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .position(pos)

                    // Memory node dots orbiting the room
                    ForEach(Array(room.nodes.prefix(8).enumerated()), id: \.element.id) { nodeIdx, node in
                        let nodeAngle = angleFor(index: nodeIdx, total: min(room.nodes.count, 8))
                        let nodeRadius: CGFloat = roomSize(room.count) / 2 + 16
                        let nodePos = positionFor(angle: nodeAngle, radius: nodeRadius, center: pos)

                        Button(action: { onSelectNode(node) }) {
                            Circle()
                                .fill(room.color.opacity(0.6))
                                .frame(width: 8, height: 8)
                        }
                        .buttonStyle(.plain)
                        .help(String(node.payload.prefix(60)))
                        .position(nodePos)
                    }
                }
            }
        }
    }

    private func roomSize(_ count: Int) -> CGFloat {
        let base: CGFloat = 40
        let scale = CGFloat(min(count, 20)) * 2
        return base + scale
    }

    private func angleFor(index: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return (Double(index) / Double(total)) * 2 * .pi - .pi / 2
    }

    private func positionFor(angle: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        CGPoint(
            x: center.x + radius * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(sin(angle))
        )
    }
}
