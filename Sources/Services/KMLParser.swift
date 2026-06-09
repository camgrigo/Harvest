import Foundation
import CoreLocation
import Compression
import UniformTypeIdentifiers

extension UTType {
    /// Keyhole Markup Language. Declared by extension since there's no system constant.
    static let kml = UTType(importedAs: "com.google.earth.kml", conformingTo: .xml)
    /// Zipped KML (KMZ). Declared by extension; conforms to the generic ZIP archive type.
    static let kmz = UTType(importedAs: "com.google.earth.kmz", conformingTo: .zip)
}

/// Parses KML and KMZ files (KMZ = a ZIP containing a .kml, usually `doc.kml`) to extract
/// Placemark polygons and their names. Dependency-free: KMZ is unzipped by reading the ZIP
/// local-file headers and inflating stored/deflated entries with Apple's `Compression`
/// framework — no third-party pod required. All work is synchronous; call it off the main
/// actor for large files.
enum KMLParser {

    /// One Placemark's geometry: a name and a boundary polygon (outer ring).
    struct Placemark: Equatable {
        var name: String
        var coordinates: [CLLocationCoordinate2D]

        static func == (lhs: Placemark, rhs: Placemark) -> Bool {
            guard lhs.name == rhs.name, lhs.coordinates.count == rhs.coordinates.count else { return false }
            for (a, b) in zip(lhs.coordinates, rhs.coordinates) {
                if a.latitude != b.latitude || a.longitude != b.longitude { return false }
            }
            return true
        }
    }

    enum ParseError: Error, LocalizedError {
        case unzipFailed
        case noKMLInArchive
        case xmlParseFailed

        var errorDescription: String? {
            switch self {
            case .unzipFailed:     return "Couldn't read the KMZ archive."
            case .noKMLInArchive:  return "No .kml file found inside the KMZ."
            case .xmlParseFailed:  return "Couldn't read the KML file."
            }
        }
    }

    /// Parse a KML or KMZ file. KMZ is detected by the "PK" ZIP magic bytes.
    /// Returns one Placemark per `<Placemark>` that has a `<Polygon>` outer ring.
    static func parse(data: Data) throws -> [Placemark] {
        let kmlData: Data
        if data.count > 2, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B {
            kmlData = try extractKML(fromKMZ: data)
        } else {
            kmlData = data
        }
        return try parseKML(kmlData)
    }

    // MARK: - KMZ (ZIP) extraction

    /// Find and inflate the first `.kml` entry (preferring `doc.kml`) inside a ZIP archive.
    private static func extractKML(fromKMZ data: Data) throws -> Data {
        let entries = ZipReader.entries(in: data)
        guard !entries.isEmpty else { throw ParseError.unzipFailed }
        let kmlEntry = entries.first { $0.name.lowercased() == "doc.kml" }
            ?? entries.first { $0.name.lowercased().hasSuffix(".kml") }
        guard let kmlEntry else { throw ParseError.noKMLInArchive }
        guard let kml = ZipReader.contents(of: kmlEntry, in: data) else { throw ParseError.unzipFailed }
        return kml
    }

    // MARK: - KML XML parsing

