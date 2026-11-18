import CoreData

extension DatabaseObject {

    /// Whether the object was deleted or detached from its context — the state a batch delete in
    /// another context leaves behind.
    ///
    /// A pending fault is fired first: when its row was deleted by a batch request, Core Data
    /// marks the object deleted and every attribute reads `nil`, so a non-optional `@NSManaged`
    /// property read afterwards would trap. Checking `isDeleted` before firing the fault let such
    /// objects through.
    public var isZombie: Bool {
        guard !isDeleted, managedObjectContext != nil else { return true }
        if isFault {
            willAccessValue(forKey: nil)
            didAccessValue(forKey: nil)
        }
        return isDeleted || managedObjectContext == nil
    }

    /// The object, or `nil` when it is a zombie.
    public var nilIfZombie: Self? {
        isZombie ? nil : self
    }
}

extension Array where Element: DatabaseObject {

    /// The objects that are not zombies.
    public func removingZombies() -> [Element] {
        filter { !$0.isZombie }
    }
}

extension Set where Element: DatabaseObject {

    /// The objects that are not zombies.
    public func removingZombies() -> [Element] {
        filter { !$0.isZombie }
    }
}
