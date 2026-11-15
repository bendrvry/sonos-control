import Foundation
import SonosCore

final class ProtocolTests {
    func testStereoPairAndSatellitesAreOneLogicalRoom() throws {
        let xml = """
        <ZoneGroups><ZoneGroup Coordinator="FIVE" ID="FIVE:1">
        <ZoneGroupMember UUID="FIVE" ZoneName="Attic &amp; lounge" Location="http://192.168.1.10:1400/xml/device_description.xml"/>
        <ZoneGroupMember UUID="LEFT" ZoneName="Desk" Location="http://192.168.1.11:1400/xml/device_description.xml" ChannelMapSet="LEFT:LF;RIGHT:RF">
          <Satellite UUID="RIGHT" ZoneName="Desk" Location="http://192.168.1.12:1400/xml/device_description.xml" Invisible="1"/>
        </ZoneGroupMember>
        <ZoneGroupMember UUID="RIGHT" ZoneName="Desk" Invisible="1" Location="http://192.168.1.12:1400/xml/device_description.xml"/>
        </ZoneGroup></ZoneGroups>
        """
        let groups = try Topology.parse(xml)
        expectEqual(groups.count, 1)
        expectEqual(groups[0].rooms.count, 2)
        expectEqual(groups[0].rooms[0].name, "Attic & lounge")
        expectTrue(groups[0].rooms[1].isStereoPair)
        expectEqual(groups[0].coordinatorURL.host, "192.168.1.10")
    }
    func testSeparateGroupedOnesRemainSeparate() throws {
        let groups = try Topology.parse("""
        <ZoneGroups><ZoneGroup Coordinator="A" ID="A:2">
        <ZoneGroupMember UUID="A" ZoneName="Left desk" Location="http://10.0.0.2:1400/xml/device_description.xml"/>
        <ZoneGroupMember UUID="B" ZoneName="Right desk" Location="http://10.0.0.3:1400/xml/device_description.xml"/>
        </ZoneGroup></ZoneGroups>
        """)
        expectEqual(groups[0].rooms.count, 2)
        expectTrue(groups[0].rooms.allSatisfy { !$0.isStereoPair })
    }
    func testMissingCoordinatorIsRejectedInsteadOfControllingAnotherRoom() {
        expectThrows(try Topology.parse("<ZoneGroups><ZoneGroup Coordinator='UNKNOWN' ID='g'><ZoneGroupMember UUID='A'/></ZoneGroup></ZoneGroups>"))
    }
    func testEscapedTopologyInSOAPEnvelope() throws {
        let data = Data("""
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetZoneGroupStateResponse xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"><ZoneGroupState>&lt;ZoneGroups&gt;&lt;/ZoneGroups&gt;</ZoneGroupState></u:GetZoneGroupStateResponse></s:Body></s:Envelope>
        """.utf8)
        let response = try SOAP.response(data, statusCode: 200)
        expectEqual(response.first("ZoneGroupState")?.text, "<ZoneGroups></ZoneGroups>")
    }
    func testUPnPFaultIsNotTreatedAsSuccess() {
        let data = Data("""
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><UPnPError><errorCode>701</errorCode><errorDescription>Transition not available</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>
        """.utf8)
        expectThrows(try SOAP.response(data, statusCode: 500)) { error in
            expectTrue(error.localizedDescription.contains("701"))
        }
    }
    func testSOAPUsesCorrectGroupEndpointAndAction() throws {
        let request = try SOAP.request(baseURL: LocalAddress.baseURL("192.168.1.8"), service: .group, action: "SetGroupVolume", arguments: [("InstanceID", "0"), ("DesiredVolume", "23")])
        expectEqual(request.url?.path, "/MediaRenderer/GroupRenderingControl/Control")
        expectEqual(request.value(forHTTPHeaderField: "SOAPACTION"), "\"urn:schemas-upnp-org:service:GroupRenderingControl:1#SetGroupVolume\"")
        let xml = try SonosXML.parse(request.httpBody!)
        expectEqual(xml.first("DesiredVolume")?.text, "23")
        expectNil(xml.first("Channel"))
    }
    func testUntrustedDiscoveryCannotReachPublicHosts() throws {
        expectNil(SSDP.location(from: "HTTP/1.1 200 OK\r\nLOCATION: http://example.com:1400/a\r\n"))
        expectNil(SSDP.location(from: "HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:1400/a\r\n"))
        expectNil(SSDP.location(from: "HTTP/1.1 200 OK\r\nLOCATION: https://192.168.1.8:1400/a\r\n"))
        expectThrows(try LocalAddress.baseURL("192.168.1.8/path"))
        expectThrows(try LocalAddress.baseURL("172.32.1.1"))
        expectNoThrow(try LocalAddress.baseURL("172.16.1.8"))
    }
    func testCaseInsensitiveSSDPHeaderAndCRLF() {
        let url = SSDP.location(from: "HTTP/1.1 200 OK\r\nserver: Sonos\r\nLoCaTiOn: http://192.168.1.7:1400/xml/device_description.xml\r\n\r\n")
        expectEqual(url?.host, "192.168.1.7")
    }
    func testGroupAliasSurvivesCoordinatorAndMembershipOrderingChanges() throws {
        let one = Room(id: "ONE-UUID", name: "Study", baseURL: try LocalAddress.baseURL("192.168.1.10"), isStereoPair: true, model: "Sonos Era 100 (Gen 2)")
        let five = Room(id: "FIVE-UUID", name: "Study 2", baseURL: try LocalAddress.baseURL("192.168.1.11"), model: "Sonos Five")
        let before = SpeakerGroup(id: "group-before", coordinatorURL: one.baseURL, rooms: [one, five])
        let after = SpeakerGroup(id: "group-after", coordinatorURL: five.baseURL, rooms: [five, one])
        expectEqual(GroupPresentation.identity(before), GroupPresentation.identity(after))
        expectEqual(GroupPresentation.name(after), "Study")
        expectEqual(GroupPresentation.speakerLabel(one), "Sonos Era 100 · stereo pair")
        let kitchen = Room(id: "KITCHEN-UUID", name: "Kitchen", baseURL: try LocalAddress.baseURL("192.168.1.12"), model: "Sonos Five")
        let different = SpeakerGroup(id: "group-after", coordinatorURL: five.baseURL, rooms: [five, kitchen])
        expectTrue(GroupPresentation.identity(different) != GroupPresentation.identity(before))
        expectEqual(GroupPresentation.name(different), "Study 2 + Kitchen")
        expectEqual(GroupPresentation.speakerLabel(kitchen, in: different), "Sonos Five · Kitchen")
    }
    func testMalformedXMLCannotProducePartialTopology() {
        expectThrows(try SonosXML.parse(Data("<a><b>broken</a>".utf8)))
    }
}

