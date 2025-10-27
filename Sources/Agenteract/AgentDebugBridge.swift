//
//  AgentDebugBridge.swift
//  AgenteractSwiftExample
//
//  Created by Agenteract
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import Combine

// MARK: - Agent Node Registry

struct AgentNode {
    weak var view: AnyObject?
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    var onChangeText: ((String) -> Void)?
    var onSwipe: ((String, String) -> Void)? // direction, velocity
    var scrollViewProxy: Any? // Will hold ScrollViewProxy for programmatic scrolling
    var scrollPosition: CGPoint = .zero // Track scroll position for relative scrolling
}

class AgentRegistry {
    static let shared = AgentRegistry()
    private var nodes: [String: AgentNode] = [:]
    private let lock = NSLock()

    func register(testID: String, node: AgentNode) {
        lock.lock()
        defer { lock.unlock() }
        nodes[testID] = node
    }

    func unregister(testID: String) {
        lock.lock()
        defer { lock.unlock() }
        nodes.removeValue(forKey: testID)
    }

    func getNode(testID: String) -> AgentNode? {
        lock.lock()
        defer { lock.unlock() }
        return nodes[testID]
    }

    func getAllTestIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(nodes.keys)
    }
}

// MARK: - Log Buffer

struct LogEntry: Codable {
    let level: String
    let message: String
    let timestamp: Double
}

class LogBuffer {
    static let shared = LogBuffer()
    private var logs: [LogEntry] = []
    private let maxLogLines = 2000
    private let lock = NSLock()

    // Callback for when new log is added
    var onNewLog: ((LogEntry) -> Void)?

    func addLog(level: String, message: String) {
        lock.lock()
        let entry = LogEntry(
            level: level,
            message: message,
            timestamp: Date().timeIntervalSince1970
        )

        logs.append(entry)

        if logs.count > maxLogLines {
            logs.removeFirst()
        }
        lock.unlock()

        // Notify listener of new log (outside lock to avoid deadlock)
        onNewLog?(entry)
    }

    func getLogs() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return logs
    }
}

// MARK: - Device Info

struct DeviceInfo: Codable {
    let isSimulator: Bool
    let deviceId: String?
    let bundleId: String
    let deviceName: String
    let osVersion: String
    let deviceModel: String
}

class DeviceInfoProvider {
    static func getDeviceInfo() -> DeviceInfo {
        #if targetEnvironment(simulator)
        let isSimulator = true
        // For simulator, get UDID from environment
        let deviceId = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
        #else
        let isSimulator = false
        // For physical device, we can't easily get UDID without private APIs
        let deviceId: String? = nil
        #endif

        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let deviceName = UIDevice.current.name
        let osVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model

        return DeviceInfo(
            isSimulator: isSimulator,
            deviceId: deviceId,
            bundleId: bundleId,
            deviceName: deviceName,
            osVersion: osVersion,
            deviceModel: deviceModel
        )
    }
}

// MARK: - Agent Commands

struct AgentCommand: Codable {
    let id: String
    let action: String
    let testID: String?
    let value: String?
    let direction: String?
    let amount: Double?
    let velocity: String?
}

struct AgentResponse: Codable {
    let id: String?
    let status: String
    let error: String?
    let hierarchy: ViewNode?
    let logs: [LogEntry]?
    let action: String?
    let deviceInfo: DeviceInfo?

    init(id: String? = nil, status: String, error: String? = nil, hierarchy: ViewNode? = nil, logs: [LogEntry]? = nil, action: String? = nil, deviceInfo: DeviceInfo? = nil) {
        self.id = id
        self.status = status
        self.error = error
        self.hierarchy = hierarchy
        self.logs = logs
        self.action = action
        self.deviceInfo = deviceInfo
    }
}

// MARK: - View Hierarchy

struct ViewNode: Codable {
    let name: String
    let testID: String?
    let text: String?
    let accessibilityLabel: String?
    let children: [ViewNode]
}

// MARK: - Log WebSocket Manager

