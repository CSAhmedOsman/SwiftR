//
//  SwiftR.swift
//  SwiftR
//
//  Created by Adam Hartford on 4/13/15.
//  Last modified by Ahmed Osman on 8/3/25.
//  Forked from: https://github.com/adamhartford/SwiftR
//
//  Description: Swift client for SignalR (iOS and Mac).
//
//  Change Log:
//    - Updated enums to Swift style
//    - Improved documentation and error handling
//    - Modernized header and added documentation comments
//

import Foundation
import WebKit

/// Represents the type of SignalR connection.
@objc public enum ConnectionType: Int {
    case hub
    case persistent
}

/// Represents the state of the SignalR connection.
@objc public enum State: Int {
    case connecting
    case connected
    case disconnected
}

/// Represents available transport mechanisms for SignalR.
public enum Transport {
    case auto
    case webSockets
    case foreverFrame
    case serverSentEvents
    case longPolling
    
    /// Returns the string value corresponding to the transport type.
    var stringValue: String {
        switch self {
            case .webSockets:
                return "webSockets"
            case .foreverFrame:
                return "foreverFrame"
            case .serverSentEvents:
                return "serverSentEvents"
            case .longPolling:
                return "longPolling"
            default:
                return "auto"
        }
    }
}

/// Represents errors that may occur in SwiftR.
public enum SwiftRError: Error {
    case notConnected
    
    /// Provides a user-friendly error message.
    public var message: String {
        switch self {
            case .notConnected:
                return "Operation requires connection, but none available."
        }
    }
}

/// Main namespace for SwiftR utilities and global methods.
class SwiftR {
    /// List of all current SignalR connections.
    static var connections = [SignalR]()
    
#if os(iOS)
    /// Cleans up temporary JavaScript files used by SwiftR.
    public class func cleanup() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SwiftR", isDirectory: true)
        let fileManager = FileManager.default
        
        do {
            if fileManager.fileExists(atPath: temp.path) {
                try fileManager.removeItem(at: temp)
            }
        } catch {
            print("Failed to remove temp JavaScript: \(error)")
        }
    }
#endif
}

/// Represents a SignalR connection, managing communication and hubs.
open class SignalR: NSObject, SwiftRWebDelegate {
    static var connections = [SignalR]()
    
    /// Internal unique identifier for the connection instance.
    var internalID: String
    /// Indicates if the connection is ready for communication.
    var ready = false
    
    /// The version of SignalR to use.
    public var signalRVersion: SignalRVersion = .v2_4_1
    /// The transport mechanism to use.
    public var transport: Transport = .auto
    /// The origin URL to use for loading web resources (used as Origin HTTP header).
    public var originUrlString: String?
    
    /// The WKWebView instance used for JavaScript bridging.
    var webView: WKWebView?
    
    /// The base URL of the SignalR server.
    var baseUrl: String
    /// The connection type (hub or persistent).
    var connectionType: ConnectionType
    
    /// Called when the web view is ready.
    var readyHandler: ((SignalR) -> ())?
    /// Collection of created hubs by name.
    var hubs = [String: Hub]()
    
    /// The current connection state.
    open var state: State = .disconnected
    /// The connection ID assigned by the server.
    open var connectionID: String?
    /// Handler for messages received from the server.
    open var received: ((Any?) -> ())?
    /// Handler called when the connection is starting.
    open var starting: (() -> ())?
    /// Handler called when the connection is established.
    open var connected: (() -> ())?
    /// Handler called when the connection is disconnected.
    open var disconnected: (() -> ())?
    /// Handler called when the connection is slow.
    open var connectionSlow: (() -> ())?
    /// Handler called when the connection fails.
    open var connectionFailed: (() -> ())?
    /// Handler called when the connection is reconnecting.
    open var reconnecting: (() -> ())?
    /// Handler called when the connection is reconnected.
    open var reconnected: (() -> ())?
    /// Handler for errors received from the server.
    open var error: (([String: Any]?) -> ())?
    
    /// Queue of JavaScript commands to be executed before the bridge is ready.
    var jsQueue: [(String, ((Any?) -> ())?)] = []
    
    /// Custom user agent string for the web view.
    open var customUserAgent: String?
    
