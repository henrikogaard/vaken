import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

final class Enclosure: NSObject, XMLParserDelegate {
    var attributes: [[String: String]] = []
    var versions: [String] = []
    private var versionText: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "enclosure" { attributes.append(attributeDict) }
        if elementName == "sparkle:version" { versionText = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if versionText != nil { versionText?.append(string) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "sparkle:version", let text = versionText {
            versions.append(text.trimmingCharacters(in: .whitespacesAndNewlines)); versionText = nil
        }
    }
}

// Usage: swift scripts/verify-appcast.swift appcast.xml archive.zip Vaken.app
// Public key and expected version are read from the built bundle, never a secret.
do {
    guard CommandLine.arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
    let feed = URL(fileURLWithPath: CommandLine.arguments[1])
    let archive = URL(fileURLWithPath: CommandLine.arguments[2])
    let app = URL(fileURLWithPath: CommandLine.arguments[3])
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] ?? [:]
    guard let publicKey = info["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: publicKey),
          let version = info["CFBundleVersion"] as? String else { throw CocoaError(.coderInvalidValue) }
    let reader = Enclosure(), parser = XMLParser(data: try Data(contentsOf: feed))
    parser.shouldResolveExternalEntities = false
    parser.delegate = reader
    guard parser.parse(), reader.attributes.count == 1, let entry = reader.attributes.first,
          reader.versions.count <= 1,
          (reader.versions.first ?? entry["sparkle:version"]) == version,
          entry["sparkle:version"] == nil || entry["sparkle:version"] == version,
          let location = entry["url"], let url = URL(string: location), url.scheme == "https", url.host != nil,
          url.user == nil, url.password == nil, url.fragment == nil,
          url.lastPathComponent == archive.lastPathComponent,
          let signatureText = entry["sparkle:edSignature"], let signature = Data(base64Encoded: signatureText),
          let size = entry["length"].flatMap(Int.init) else { throw CocoaError(.coderInvalidValue) }
    let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard bytes.count == size, key.isValidSignature(signature, for: bytes) else { throw CocoaError(.coderInvalidValue) }
    print("Appcast version, HTTPS URL, archive length and Ed25519 signature verified.")
} catch {
    fputs("Appcast verification failed. Check metadata, archive and embedded public key.\n", stderr)
    exit(1)
}
