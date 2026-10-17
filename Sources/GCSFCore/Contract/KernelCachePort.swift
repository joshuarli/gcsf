public protocol KernelCachePort: Sendable {
    func invalidateCachedItem(_ inode: Inode) async
    func revokeCachedItem(_ inode: Inode) async
}