    /// Optional query string parameters for the SignalR connection.
    open var queryString: Any? {
        didSet {
            if let qs: Any = queryString {
                if let jsonData = try? JSONSerialization.data(withJSONObject: qs, options: JSONSerialization.WritingOptions()) {
                    let json = NSString(data: jsonData, encoding: String.Encoding.utf8.rawValue) as String?
                    runJavaScript("swiftR.connection.qs = \(json ?? "{}")")
                }
            } else {
                runJavaScript("swiftR.connection.qs = {}")
            }
        }
    }
    
    /// Optional HTTP headers for the SignalR connection.
    open var headers: [String: String]? {
        didSet {
            if let h = headers {
                if let jsonData = try? JSONSerialization.data(withJSONObject: h, options: JSONSerialization.WritingOptions()) {
                    let json = NSString(data: jsonData, encoding: String.Encoding.utf8.rawValue) as String?
                    runJavaScript("swiftR.headers = \(json ?? "{}")")
                }
            } else {
                runJavaScript("swiftR.headers = {}")
            }
        }
    }
    
    /// Initializes a new SignalR connection.
    /// - Parameters:
    ///   - baseUrl: The base URL of the SignalR server.
    ///   - connectionType: Type of connection, either hub or persistent (default is `.hub`).
    public init(_ baseUrl: String, connectionType: ConnectionType = .hub) {
        internalID = NSUUID().uuidString
        self.baseUrl = baseUrl
        self.connectionType = connectionType
        super.init()
    }
    
    /// Establishes the connection and prepares the JavaScript bridge.
    /// - Parameter callback: Optional completion handler after the web view is ready.
    public func connect(_ callback: (() -> ())? = nil) {
        readyHandler = { [weak self] _ in
            self?.jsQueue.forEach { self?.runJavaScript($0.0, callback: $0.1) }
            self?.jsQueue.removeAll()
            
            if let hubs = self?.hubs {
                hubs.forEach { $0.value.initialize() }
            }
            
            self?.ready = true
            callback?()
        }
        
        initialize()
    }
    
