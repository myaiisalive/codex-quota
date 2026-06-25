import Foundation

enum FloatingEdgeAttachment: String {
    case left
    case right
    case top
    case bottom

    var isHorizontalBar: Bool {
        self == .top || self == .bottom
    }
}

@MainActor
final class FloatingPanelState: ObservableObject {
    static let edgeSnapEnabledKey = "edgeSnapEnabled"

    @Published var attachedEdge: FloatingEdgeAttachment?
    @Published var showsEdgeBar = false

    var isEdgeBarVisible: Bool {
        attachedEdge != nil && showsEdgeBar
    }
}
