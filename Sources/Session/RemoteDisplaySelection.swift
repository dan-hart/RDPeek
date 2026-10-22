import CoreGraphics
import RDPKit

/// Explicit choices keep the complete server descriptor, never an array index.
enum RemoteDisplaySelection: Equatable {
    case all
    case only([RDPMonitorDefinition])

    func selected(in monitors: [RDPMonitorDefinition]) -> [RDPMonitorDefinition] {
        switch self {
        case .all: monitors
        case let .only(selected): monitors.filter { selected.contains($0) }
        }
    }

    mutating func reconcile(with monitors: [RDPMonitorDefinition]) {
        guard case .only = self else { return }
        let surviving = selected(in: monitors)
        self = surviving.isEmpty ? .all : .only(surviving)
    }

    mutating func toggle(_ monitor: RDPMonitorDefinition, in monitors: [RDPMonitorDefinition]) {
        guard monitors.contains(monitor) else { return }
        var selected = selected(in: monitors)
        if selected.contains(monitor) {
            guard selected.count > 1 else { return }
            selected.removeAll { $0 == monitor }
        } else {
            selected.append(monitor)
        }
        self = .only(selected)
    }
}

/// All source rectangles use the composed frame's top-left pixel coordinates.
/// Local destination rectangles use AppKit's bottom-left coordinates.
struct RemoteDisplayViewport: Equatable {
    let frameSize: CGSize
    let monitors: [RDPMonitorDefinition]
    let sourceRect: CGRect
    let visibleRects: [CGRect]

    init(frameSize: CGSize, monitors: [RDPMonitorDefinition], selection: RemoteDisplaySelection = .all) {
        self.frameSize = frameSize
        let frameRect = CGRect(origin: .zero, size: frameSize)
        let layout = Self.validatedLayout(monitors, frameSize: frameSize)
        self.monitors = layout.isEmpty ? [] : monitors
        let selected = selection.selected(in: self.monitors)
        let rects = zip(monitors, layout).compactMap { monitor, rect in
            selected.contains(monitor) ? rect : nil
        }
        visibleRects = rects.isEmpty ? [frameRect] : rects
        sourceRect = visibleRects.reduce(CGRect.null) { $0.union($1) }
    }

    init(frame: RDPFrameMetadata, selection: RemoteDisplaySelection = .all) {
        self.init(frameSize: CGSize(width: Int(frame.width), height: Int(frame.height)),
                  monitors: frame.monitorDefinitions, selection: selection)
    }

    func destinationRect(in bounds: CGRect) -> CGRect {
        guard sourceRect.width > 0, sourceRect.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / sourceRect.width, bounds.height / sourceRect.height)
        let size = CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func localRect(for source: CGRect, in bounds: CGRect) -> CGRect {
        let destination = destinationRect(in: bounds)
        guard sourceRect.width > 0 else { return .zero }
        let scale = destination.width / sourceRect.width
        return CGRect(x: destination.minX + (source.minX - sourceRect.minX) * scale,
                      y: destination.maxY - (source.maxY - sourceRect.minY) * scale,
                      width: source.width * scale, height: source.height * scale)
    }

    func remotePoint(from point: CGPoint, in bounds: CGRect) -> RDPRemotePoint? {
        let destination = destinationRect(in: bounds)
        guard point.x.isFinite, point.y.isFinite, destination.width > 0,
              point.x >= destination.minX, point.x < destination.maxX,
              point.y >= destination.minY, point.y < destination.maxY else { return nil }
        let scale = sourceRect.width / destination.width
        let x = sourceRect.minX + (point.x - destination.minX) * scale
        // The very bottom edge still refers to the last row, not the next pixel.
        let y = min(sourceRect.maxY - 1, sourceRect.minY + (destination.maxY - point.y) * scale)
        let remote = CGPoint(x: floor(x), y: floor(y))
        guard visibleRects.contains(where: { $0.contains(remote) }),
              remote.x >= 0, remote.y >= 0,
              remote.x <= CGFloat(UInt16.max), remote.y <= CGFloat(UInt16.max) else { return nil }
        return RDPRemotePoint(x: UInt16(remote.x), y: UInt16(remote.y))
    }

    private static func validatedLayout(_ monitors: [RDPMonitorDefinition], frameSize: CGSize) -> [CGRect] {
        guard frameSize.width.isFinite, frameSize.height.isFinite,
              frameSize.width > 0, frameSize.height > 0,
              monitors.allSatisfy({ $0.left <= $0.right && $0.top <= $0.bottom }),
              let minX = monitors.map(\.left).min(), let minY = monitors.map(\.top).min() else { return [] }
        let rectangles = monitors.map { monitor in
            CGRect(x: Double(monitor.left) - Double(minX), y: Double(monitor.top) - Double(minY),
                   width: Double(monitor.right) - Double(monitor.left) + 1,
                   height: Double(monitor.bottom) - Double(monitor.top) + 1)
        }
        guard rectangles.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.maxX <= frameSize.width && $0.maxY <= frameSize.height }) else {
            return []
        }
        for (index, rect) in rectangles.enumerated() {
            guard rectangles.dropFirst(index + 1).allSatisfy({ rect.intersection($0).isEmpty }) else { return [] }
        }
        return rectangles
    }
}

func remoteDisplayAllowsWindowMatching(hasPresentedFrame: Bool, reportedMonitorCount: Int) -> Bool {
    hasPresentedFrame && reportedMonitorCount <= 1
}