    /// Prepares and loads the web view with required JavaScript resources.
    private func initialize() {
        let bundle = Bundle.sm_frameworkBundle()
        
        guard
            let jqueryURL = bundle.url(forResource: "jquery-2.1.3.min", withExtension: "js"),
            let signalRURL = bundle.url(forResource: "jquery.signalr-\(signalRVersion).min", withExtension: "js"),
            let jsURL = bundle.url(forResource: "SwiftR", withExtension: "js")
        else { return }
        
        // Helpers for including scripts as <script src=""> or <script>content</script>
        let scriptAsSrc: (URL) -> String = { url in return "<script src='\(url.absoluteString)'></script>" }
        let scriptAsContent: (URL) -> String = { url in
            let scriptContent = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return "<script>\(scriptContent)</script>"
        }
        let script: (URL) -> String = { url in return self.originUrlString != nil ? scriptAsContent(url) : scriptAsSrc(url) }
        
        var jqueryInclude = script(jqueryURL)
        var signalRInclude = script(signalRURL)
        var jsInclude = script(jsURL)
        
        /// Use originUrlString if provided, otherwise fallback to bundle URL
        let baseHTMLUrl = originUrlString.map { URL(string: $0) } ?? bundle.bundleURL
        
        // Loading file:// URLs from NSTemporaryDirectory() works on iOS, not on macOS.
#if os(iOS)
        if #available(iOS 9.0, *), originUrlString == nil {
            let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SwiftR", isDirectory: true)
            let jqueryTempURL = temp.appendingPathComponent("jquery-2.1.3.min.js")
            let signalRTempURL = temp.appendingPathComponent("jquery.signalr-\(signalRVersion).min")
            let jsTempURL = temp.appendingPathComponent("SwiftR.js")
            
            let fileManager = FileManager.default
            
            do {
                if SwiftR.connections.isEmpty {
                    SwiftR.cleanup()
                    try fileManager.createDirectory(at: temp, withIntermediateDirectories: false)
                }
                
                if !fileManager.fileExists(atPath: jqueryTempURL.path) {
                    try fileManager.copyItem(at: jqueryURL, to: jqueryTempURL)
                }
                if !fileManager.fileExists(atPath: signalRTempURL.path) {
                    try fileManager.copyItem(at: signalRURL, to: signalRTempURL)
                }
                if !fileManager.fileExists(atPath: jsTempURL.path) {
                    try fileManager.copyItem(at: jsURL, to: jsTempURL)
                }
            } catch {
                print("Failed to copy JavaScript to temp dir: \(error)")
            }
            
            jqueryInclude = scriptAsSrc(jqueryTempURL)
            signalRInclude = scriptAsSrc(signalRTempURL)
            jsInclude = scriptAsSrc(jsTempURL)
        }
#else
        if originUrlString == nil {
            // On macOS, always embed script content
            jqueryInclude = scriptAsContent(jqueryURL)
            signalRInclude = scriptAsContent(signalRURL)
            jsInclude = scriptAsContent(jsURL)
        }
#endif
        
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "interOp")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        // For debugging in development, you can enable developer extras for macOS.
        // #if !os(iOS)
        //     config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // #endif
        
        webView = WKWebView(frame: CGRect.zero, configuration: config)
        webView?.navigationDelegate = self
        
        let html = "<!doctype html><html><head></head><body>"
        + "\(jqueryInclude)\(signalRInclude)\(jsInclude)"
        + "</body></html>"
        
        webView?.loadHTMLString(html, baseURL: baseHTMLUrl)
        
        if let ua = customUserAgent {
            applyUserAgent(ua)
        }
        
        SwiftR.connections.append(self)
    }
    
    /// Cleans up the web view and removes handlers upon deallocation.
    deinit {
        if let webView {
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "interOp")
            webView.removeFromSuperview()
        }
    }
    
    /// Creates a new hub proxy for the specified hub name.
    /// - Parameter name: Name of the hub.
    /// - Returns: The created Hub instance.
    open func createHubProxy(_ name: String) -> Hub {
        let hub = Hub(name: name, connection: self)
        hubs[name.lowercased()] = hub
        return hub
    }
    
    /// Adds an existing hub instance to the connection.
    /// - Parameter hub: The Hub instance to add.
    open func addHub(_ hub: Hub) {
        hub.connection = self
        hubs[hub.name.lowercased()] = hub
    }
    
    /// Sends data to the server via SignalR.
    /// - Parameter data: The data to send.
    open func send(_ data: Any?) {
        var json = "null"
        if let d = data {
            if let val = SignalR.stringify(d) {
                json = val
            }
        }
        runJavaScript("swiftR.connection.send(\(json))")
    }
    
    /// Starts the SignalR connection. If not ready, this will call `connect()` first.
    open func start() {
        if ready {
            runJavaScript("start()")
        } else {
            connect()
        }
    }
    
    /// Stops the SignalR connection gracefully.
    open func stop() {
        runJavaScript("swiftR.connection.stop()")
    }
    
    /// Processes a message received from the JavaScript bridge.
    /// - Parameter json: The JSON dictionary containing the message.
    func processMessage(_ json: [String: Any]) {
        if let message = json["message"] as? String {
            switch message {
                case "ready":
                    let isHub = connectionType == .hub ? "true" : "false"
                    runJavaScript("swiftR.transport = '\(transport.stringValue)'")
                    runJavaScript("initialize('\(baseUrl)', \(isHub))")
                    readyHandler?(self)
                    runJavaScript("start()")
                case "starting":
                    state = .connecting
                    starting?()
                case "connected":
                    state = .connected
                    connectionID = json["connectionId"] as? String
                    connected?()
                case "disconnected":
                    state = .disconnected
                    disconnected?()
                case "connectionSlow":
                    connectionSlow?()
                case "connectionFailed":
                    connectionFailed?()
                case "reconnecting":
                    state = .connecting
                    reconnecting?()
                case "reconnected":
                    state = .connected
                    reconnected?()
                case "invokeHandler":
                    if let hubName = json["hub"] as? String,
                       let hub = hubs[hubName] {
                        let result = json["result"]
                        let error = json["error"] as AnyObject?
                        if let uuid = json["id"] as? String,
                           let callback = hub.invokeHandlers[uuid] {
                            callback(result as AnyObject?, error)
                            hub.invokeHandlers.removeValue(forKey: uuid)
                        } else if let e = error {
                            print("SwiftR invoke error: \(e)")
                        }
                    }
                case "error":
                    if let err = json["error"] as? [String: Any] {
                        error?(err)
                    } else {
                        error?(nil)
                    }
                default:
                    break
            }
        } else if let data: Any = json["data"] {
            received?(data)
        } else if let hubName = json["hub"] as? String {
            let callbackID = json["id"] as? String
            let method = json["method"] as? String
            let arguments = json["arguments"] as? [AnyObject]
            let hub = hubs[hubName]
            
            if let method = method, let callbackID = callbackID, let handlers = hub?.handlers[method], let handler = handlers[callbackID] {
                handler(arguments)
            }
        }
    }
    
    /// Evaluates a JavaScript script in the web view.
    /// - Parameters:
    ///   - script: The JavaScript code to run.
    ///   - callback: Optional callback when script execution is complete.
    func runJavaScript(_ script: String, callback: ((Any?) -> ())? = nil) {
        guard let webView else {
            jsQueue.append((script, callback))
            return
        }
        
        webView.evaluateJavaScript(script, completionHandler: { (result, _)  in
            callback?(result)
        })
    }
    
    /// Applies a custom user agent to the web view.
    /// - Parameter userAgent: The user agent string.
    func applyUserAgent(_ userAgent: String) {
#if os(iOS)
        if #available(iOS 9.0, *) {
            webView?.customUserAgent = userAgent
        } else {
            print("Unable to set user agent for WKWebView on iOS <= 8. Please register defaults via NSUserDefaults instead.")
        }
