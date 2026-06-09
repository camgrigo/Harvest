import XCTest
import CoreLocation
@testable import Harvest

final class KMLParserTests: XCTestCase {

    private let sampleKML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
            <Document>
                <Placemark>
                    <name>Territory A</name>
                    <Polygon>
                        <outerBoundaryIs>
                            <LinearRing>
                                <coordinates>
                                    -74.0,40.1,0
                                    -74.1,40.1,0
                                    -74.1,40.2,0
                                    -74.0,40.2,0
                                    -74.0,40.1,0
                                </coordinates>
                            </LinearRing>
                        </outerBoundaryIs>
                    </Polygon>
                </Placemark>
            </Document>
        </kml>
        """.data(using: .utf8)!

    func testParseKMLExtractsPlacemark() throws {
        let result = try KMLParser.parse(data: sampleKML)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "Territory A")
        XCTAssertEqual(result.first?.coordinates.count, 5)
    }

    func testCoordinatesAreLatLonSwappedFromKMLOrder() throws {
        // KML stores lon,lat — parser must surface lat,lon.
        let first = try XCTUnwrap(try KMLParser.parse(data: sampleKML).first?.coordinates.first)
        XCTAssertEqual(first.latitude, 40.1, accuracy: 0.0001)
        XCTAssertEqual(first.longitude, -74.0, accuracy: 0.0001)
    }

    func testMultiplePlacemarks() throws {
        let kml = """
            <kml><Document>
              <Placemark><name>One</name><Polygon><outerBoundaryIs><LinearRing>
                <coordinates>-1,1 -1,2 -2,2 -1,1</coordinates>
              </LinearRing></outerBoundaryIs></Polygon></Placemark>
              <Placemark><name>Two</name><Polygon><outerBoundaryIs><LinearRing>
                <coordinates>-3,3 -3,4 -4,4 -3,3</coordinates>
              </LinearRing></outerBoundaryIs></Polygon></Placemark>
            </Document></kml>
            """.data(using: .utf8)!
        let result = try KMLParser.parse(data: kml)
        XCTAssertEqual(result.map(\.name), ["One", "Two"])
        XCTAssertEqual(result[0].coordinates.count, 4)
    }

    func testNamespacePrefixedElementsParse() throws {
        let kml = """
            <kml:kml><kml:Document><kml:Placemark><kml:name>Pre</kml:name>
              <kml:Polygon><kml:outerBoundaryIs><kml:LinearRing>
                <kml:coordinates>-1,1 -1,2 -2,2 -1,1</kml:coordinates>
              </kml:LinearRing></kml:outerBoundaryIs></kml:Polygon>
            </kml:Placemark></kml:Document></kml:kml>
            """.data(using: .utf8)!
        let result = try KMLParser.parse(data: kml)
        XCTAssertEqual(result.first?.name, "Pre")
        XCTAssertEqual(result.first?.coordinates.count, 4)
    }

    func testEmptyKMLReturnsEmpty() throws {
        let emptyKML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <kml xmlns="http://www.opengis.net/kml/2.2"><Document></Document></kml>
            """.data(using: .utf8)!
        XCTAssertEqual(try KMLParser.parse(data: emptyKML).count, 0)
    }

    func testPlacemarkWithoutPolygonIsSkipped() throws {
        let kml = """
            <kml><Document><Placemark><name>PointOnly</name>
              <Point><coordinates>-74,40,0</coordinates></Point>
            </Placemark></Document></kml>
            """.data(using: .utf8)!
        XCTAssertEqual(try KMLParser.parse(data: kml).count, 0)
    }
}
