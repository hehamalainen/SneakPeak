public enum DisplaySelection {
    public static func choose(available: [UInt32], preferred: UInt32?, active: UInt32?) -> UInt32? {
        if let preferred, available.contains(preferred) { return preferred }
        if let active, available.contains(active) { return active }
        return available.first
    }
}