#else
        if #available(OSX 10.11, *) {
            webView?.customUserAgent = userAgent
        } else {
            print("Unable to set user agent for WKWebView on OS X <= 10.10.")
        }
#endif
    }
    
    // MARK: - WKNavigationDelegate
    
    // http://stackoverflow.com/questions/26514090/wkwebview-does-not-run-javascriptxml-http-request-with-out-adding-a-parent-vie#answer-26575892
    
    /// Called when web view navigation finishes.
    open func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if os(iOS)
        UIApplication.shared.keyWindow?.addSubview(webView)
#endif
    }
    
    open func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
    
    // MARK: - WKScriptMessageHandler
    
    /// Called when the web view receives a message from JavaScript.
    open func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let id = message.body as? String {
            webView?.evaluateJavaScript("readMessage('\(id)')", completionHandler: { [weak self] (msg, err) in
                if let m = msg as? [String: Any] {
                    self?.processMessage(m)
                } else if let e = err {
                    print("SwiftR unable to process message \(id): \(e)")
                } else {
                    print("SwiftR unable to process message \(id)")
                }
            })
        }
    }
    
    // MARK: - Class methods
    
    /// Converts a Swift object to a JSON string for JavaScript interop.
    /// - Parameter obj: The object to convert.
    /// - Returns: The JSON string if conversion is successful.
    class func stringify(_ obj: Any) -> String? {
        // Using an array to start with a valid top level type for NSJSONSerialization
        let arr = [obj]
        if let data = try? JSONSerialization.data(withJSONObject: arr, options: JSONSerialization.WritingOptions()) {
            if let str = NSString(data: data, encoding: String.Encoding.utf8.rawValue) as String? {
                // Strip the array brackets to be left with the desired value
                let range = str.index(str.startIndex, offsetBy: 1) ..< str.index(str.endIndex, offsetBy: -1)
                return String(str[range])
            }
        }
        return nil
    }
}

/// Represents a SignalR hub, allowing registration of methods and invocation.
open class Hub: NSObject {
    /// The hub's name.
    let name: String
    /// Maps method names to handler dictionaries by callback ID.
    var handlers: [String: [String: ([Any]?) -> ()]] = [:]
    /// Maps invocation UUIDs to their completion handlers.
    var invokeHandlers: [String: (_ result: Any?, _ error: AnyObject?) -> ()] = [:]
    /// The SignalR connection this hub belongs to.
    var connection: SignalR?
    
    /// Initializes a new Hub instance with a name.
    /// - Parameter name: The hub name.
    public init(_ name: String) {
        self.name = name
        self.connection = nil
    }
    
    /// Initializes a new Hub instance with a name and connection.
    /// - Parameters:
    ///   - name: The hub name.
    ///   - connection: The SignalR connection.
    init(name: String, connection: SignalR) {
        self.name = name
        self.connection = connection
    }
    
