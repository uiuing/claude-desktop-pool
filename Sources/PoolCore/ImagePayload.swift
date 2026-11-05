import Foundation

public struct ImagePayload: Equatable, Sendable {
    public let data: Data
    public let mediaType: String
    public let fileExtension: String

    public init(block: JSONValue) throws {
        guard block["type"]?.stringValue == "image", let source = block["source"],
              source.objectValue.map({ Set($0.keys) == ["type", "media_type", "data"] }) == true,
              source["type"]?.stringValue == "base64", let media = source["media_type"]?.stringValue,
              let encoded = source["data"]?.stringValue, encoded.utf8.count <= 5_592_408,
              let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= 4 * 1024 * 1024 else {
            throw BridgeFailure.unsupported("Images must be attached as bounded base64 data. Remote image URLs are not fetched.")
        }
        let bytes = [UInt8](data.prefix(16))
        let actual: (String, String)?
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { actual = ("image/png", "png") }
        else if bytes.starts(with: [255, 216, 255]) { actual = ("image/jpeg", "jpg") }
        else if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { actual = ("image/gif", "gif") }
        else if bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WEBP".utf8) { actual = ("image/webp", "webp") }
        else { actual = nil }
        guard let actual, media == actual.0 else { throw BridgeFailure.invalidRequest("The image data does not match its declared format.") }
        self.data = data; mediaType = media; fileExtension = actual.1
    }
}