    private static func parseKML(_ data: Data) throws -> [Placemark] {
        let parser = XMLParser(data: data)
        let delegate = KMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.xmlParseFailed }
        return delegate.placemarks
    }

    private final class KMLDelegate: NSObject, XMLParserDelegate {
        var placemarks: [Placemark] = []
        private var currentName = ""
        private var currentCoordinates: [CLLocationCoordinate2D] = []
        private var inPlacemark = false
        private var inPolygon = false
        private var inOuterBoundary = false
        private var inLinearRing = false
        private var inName = false
        private var inCoordinates = false
        private var coordinateBuffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch localName(elementName) {
            case "placemark":
                inPlacemark = true
                currentName = ""
                currentCoordinates = []
            case "name":
                if inPlacemark, !inPolygon { inName = true }
            case "polygon":       inPolygon = inPlacemark
            case "outerboundaryis": inOuterBoundary = inPolygon
            case "linearring":    inLinearRing = inOuterBoundary
            case "coordinates":
                if inLinearRing { inCoordinates = true; coordinateBuffer = "" }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch localName(elementName) {
            case "name":
                inName = false
            case "coordinates":
                if inCoordinates {
                    // Only take the outer ring (the first one parsed for this placemark).
                    if currentCoordinates.isEmpty {
                        currentCoordinates = Self.parseCoordinates(coordinateBuffer)
                    }
                    inCoordinates = false
                }
            case "linearring":      inLinearRing = false
            case "outerboundaryis": inOuterBoundary = false
            case "polygon":         inPolygon = false
            case "placemark":
                let name = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentCoordinates.isEmpty {
                    placemarks.append(Placemark(name: name, coordinates: currentCoordinates))
                }
                inPlacemark = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inCoordinates {
                coordinateBuffer.append(string)
            } else if inName {
                currentName.append(string)
            }
        }

        private func localName(_ element: String) -> String {
            // Strip any namespace prefix (e.g. "kml:Placemark") and lowercase.
            (element.split(separator: ":").last.map(String.init) ?? element).lowercased()
        }

        /// KML coordinates are whitespace-separated "lon,lat[,alt]" tuples.
        static func parseCoordinates(_ raw: String) -> [CLLocationCoordinate2D] {
            raw
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
                .compactMap { token in
                    let parts = token.split(separator: ",").map(String.init)
                    guard parts.count >= 2,
                          let lon = Double(parts[0]),
                          let lat = Double(parts[1]) else { return nil }
                    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
        }
    }
}

/// Minimal ZIP reader: enumerates local file entries and inflates stored (0) or
/// deflated (8) data using Apple's `Compression` framework. Sufficient for KMZ files,
/// which Google Earth / mapping tools write with standard deflate.
enum ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let dataOffset: Int   // offset into the archive where this entry's data starts
    }

    private static let localHeaderSignature: UInt32 = 0x0403_4b50

    static func entries(in data: Data) -> [Entry] {
        var result: [Entry] = []
        let bytes = [UInt8](data)
        var i = 0
        while i + 30 <= bytes.count {
            let sig = readUInt32(bytes, i)
            guard sig == localHeaderSignature else { break }
            let method = readUInt16(bytes, i + 8)
            let compressedSize = Int(readUInt32(bytes, i + 18))
            let uncompressedSize = Int(readUInt32(bytes, i + 22))
            let nameLen = Int(readUInt16(bytes, i + 26))
            let extraLen = Int(readUInt16(bytes, i + 28))
            let nameStart = i + 30
            guard nameStart + nameLen <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart ..< nameStart + nameLen], as: UTF8.self)
            let dataOffset = nameStart + nameLen + extraLen
            // Bit 3 of the general-purpose flag means sizes live in a trailing data descriptor;
            // such streamed entries aren't supported by this minimal reader. KMZ writers
            // generally include sizes in the header, so this is fine in practice.
            result.append(Entry(name: name, method: method,
                                compressedSize: compressedSize,
                                uncompressedSize: uncompressedSize,
                                dataOffset: dataOffset))
            i = dataOffset + compressedSize
        }
        return result
    }

    static func contents(of entry: Entry, in data: Data) -> Data? {
        guard entry.compressedSize > 0,
              entry.dataOffset + entry.compressedSize <= data.count else { return nil }
        let slice = data.subdata(in: entry.dataOffset ..< entry.dataOffset + entry.compressedSize)
        switch entry.method {
        case 0:   return slice                                   // stored, no compression
        case 8:   return inflate(slice, expectedSize: entry.uncompressedSize)  // deflate
        default:  return nil
        }
    }

    /// Inflate raw DEFLATE data (ZIP method 8) using zlib's raw stream via Compression.
    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        let capacity = max(expectedSize, data.count * 4, 64 * 1024)
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let written = compression_decode_buffer(
                dst, capacity,
                srcBase, data.count,
                nil, COMPRESSION_ZLIB   // COMPRESSION_ZLIB == raw DEFLATE in Apple's API
            )
            guard written > 0 else { return nil }
            return Data(bytes: dst, count: written)
        }
    }

    private static func readUInt16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }
    private static func readUInt32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
}