    /// Registers a handler for a method received from the server.
    /// - Parameters:
    ///   - method: The method name.
    ///   - callback: The handler to invoke when data is received.
    open func on(_ method: String, callback: @escaping ([Any]?) -> ()) {
        let callbackID = UUID().uuidString
        
        if handlers[method] == nil {
            handlers[method] = [:]
        }
        
        handlers[method]?[callbackID] = callback
    }
    
    /// Initializes all registered handlers in JavaScript.
    func initialize() {
        for (method, callbacks) in handlers {
            callbacks.forEach { connection?.runJavaScript("addHandler('\($0.key)', '\(name)', '\(method)')") }
        }
    }
    
    /// Invokes a method on the server hub.
    /// - Parameters:
    ///   - method: The method name.
    ///   - arguments: Optional arguments for the method.
    ///   - callback: Optional callback for the result or error.
    /// - Throws: `SwiftRError.notConnected` if the connection is missing.
    open func invoke(_ method: String, arguments: [Any]? = nil, callback: ((_ result: Any?, _ error: Any?) -> ())? = nil) throws {
        guard let connection else {
            throw SwiftRError.notConnected
        }
        
        var jsonArguments = [String]()
        
        if let args = arguments {
            for arg in args {
                if let val = SignalR.stringify(arg) {
                    jsonArguments.append(val)
                } else {
                    jsonArguments.append("null")
                }
            }
        }
        
        let args = jsonArguments.joined(separator: ", ")
        
        let uuid = UUID().uuidString
        if let handler = callback {
            invokeHandlers[uuid] = handler
        }
        
        let doneJS = "function() { postMessage({ message: 'invokeHandler', hub: '\(name.lowercased())', id: '\(uuid)', result: arguments[0] }); }"
        let failJS = "function() { postMessage({ message: 'invokeHandler', hub: '\(name.lowercased())', id: '\(uuid)', error: processError(arguments[0]) }); }"
        let js = args.isEmpty
        ? "ensureHub('\(name)').invoke('\(method)').done(\(doneJS)).fail(\(failJS))"
        : "ensureHub('\(name)').invoke('\(method)', \(args)).done(\(doneJS)).fail(\(failJS))"
        
        connection.runJavaScript(js)
    }
    
}

/// Supported SignalR JavaScript library versions.
public enum SignalRVersion : CustomStringConvertible {
    case v2_4_1
    case v2_4_0
    case v2_2_2
    case v2_2_1
    case v2_2_0
    case v2_1_2
    case v2_1_1
    case v2_1_0
    case v2_0_3
    case v2_0_2
    case v2_0_1
    case v2_0_0
    
    /// The version number as a string.
    public var description: String {
        switch self {
            case .v2_4_1: return "2.4.1"
            case .v2_4_0: return "2.4.0"
            case .v2_2_2: return "2.2.2"
            case .v2_2_1: return "2.2.1"
            case .v2_2_0: return "2.2.0"
            case .v2_1_2: return "2.1.2"
            case .v2_1_1: return "2.1.1"
            case .v2_1_0: return "2.1.0"
            case .v2_0_3: return "2.0.3"
            case .v2_0_2: return "2.0.2"
            case .v2_0_1: return "2.0.1"
            case .v2_0_0: return "2.0.0"
        }
    }
}

/// Protocol for classes that act as both navigation and script message delegates for WKWebView.
public protocol SwiftRWebDelegate: WKNavigationDelegate, WKScriptMessageHandler {}

/// Empty class for use in bundle resource lookups.
private class BundleToken {}

extension Bundle {
    /// Finds the correct Bundle for resources, supporting SPM, CocoaPods, and Carthage.
    static func sm_frameworkBundle() -> Bundle {
        
        let candidates = [
            // Bundle should be present here when the package is linked into an App.
            Bundle.main.resourceURL,
            
            // Bundle should be present here when the package is linked into a framework.
            Bundle(for: BundleToken.self).resourceURL,
            
            // For command-line tools.
            Bundle.main.bundleURL,
        ]
        
        let bundleNames = [
            "SwiftR",
            // For Swift Manager
            "com.adamhartford.SwiftR",
            // For Carthage
            "org.cocoapods.SwiftR",
        ]
        
        for bundleName in bundleNames {
            for candidate in candidates {
                let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle")
                if let bundle = bundlePath.flatMap(Bundle.init(url:)) {
                    return bundle
                }
            }
        }
        
        // Return whatever bundle this code is in as a last resort.
        return Bundle(for: BundleToken.self)
    }
}
