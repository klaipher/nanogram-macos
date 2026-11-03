import XCTest
import AppKit
import CoreText
@testable import OCR
import TGPassportMRZ

final class MRZRecognitionTests: XCTestCase {
    private let td3 = [
        "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<",
        "L898902C36UTO7408122F1204159ZE184226B<<<<<10",
    ]
    private let td1 = [
        "I<UTOD231458907<<<<<<<<<<<<<<<",
        "7408122F1204159UTO<<<<<<<<<<<6",
        "ERIKSSON<<ANNA<MARIA<<<<<<<<<<",
    ]

    private func specimen(mrz: [String], fontSize: CGFloat) -> CGImage {
        let width = 1400, height = 900
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func draw(_ text: String, font: NSFont, y: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
            context.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(line, context)
        }
        draw("PASSPORT  UTOPIA", font: .boldSystemFont(ofSize: 40), y: 800)
        draw("Surname / Nom  ERIKSSON", font: .systemFont(ofSize: 28), y: 700)
        draw("Given names / Prénoms  ANNA MARIA", font: .systemFont(ofSize: 28), y: 640)
        draw("Date of birth 12 AUG 1974   Sex F", font: .systemFont(ofSize: 28), y: 580)
        let mono = NSFont(name: "Courier", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        for (index, line) in mrz.enumerated() {
            draw(line, font: mono, y: CGFloat(60 + (mrz.count - 1 - index) * Int(fontSize * 1.6)))
        }
        return context.makeImage()!
    }

    func testTD3PassportLinesAreRecognizedAndParse() {
        let image = specimen(mrz: td3, fontSize: 36)
        let text = recognizeMRZ(image)
        XCTAssertEqual(text?.components(separatedBy: "\n"), td3)
        let mrz = TGPassportMRZ.parseLines(text?.components(separatedBy: "\n"))
        XCTAssertEqual(mrz?.lastName, "ERIKSSON")
        XCTAssertEqual(mrz?.firstName, "ANNA MARIA")
        XCTAssertEqual(mrz?.documentNumber, "L898902C3")
        XCTAssertEqual(mrz?.issuingCountry, "UTO")
        XCTAssertNotNil(mrz?.birthDate)
        XCTAssertNotNil(mrz?.expiryDate)
    }

    func testTD1IdentityCardLinesAreRecognizedAndParse() {
        let image = specimen(mrz: td1, fontSize: 48)
        let text = recognizeMRZ(image)
        XCTAssertEqual(text?.components(separatedBy: "\n"), td1)
        let mrz = TGPassportMRZ.parseLines(text?.components(separatedBy: "\n"))
        XCTAssertEqual(mrz?.lastName, "ERIKSSON")
        XCTAssertEqual(mrz?.documentNumber, "D23145890")
    }

    func testImageWithoutMRZGivesNil() {
        let image = specimen(mrz: [], fontSize: 36)
        XCTAssertNil(recognizeMRZ(image))
    }

    func testNormalizationRepairsTypicalVisionMisreads() {
        XCTAssertEqual(normalizedMRZCandidate("p<utoeriksson«anna<maria " + String(repeating: "<", count: 18)), td3[0])
        XCTAssertEqual(normalizedMRZCandidate(td1[1] + "<"), td1[1])
        XCTAssertNil(normalizedMRZCandidate("Surname / Nom ERIKSSON"))
        XCTAssertNil(normalizedMRZCandidate("L898902C36UTO7408122F1204159ZE184226B<<<<<10ABC"))
    }

    func testFieldAwareCorrectionFixesLetterDigitConfusions() {
        XCTAssertEqual(mrzLines(fromBottomToTop: ["L898902C36UT074O8122F12O4159ZE184226B<<<<<1O", "P<UT0ERIKSS0N<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<"]), td3)
        XCTAssertEqual(mrzLines(fromBottomToTop: ["ERIKSS0N<<ANNA<MARIA<<<<<<<<<<", "74O8122F12O4159UT0<<<<<<<<<<<6", "I<UT0D231458907<<<<<<<<<<<<<<<"]), td1)
    }

    func testAsyncRecognitionCompletesOnMain() {
        let done = expectation(description: "completion")
        recognizeMRZ(specimen(mrz: td3, fontSize: 36)) { text in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(text)
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
    }
}