class AgentLogSocketManager: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private let projectName: String
    private var reconnectTimer: Timer?

    init(projectName: String) {
        self.projectName = projectName
        super.init()

        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        // Set up log callback to send logs immediately
        LogBuffer.shared.onNewLog = { [weak self] entry in
            self?.sendLogEntry(entry)
        }

        connect()
    }

    func connect() {
        guard webSocketTask == nil else { return }

        let urlString = "ws://127.0.0.1:8767/\(projectName)" // New port
        guard let url = URL(string: urlString) else {
            print("Invalid Log WebSocket URL")
            return
        }

        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()

        print("Connecting to log server at \(urlString)...")
        receiveMessage()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                // The log server doesn't send messages, but we need the receive
                // loop to detect failures. We'll log if we get anything unexpected.
                print("Received unexpected message on log socket: \(message)")
                self?.receiveMessage() // Continue listening

            case .failure(let error):
                print("Log WebSocket receive error: \(error.localizedDescription)")
                self?.scheduleReconnect()
            }
        }
    }

    private func sendLogEntry(_ entry: LogEntry) {
        let response = AgentResponse(
            id: nil,
            status: "log",
            logs: [entry]
        )
        sendResponse(response)
    }

    private func sendResponse(_ response: AgentResponse) {
        guard let data = try? JSONEncoder().encode(response),
              let text = String(data: data, encoding: .utf8) else {
            print("Failed to encode log response")
            return
        }

        webSocketTask?.send(.string(text)) { error in
            if let error = error {
                print("Log WebSocket send error: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleReconnect() {
        DispatchQueue.main.async { [weak self] in
            self?.webSocketTask = nil
            self?.reconnectTimer?.invalidate()
            self?.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                print("Reconnecting to log server...")
                self?.connect()
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("Connected to log server")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown"
        print("Disconnected from log server: \(reasonString). Reconnecting...")
        scheduleReconnect()
    }
}

// MARK: - WebSocket Manager

class AgentWebSocketManager: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published var isConnected = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private let projectName: String
    private var reconnectTimer: Timer?

    init(projectName: String) {
        self.projectName = projectName
        super.init()

        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        connect()
    }

    func connect() {
        guard webSocketTask == nil else { return }

        let urlString = "ws://127.0.0.1:8765/\(projectName)"
        guard let url = URL(string: urlString) else {
            print("Invalid WebSocket URL")
            return
        }

        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()

        print("Connecting to agent server at \(urlString)...")
        receiveMessage()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self?.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self?.receiveMessage()

            case .failure(let error):
                print("WebSocket receive error: \(error.localizedDescription)")
                self?.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let command = try? JSONDecoder().decode(AgentCommand.self, from: data) else {
            print("Failed to decode command")
            sendResponse(AgentResponse(status: "error", error: "Invalid command format"))
            return
        }

        print("Received command: \(command.action)")

        Task { @MainActor in
            let response = await self.handleCommand(command)
            self.sendResponse(response)
        }
    }

    @MainActor
    private func handleCommand(_ command: AgentCommand) async -> AgentResponse {
        switch command.action {
        case "getViewHierarchy":
            let hierarchy = ViewHierarchyInspector.getHierarchy()
            return AgentResponse(id: command.id, status: "success", hierarchy: hierarchy)

        case "getConsoleLogs":
            let logs = LogBuffer.shared.getLogs()
            return AgentResponse(id: command.id, status: "success", logs: logs)

        case "tap":
            guard let testID = command.testID else {
                return AgentResponse(id: command.id, status: "error", error: "Missing testID", action: command.action)
            }
            let success = simulateTap(testID: testID)
            return AgentResponse(id: command.id, status: success ? "ok" : "error", action: command.action)

        case "input":
            guard let testID = command.testID, let value = command.value else {
                return AgentResponse(id: command.id, status: "error", error: "Missing testID or value", action: command.action)
            }
            let success = simulateInput(testID: testID, value: value)
            return AgentResponse(id: command.id, status: success ? "ok" : "error", action: command.action)

        case "longPress":
            guard let testID = command.testID else {
                return AgentResponse(id: command.id, status: "error", error: "Missing testID", action: command.action)
            }
            let success = simulateLongPress(testID: testID)
            return AgentResponse(id: command.id, status: success ? "ok" : "error", action: command.action)

        case "scroll":
            guard let testID = command.testID, let direction = command.direction else {
                return AgentResponse(id: command.id, status: "error", error: "Missing testID or direction", action: command.action)
            }
            let amount = command.amount ?? 100.0
            let success = simulateScroll(testID: testID, direction: direction, amount: amount)
            return AgentResponse(id: command.id, status: success ? "ok" : "error", action: command.action)

        case "swipe":
            guard let testID = command.testID, let direction = command.direction else {
                return AgentResponse(id: command.id, status: "error", error: "Missing testID or direction", action: command.action)
            }
            let velocity = command.velocity ?? "medium"
            let success = simulateSwipe(testID: testID, direction: direction, velocity: velocity)
            return AgentResponse(id: command.id, status: success ? "ok" : "error", action: command.action)

        default:
            return AgentResponse(id: command.id, status: "error", error: "Unknown action: \(command.action)", action: command.action)
        }
    }

    private func sendResponse(_ response: AgentResponse) {
        guard let data = try? JSONEncoder().encode(response),
              let text = String(data: data, encoding: .utf8) else {
            print("Failed to encode response")
            return
        }

        webSocketTask?.send(.string(text)) { error in
            if let error = error {
                print("WebSocket send error: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleReconnect() {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.webSocketTask = nil

            self?.reconnectTimer?.invalidate()
            self?.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                print("Reconnecting to agent server...")
                self?.connect()
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
            print("Connected to agent server")

            // Send device info immediately after connecting
            self?.sendDeviceInfo()
        }
    }

    private func sendDeviceInfo() {
        let deviceInfo = DeviceInfoProvider.getDeviceInfo()
        let response = AgentResponse(
            id: "device-info",
            status: "deviceInfo",
            deviceInfo: deviceInfo
        )
        sendResponse(response)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown"
        print("Disconnected from agent server: \(reasonString). Reconnecting...")
        scheduleReconnect()
    }
}

// MARK: - Simulation Functions

@MainActor
func simulateTap(testID: String) -> Bool {
    guard let node = AgentRegistry.shared.getNode(testID: testID) else {
        print("simulateTap: No node found for testID \"\(testID)\"")
        return false
    }

    if let onTap = node.onTap {
        onTap()
        return true
    }

    print("simulateTap: No onTap handler found for testID \"\(testID)\"")
    return false
}

@MainActor
func simulateInput(testID: String, value: String) -> Bool {
    guard let node = AgentRegistry.shared.getNode(testID: testID) else {
        print("simulateInput: No node found for testID \"\(testID)\"")
        return false
    }

    if let onChangeText = node.onChangeText {
        onChangeText(value)
        return true
    }

    print("simulateInput: No onChangeText handler found for testID \"\(testID)\"")
    return false
}

@MainActor
func simulateLongPress(testID: String) -> Bool {
    guard let node = AgentRegistry.shared.getNode(testID: testID) else {
        print("simulateLongPress: No node found for testID \"\(testID)\"")
        return false
    }

    if let onLongPress = node.onLongPress {
        onLongPress()
        return true
    }

    print("simulateLongPress: No onLongPress handler found for testID \"\(testID)\"")
    return false
}

@MainActor
func simulateScroll(testID: String, direction: String, amount: Double) -> Bool {
    guard var node = AgentRegistry.shared.getNode(testID: testID) else {
        return false
    }

    // Try to get the UIScrollView from the stored reference
    var scrollView: UIScrollView?
    if let view = node.view as? UIScrollView {
        scrollView = view
    } else {
        // Fallback: try to find it in the view hierarchy
        scrollView = findScrollView(testID: testID)
    }

    guard let scrollView = scrollView else {
        print("simulateScroll: ERROR - No UIScrollView found for testID \"\(testID)\"")
        return false
    }

    // Calculate relative scroll offset
    let deltaX = direction == "right" ? CGFloat(amount) : direction == "left" ? -CGFloat(amount) : 0
    let deltaY = direction == "down" ? CGFloat(amount) : direction == "up" ? -CGFloat(amount) : 0

    // Get current offset
    let currentOffset = scrollView.contentOffset

    // Calculate new offset (relative scrolling)
    let newX = max(0, min(scrollView.contentSize.width - scrollView.bounds.width, currentOffset.x + deltaX))
    let newY = max(0, min(scrollView.contentSize.height - scrollView.bounds.height, currentOffset.y + deltaY))
    let newOffset = CGPoint(x: newX, y: newY)

    // Update tracked position
    node.scrollPosition = newOffset
    AgentRegistry.shared.register(testID: testID, node: node)

    // Perform the scroll
    scrollView.setContentOffset(newOffset, animated: true)

    print("simulateScroll: Scrolled from (\(currentOffset.x), \(currentOffset.y)) to (\(newOffset.x), \(newOffset.y))")
    return true
}

// Helper function to find UIScrollView in the view hierarchy
@MainActor
private func findScrollView(testID: String) -> UIScrollView? {
    // Get the root view from the active window scene
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = scene.windows.first(where: { $0.isKeyWindow }),
          let rootView = window.rootViewController?.view else {
        return nil
    }

    // Find all ScrollViews in the hierarchy
    let allScrollViews = findAllScrollViews(in: rootView)
    // Find all ScrollViews that contain the testID
    var candidates: [(scrollView: UIScrollView, area: CGFloat)] = []
    for (index, scrollView) in allScrollViews.enumerated() {
        if containsTestID(testID, in: scrollView) {
            let area = scrollView.bounds.width * scrollView.bounds.height
            candidates.append((scrollView, area))
        }
    }

    // Return the smallest ScrollView (innermost) that contains the testID
    if let smallest = candidates.min(by: { $0.area < $1.area }) {
        return smallest.scrollView
    }

    return nil
}

@MainActor
private func findAllScrollViews(in view: UIView) -> [UIScrollView] {
    var scrollViews: [UIScrollView] = []

    // Check if this view is a ScrollView
    if let scrollView = view as? UIScrollView {
        scrollViews.append(scrollView)
    }

    // Recursively search all subviews
    for subview in view.subviews {
        scrollViews.append(contentsOf: findAllScrollViews(in: subview))
    }

    return scrollViews
}

@MainActor
private func containsTestID(_ testID: String, in view: UIView) -> Bool {
    // Check if this view has the testID
    if let identifier = view.accessibilityIdentifier {
        print("containsTestID: Found view with accessibilityIdentifier '\(identifier)', looking for '\(testID)'")
        if identifier == testID {
            print("containsTestID: MATCH FOUND!")
            return true
        }
    }

    // Recursively check all subviews
    for subview in view.subviews {
        if containsTestID(testID, in: subview) {
            return true
        }
    }

    return false
}

@MainActor
func simulateSwipe(testID: String, direction: String, velocity: String) -> Bool {
    guard let node = AgentRegistry.shared.getNode(testID: testID) else {
        print("simulateSwipe: No node found for testID \"\(testID)\"")
        return false
    }

    // First check if there's an explicit onSwipe handler
    if let onSwipe = node.onSwipe {
        onSwipe(direction, velocity)
        return true
    }

    // Fallback: if it's a scrollable view without explicit swipe handler,
    // convert swipe to scroll
    if node.scrollViewProxy != nil {
        let velocityMap: [String: Double] = ["slow": 300, "medium": 600, "fast": 1200]
        let distance = velocityMap[velocity] ?? 600
        return simulateScroll(testID: testID, direction: direction, amount: distance)
    }

    print("simulateSwipe: No swipe handler or scroll support found for testID \"\(testID)\"")
    return false
}

// MARK: - View Hierarchy Inspector

class ViewHierarchyInspector {
    @MainActor
    static func getHierarchy() -> ViewNode? {
        // Get the root view from the active window scene
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              let rootView = window.rootViewController?.view else {
            print("Failed to get root view")
            return fallbackHierarchy()
        }

        // Traverse the UIKit view hierarchy
        let hierarchy = traverseView(rootView)

        // Augment with registry information
        // SwiftUI's accessibilityIdentifier doesn't always propagate to UIKit,
        // so we add registered testIDs as a separate section
        let registeredIDs = AgentRegistry.shared.getAllTestIDs()

        if !registeredIDs.isEmpty {
            var augmentedChildren = hierarchy.children

            // Add a "RegisteredElements" node containing all testIDs
            let registeredNodes = registeredIDs.map { testID in
                ViewNode(
                    name: "RegisteredElement",
                    testID: testID,
                    text: nil,
                    accessibilityLabel: nil,
                    children: []
                )
            }

            let registryNode = ViewNode(
                name: "AgentRegistry",
                testID: nil,
                text: "Elements registered for agent interaction",
                accessibilityLabel: nil,
                children: registeredNodes
            )

            augmentedChildren.append(registryNode)

            return ViewNode(
                name: hierarchy.name,
                testID: hierarchy.testID,
                text: hierarchy.text,
                accessibilityLabel: hierarchy.accessibilityLabel,
                children: augmentedChildren
            )
        }

        return hierarchy
    }

    // Fallback to registry-based hierarchy if UIKit traversal fails
    private static func fallbackHierarchy() -> ViewNode? {
        let testIDs = AgentRegistry.shared.getAllTestIDs()
        let children = testIDs.map { testID in
            ViewNode(
                name: "View",
                testID: testID,
                text: nil,
                accessibilityLabel: nil,
                children: []
            )
        }
        return ViewNode(
            name: "Root",
            testID: nil,
            text: nil,
            accessibilityLabel: nil,
            children: children
        )
    }

    private static func traverseView(_ view: UIView) -> ViewNode {
        // Get the class name, removing module prefix if present
        let fullTypeName = String(describing: type(of: view))
        let typeName = fullTypeName.components(separatedBy: ".").last ?? fullTypeName

        // Get accessibility properties - check the view and all its subviews
        var testID = view.accessibilityIdentifier
        var accessibilityLabel = view.accessibilityLabel

        // Try to extract text content from common view types
        var text: String? = nil
        if let label = view as? UILabel {
            text = label.text
            // If no explicit accessibilityLabel, use the text
            if accessibilityLabel == nil {
                accessibilityLabel = label.text
            }
        } else if let button = view as? UIButton {
            text = button.titleLabel?.text ?? button.currentTitle
            if accessibilityLabel == nil {
                accessibilityLabel = text
            }
        } else if let textField = view as? UITextField {
            text = textField.text
            // Also check for placeholder
            if (text == nil || text!.isEmpty), let placeholder = textField.placeholder {
                accessibilityLabel = placeholder
            }
        } else if let textView = view as? UITextView {
            text = textView.text
        }

        // Get meaningful name for the component
        let name = getComponentName(typeName: typeName)

        // Recursively traverse child views
        var children: [ViewNode] = []

        // For SwiftUI hosting views, we need to traverse ALL subviews recursively
        // because SwiftUI can nest views deeply
        let subviewsToTraverse = getAllSubviews(of: view)

        for subview in subviewsToTraverse {
            let childNode = traverseView(subview)
            if shouldIncludeNode(childNode) {
                children.append(childNode)
            }
        }

        // If this view has no testID but has exactly one child with a testID,
        // bubble up the testID (SwiftUI often wraps views in containers)
        if testID == nil && children.count == 1 && children[0].testID != nil {
            testID = children[0].testID
        }

        return ViewNode(
            name: name,
            testID: testID,
            text: text,
            accessibilityLabel: accessibilityLabel,
            children: children
        )
    }

    // Get all immediate subviews of a view
    private static func getAllSubviews(of view: UIView) -> [UIView] {
        return view.subviews
    }

    // Convert UIKit type names to more readable component names
    private static func getComponentName(typeName: String) -> String {
        // Remove common prefixes
        var name = typeName
        if name.hasPrefix("_") {
            name = String(name.dropFirst())
        }

        // Map common UIKit types to friendly names
        let mappings: [String: String] = [
            "UILabel": "Text",
            "UIButton": "Button",
            "UITextField": "TextField",
            "UITextView": "TextView",
            "UIImageView": "Image",
            "UIScrollView": "ScrollView",
            "UITableView": "TableView",
            "UICollectionView": "CollectionView",
            "UIStackView": "StackView",
            "UIView": "View",
            "UIHostingView": "SwiftUIView",
            "UINavigationBar": "NavigationBar",
            "UITabBar": "TabBar"
        ]

        // Check for exact matches
        if let mapped = mappings[name] {
            return mapped
        }

        // Check for partial matches (e.g., "UIButtonLabel" -> "Button")
        for (pattern, replacement) in mappings {
            if name.contains(pattern.replacingOccurrences(of: "UI", with: "")) {
                return replacement
            }
        }

        return name
    }

    // Determine if a node should be included in the hierarchy
    private static func shouldIncludeNode(_ node: ViewNode) -> Bool {
        // Always include nodes with testID (these are explicitly marked for agent interaction)
        if node.testID != nil {
            return true
        }

        // Include nodes with text content
        if node.text != nil && !node.text!.isEmpty {
            return true
        }

        // Include nodes with accessibility labels
        if node.accessibilityLabel != nil && !node.accessibilityLabel!.isEmpty {
            return true
        }

        // Include nodes that have meaningful children (check this early)
        if !node.children.isEmpty {
            return true
        }

        // Include meaningful component types
        let meaningfulTypes = [
            "Button", "Text", "TextField", "TextView", "Image",
            "ScrollView", "StackView", "NavigationBar", "TabBar",
            "SwiftUIView"
        ]
        if meaningfulTypes.contains(node.name) {
            return true
        }

        // Filter out noise
        let ignoredTypes = [
            "ContainerView", "WrapperView", "LayoutView",
            "ModifiedContent", "ViewHost"
        ]
        if ignoredTypes.contains(where: { node.name.contains($0) }) {
            return false
        }

        // Be more permissive - include most views by default
        // The hierarchy will be large but complete
        return true
    }
}

// MARK: - AgentDebugBridge View

public struct AgentDebugBridge: View {
    let projectName: String
    @StateObject private var webSocketManager: AgentWebSocketManager
    @StateObject private var logSocketManager: AgentLogSocketManager

    public init(projectName: String) {
        self.projectName = projectName
        _webSocketManager = StateObject(wrappedValue: AgentWebSocketManager(projectName: projectName))
        _logSocketManager = StateObject(wrappedValue: AgentLogSocketManager(projectName: projectName))
    }

    public var body: some View {
        EmptyView()
            .onDisappear {
                webSocketManager.disconnect()
                logSocketManager.disconnect()
            }
    }
}
