# Agenteract Swift

SwiftUI integration for the Agenteract agent interaction framework.

## Overview

Agenteract Swift provides the tools needed to make your SwiftUI applications inspectable and controllable by AI agents. It includes:

- **Agent bindings** for SwiftUI views (buttons, text fields, etc.)
- **View hierarchy inspection** to let agents "see" your UI
- **Console log streaming** to agents
- **WebSocket bridge** for communication with the Agenteract agent server

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 14.0+

## Installation

### Swift Package Manager

Add Agenteract to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/agenteract/agenteract-swift", from: "1.0.0")
]
```

Or in Xcode:
1. File > Add Package Dependencies
2. Enter the repository URL: `https://github.com/agenteract/agenteract-swift`
3. Select the version you want to use

## Usage

### 1. Add the Agent Debug Bridge

Add the `AgentDebugBridge` to your root view to enable agent communication:

```swift
import SwiftUI
import Agenteract

struct ContentView: View {
    var body: some View {
        VStack {
            // Your UI here
        }
        .background(
            AgentDebugBridge(projectName: "your-app-name")
        )
    }
}
```

The `projectName` should match the name in your `agenteract.config.js`.

### 2. Add Agent Bindings to Your Views

Use the `.agentBinding()` modifier or convenience wrappers to make views agent-controllable:

#### Using the View Modifier

```swift
Button("Click Me") {
    handleClick()
}
.agentBinding(testID: "my-button", onTap: {
    handleClick()
})
```

#### Using AgentButton

```swift
AgentButton(testID: "my-button") {
    handleClick()
} label: {
    Text("Click Me")
}
```

#### Using AgentTextField

```swift
@State private var inputText = ""

AgentTextField(
    testID: "my-input",
    placeholder: "Enter text",
    text: $inputText
)
```

### 3. Use the Logger

Send logs to both Xcode console and the agent server:

```swift
import Agenteract

AppLogger.info("User logged in")
AppLogger.error("Failed to fetch data")
AppLogger.debug("Cache hit for key: \(key)")
```

## Key Concepts

### Test IDs

Every interactive element needs a unique `testID` to be addressable by agents:

```swift
Button("Submit") { submit() }
    .agentBinding(testID: "submit-button", onTap: { submit() })
```

### Handler Registration

The `agentBinding` modifier registers event handlers with the agent system while also functioning as normal SwiftUI components.

### View Hierarchy

The agent can inspect your app's view hierarchy using the `getViewHierarchy` command, which traverses the UIKit view tree and augments it with registered agent bindings.

## Configuration

Ensure your `agenteract.config.js` includes your Swift app:

```javascript
export default {
  projects: [
    {
      name: 'your-app-name',
      type: 'swift',
      // ... other configuration
    }
  ]
}
```

## Agent Commands

Once integrated, agents can:

- **View the hierarchy**: See all UI components and their structure
- **Tap elements**: Simulate taps on buttons and other views
- **Input text**: Fill text fields programmatically
- **Long press**: Trigger long press gestures
- **Read logs**: Access console output from the app

## Example

See the [swift-app example](../../examples/swift-app) for a complete working implementation.

## Architecture

- **AgentBinding.swift**: View modifiers and convenience wrappers for marking views as agent-controllable
- **AgentDebugBridge.swift**: WebSocket communication, command handling, and view hierarchy inspection
- **Logger.swift**: Logging utility that sends logs to both Xcode and the agent server

## Troubleshooting

### Agent server not connecting

Make sure:
1. The agent server is running (`pnpm agenterserve dev`)
2. Your `projectName` matches the config
3. You're running on localhost/simulator (WebSocket connects to `127.0.0.1:8765`)

### View hierarchy is empty

Ensure:
1. Views have `testID` properties set via `.agentBinding()`
2. The `AgentDebugBridge` is added to your view hierarchy
3. The app is fully loaded before querying hierarchy

## License

MIT

## Contributing

Contributions welcome! Please see the main [Agenteract repository](https://github.com/agenteract/agenteract) for contribution guidelines.
