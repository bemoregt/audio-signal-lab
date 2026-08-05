//
//  SpectrumHistory.swift
//  AudioWaterfall
//

import Foundation

/// Fixed-length ring of spectrum rows — the waterfall mesh's source data.
/// `push` and `snapshot`/`version` may be called from different threads (a timer thread
/// pushing new rows, a SceneKit render thread reading them), so access is lock-guarded.
final class SpectrumHistory {
    let timeSteps: Int
    let binCount: Int

    private var rows: [[Float]]
    private var currentVersion = 0
    private let lock = NSLock()

    init(timeSteps: Int = 64, binCount: Int = 192) {
        self.timeSteps = timeSteps
        self.binCount = binCount
        self.rows = Array(repeating: [Float](repeating: 0, count: binCount), count: timeSteps)
    }

    var version: Int {
        lock.lock(); defer { lock.unlock() }
        return currentVersion
    }

    /// Pushes a new row as the newest (index 0), dropping the oldest row.
    func push(_ row: [Float]) {
        lock.lock()
        rows.removeLast()
        rows.insert(row, at: 0)
        currentVersion += 1
        lock.unlock()
    }

    func snapshot() -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        return rows
    }
}
