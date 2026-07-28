import Foundation

/// Plain application payload transported only inside authenticated TLS. The
/// server encrypts this payload at rest; the client owns no encryption key.
public struct ServerClipboardPayload: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var item: ClipboardItem
    public var imageData: Data?

    public init(schemaVersion: Int = 2, item: ClipboardItem, imageData: Data? = nil) {
        self.schemaVersion = schemaVersion
        self.item = item
        self.imageData = imageData
    }
}
