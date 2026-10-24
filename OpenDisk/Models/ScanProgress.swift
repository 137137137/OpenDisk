import Foundation

enum ScanPhase: Equatable, Sendable {
    case checkingChanges
    case applyingChanges
    case scanning
}

struct ScanProgress: Equatable, Sendable {
    let scannedBytes: Int64
    let itemsScanned: Int
    var phase: ScanPhase = .scanning
    var stepsCompleted = 0
    var stepsTotal = 0
}