// Standalone contract checks also run with Command Line Tools, without Xcode/XCTest.
func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    guard lhs == rhs else { fatalError("Expected \(rhs), got \(lhs)", file: file, line: line) }
}
func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    guard value else { fatalError("Expected true", file: file, line: line) }
}
func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    guard value == nil else { fatalError("Expected nil", file: file, line: line) }
}
func expectThrows<T>(_ value: @autoclosure () throws -> T, verify: (Error) -> Void = { _ in }, file: StaticString = #file, line: UInt = #line) {
    do { _ = try value(); fatalError("Expected an error", file: file, line: line) }
    catch { verify(error) }
}
func expectNoThrow<T>(_ value: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try value() } catch { fatalError("Unexpected error: \(error)", file: file, line: line) }
}
@main
struct RunChecks {
    static func main() throws {
        let checks = ProtocolTests()
        try checks.testStereoPairAndSatellitesAreOneLogicalRoom()
        try checks.testSeparateGroupedOnesRemainSeparate()
        checks.testMissingCoordinatorIsRejectedInsteadOfControllingAnotherRoom()
        try checks.testEscapedTopologyInSOAPEnvelope()
        checks.testUPnPFaultIsNotTreatedAsSuccess()
        try checks.testSOAPUsesCorrectGroupEndpointAndAction()
        try checks.testUntrustedDiscoveryCannotReachPublicHosts()
        checks.testCaseInsensitiveSSDPHeaderAndCRLF()
        checks.testMalformedXMLCannotProducePartialTopology()
        try checks.testGroupAliasSurvivesCoordinatorAndMembershipOrderingChanges()
        print("10 protocol and presentation checks passed. These are fixture tests, not live speaker tests.")
    }
}
