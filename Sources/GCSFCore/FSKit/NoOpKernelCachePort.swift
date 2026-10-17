public struct NoOpKernelCachePort: KernelCachePort {
    public init() {}

    public func invalidateCachedItem(_ inode: Inode) async {}

    public func revokeCachedItem(_ inode: Inode) async {}
}
