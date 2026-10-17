import Foundation
import FSKit

public final class GCSFItem: FSItem, @unchecked Sendable {
    public let inode: Inode

    public init(inode: Inode) {
        self.inode = inode
        super.init()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError()
    }
}
