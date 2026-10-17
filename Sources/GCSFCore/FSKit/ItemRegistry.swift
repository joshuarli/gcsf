import Foundation
import FSKit
import Synchronization

struct PlannedEntry: Equatable, Sendable {
    var name: String
    var kind: EngineItemKind
    var inode: UInt64
    var nextCookie: UInt64
}

public struct KernelCacheAttempt: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable {
        case invalidate
        case revoke
    }

    public var inode: Inode
    public var action: Action
    public var calledSetCacheState: Bool
    public var kernelErrorDomain: String?
    public var kernelErrorCode: Int?
    public var kernelEffectVerified: Bool
}

final class ItemRegistry: @unchecked Sendable {
    struct Record {
        var item: GCSFItem
        var parent: Inode
        var kind: EngineItemKind
        var cacheMode: FSVolume.DataCacheMode
    }

    private struct State {
        var records: [Inode: Record] = [:]
        var attempts: [KernelCacheAttempt] = []
    }

    private let state = Mutex(State())

    func adopt(inode: Inode, parent: Inode, kind: EngineItemKind) -> GCSFItem {
        state.withLock { state in
            if var record = state.records[inode] {
                record.parent = parent
                record.kind = kind
                state.records[inode] = record
                return record.item
            }
            let item = GCSFItem(inode: inode)
            state.records[inode] = Record(item: item, parent: parent, kind: kind, cacheMode: .none)
            return item
        }
    }

    func parent(of inode: Inode) -> Inode {
        state.withLock { state in
            state.records[inode]?.parent ?? inode
        }
    }

    func kind(of inode: Inode) -> EngineItemKind? {
        state.withLock { $0.records[inode]?.kind }
    }

    func item(for inode: Inode) -> GCSFItem? {
        state.withLock { $0.records[inode]?.item }
    }

    func setCacheMode(_ inode: Inode, _ mode: FSVolume.DataCacheMode) {
        state.withLock { state in
            state.records[inode]?.cacheMode = mode
        }
    }

    func cacheMode(of inode: Inode) -> FSVolume.DataCacheMode {
        state.withLock { $0.records[inode]?.cacheMode ?? .none }
    }

    func reclaim(_ item: GCSFItem) {
        let flag = Mutex(false)
        state.withLock { state in
            _ = item.tryReclaim {
                flag.withLock { $0 = true }
            }
            if flag.withLock({ $0 }) {
                state.records.removeValue(forKey: item.inode)
            }
        }
    }

    func removeAll() {
        state.withLock { $0.records.removeAll() }
    }

    func record(_ attempt: KernelCacheAttempt) {
        state.withLock { $0.attempts.append(attempt) }
    }

    func attempts() -> [KernelCacheAttempt] {
        state.withLock { $0.attempts }
    }
}
