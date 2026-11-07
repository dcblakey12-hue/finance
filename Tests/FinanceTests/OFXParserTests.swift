import XCTest
@testable import Finance

final class OFXParserTests: XCTestCase {
    func testParseSGML() throws {
        let data = try Data(contentsOf: Bundle.module.url(forResource: "sample", withExtension: "ofx")!)
        let parsed = try OFXParser.shared.parse(data: data)
        XCTAssertEqual(parsed.accountId, "123456789")
        XCTAssertEqual(parsed.transactions.count, 3)
        XCTAssertEqual(parsed.transactions.first?.name, "Whole Foods Market")
        XCTAssertEqual(parsed.transactions.first?.amount ?? 0, -54.20, accuracy: 0.001)
        XCTAssertEqual(parsed.balance ?? 0, 2450.75, accuracy: 0.001)
    }
    func testParseXML() throws {
        let xml = """
        <OFX><STMTRS><BANKACCTFROM><BANKID>123</BANKID><ACCTID>999</ACCTID></BANKACCTFROM>
        <BANKTRANLIST><STMTTRN><TRNTYPE>CREDIT</TRNTYPE><DTPOSTED>20240201120000</DTPOSTED><TRNAMT>1500.00</TRNAMT><FITID>tx1</FITID><NAME>Payroll</NAME></STMTTRN></BANKTRANLIST>
        <LEDGERBAL><BALAMT>100.00</BALAMT></LEDGERBAL></STMTRS></OFX>
        """
        let parsed = try OFXParser.shared.parse(string: xml)
        XCTAssertEqual(parsed.transactions.count, 1)
        XCTAssertEqual(parsed.transactions[0].amount, 1500, accuracy: 0.001)
        XCTAssertEqual(parsed.transactions[0].type, .credit)
    }
    func testDateParsing() {
        let d = OFXParser.parseOFXDate("20240115120000")
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.year, from: d), 2024)
        XCTAssertEqual(cal.component(.month, from: d), 1)
        XCTAssertEqual(cal.component(.day, from: d), 15)
    }

    func testInstitutionOrgAndFidSGML() throws {
        let sgml = """
        OFXHEADER:100
        DATA:OFXSGML

        <OFX><SIGNONMSGSRSV1><SONRS><STATUS><CODE>0<SEVERITY>INFO</STATUS>
        <DTSERVER>20240131120000<LANGUAGE>ENG
        <FI><ORG>Example Credit Union<FID>1234</FI></SONRS></SIGNONMSGSRSV1>
        <BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKACCTFROM><BANKID>999<ACCTID>555</BANKACCTFROM>
        <BANKTRANLIST><STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20240115<TRNAMT>-10.00<FITID>a1<NAME>Coffee</STMTTRN></BANKTRANLIST>
        </STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
        """
        let parsed = try OFXParser.shared.parse(string: sgml)
        XCTAssertEqual(parsed.institutionOrg, "Example Credit Union")
        XCTAssertEqual(parsed.institutionFid, "1234")
        XCTAssertEqual(parsed.transactions.count, 1)
    }

    func testNoInstitutionBlockGivesNil() throws {
        let data = try Data(contentsOf: Bundle.module.url(forResource: "sample", withExtension: "ofx")!)
        let parsed = try OFXParser.shared.parse(data: data)
        XCTAssertNil(parsed.institutionOrg)
        XCTAssertNil(parsed.institutionFid)
    }
}
