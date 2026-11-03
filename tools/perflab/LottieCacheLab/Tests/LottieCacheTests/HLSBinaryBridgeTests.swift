import XCTest
import JavaScriptCore
@testable import TelegramMedia

final class HLSBinaryBridgeTests: XCTestCase {
    private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../Resources/hls").standardized

    func testStoreHandsEachItemOutOnce() {
        let store = HLSJSBinaryStore()
        let first = store.put(Data([1, 2, 3]))
        let second = store.put(Data([4]))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, 0)
        XCTAssertEqual(store.take(first), Data([1, 2, 3]))
        XCTAssertNil(store.take(first))
        XCTAssertEqual(store.take(second), Data([4]))
    }

    private func makeContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JS exception: \(String(describing: exception))")
        }
        let polyfills = try XCTUnwrap(JSValue(newObjectIn: context))
        let put: @convention(block) (JSValue) -> Int32 = { value in
            return HLSJSBinaryStore.putBinary(value)
        }
        let take: @convention(block) (Int32) -> JSValue = { id in
            return HLSJSBinaryStore.takeBinary(id, in: JSContext.current())
        }
        let log: @convention(block) (JSValue) -> Void = { _ in }
        let post: @convention(block) (JSValue) -> Void = { _ in }
        let now: @convention(block) () -> Double = { CFAbsoluteTimeGetCurrent() * 1000 }
        polyfills.setObject(put, forKeyedSubscript: "putBinary" as NSString)
        polyfills.setObject(take, forKeyedSubscript: "takeBinary" as NSString)
        polyfills.setObject(log, forKeyedSubscript: "consoleLog" as NSString)
        polyfills.setObject(post, forKeyedSubscript: "postMessage" as NSString)
        polyfills.setObject(now, forKeyedSubscript: "performanceNow" as NSString)
        context.setObject(polyfills, forKeyedSubscript: "_JsCorePolyfills" as NSString)
        context.evaluateScript("function setTimeout() { return 0; } function setInterval() { return 0; } function clearTimeout() {} function clearInterval() {}")
        let prologue = try String(contentsOf: resources.appendingPathComponent("headless_prologue.js"), encoding: .utf8)
        context.evaluateScript(prologue)
        let bundle = try String(contentsOf: resources.appendingPathComponent("index/index.bundle.js"), encoding: .utf8)
        context.evaluateScript(bundle)
        context.evaluateScript("""
        var bridgeCalls = [];
        var nextResponse = {};
        window.bridgeInvokeAsync = function(bridgeId, className, methodName, params) {
            bridgeCalls.push({ className: className, methodName: methodName, params: params });
            if (methodName === "load") {
                return Promise.resolve(nextResponse);
            }
            if (methodName === "appendBuffer") {
                return Promise.resolve({ ranges: [] });
            }
            return Promise.resolve({});
        };
        """)
        return context
    }

    func testSegmentsReachTheXMLHttpRequestStubAsArrayBuffers() throws {
        let context = try makeContext()
        let id = HLSJSBinaryStore.shared.put(Data([9, 8, 7, 6, 5]))
        context.evaluateScript("""
        nextResponse = { status: 200, statusText: "OK", responseDataId: \(id), responseHeaders: {} };
        var xhr = new window.XMLHttpRequest();
        xhr.open("GET", "http://localhost/segment.mp4");
        xhr.responseType = "arraybuffer";
        xhr.send();
        """)
        let load = context.evaluateScript("JSON.stringify(bridgeCalls.filter(function(c) { return c.methodName === 'load'; }).map(function(c) { return c.params.responseType; }))")?.toString()
        XCTAssertEqual(load, "[\"arraybuffer\"]")
        let bytes = context.evaluateScript("xhr.response instanceof ArrayBuffer ? Array.from(new Uint8Array(xhr.response)).join(',') : String(xhr.response)")?.toString()
        XCTAssertEqual(bytes, "9,8,7,6,5")
        XCTAssertNil(HLSJSBinaryStore.shared.take(id))
    }

    func testBase64ResponsesStillWork() throws {
        let context = try makeContext()
        context.evaluateScript("""
        nextResponse = { status: 200, statusText: "OK", responseData: "\(Data([1, 2, 250]).base64EncodedString())", responseHeaders: {} };
        var xhr = new window.XMLHttpRequest();
        xhr.open("GET", "http://localhost/segment.mp4");
        xhr.responseType = "arraybuffer";
        xhr.send();
        """)
        XCTAssertEqual(context.evaluateScript("Array.from(new Uint8Array(xhr.response)).join(',')")?.toString(), "1,2,250")
    }

    func testAppendBufferSendsAnIdInsteadOfBase64() throws {
        let context = try makeContext()
        context.evaluateScript("""
        var source = new window.MediaSource();
        source.readyState = "open";
        var buffer = source.addSourceBuffer('video/mp4; codecs="avc1.64001f"');
        var bytes = new Uint8Array([0, 1, 2, 3, 4, 5, 6]);
        buffer.appendBuffer(bytes.subarray(2, 6));
        var append = bridgeCalls.filter(function(c) { return c.methodName === 'appendBuffer'; })[0];
        """)
        XCTAssertTrue(context.evaluateScript("append.params.data === undefined")?.toBool() ?? false)
        let dataId = try XCTUnwrap(context.evaluateScript("append.params.dataId")?.toInt32())
        XCTAssertEqual(HLSJSBinaryStore.shared.take(dataId), Data([2, 3, 4, 5]))
    }
}
