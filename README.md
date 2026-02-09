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

## Quick Start

### 1. Configure URL Scheme for Deep Linking

To enable deep link pairing with physical devices, configure your app's URL scheme:

**Option A: In Info.plist**

Add this to your `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>CFBundleURLName</key>
        <string>com.yourcompany.yourapp</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>yourapp</string>
        </array>
    </dict>
</array>
```

**Option B: In Xcode**

1. Select your project in the Project Navigator
2. Select your app target
3. Go to the **Info** tab
4. Expand **URL Types**
5. Click **+** to add a new URL type
6. Fill in:
   - **Identifier**: `com.yourcompany.yourapp` (typically your bundle ID)
   - **URL Schemes**: `yourapp` (e.g., `myapp`, `agenteract-swift-example`)
   - **Role**: `Editor`

**Important:** The URL scheme should be unique to your app and match what you'll use in the CLI connect command.

### 2. Add the Agent Debug Bridge

Add the `AgentDebugBridge` to your root view to enable agent communication. **No additional setup is required in your App struct** - just add it to your main view:

**App.swift (Standard SwiftUI - No special setup needed):**
```swift
import SwiftUI

@main
struct YourApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

**ContentView.swift (Add AgentDebugBridge here):**
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

**Important:** The `AgentDebugBridge` automatically handles everything internally:
- Deep link configuration handling (no code needed in your App struct)
- WebSocket connection management (single connection for commands and logs)
- Saving connection settings to UserDefaults
- Auto-reconnection when the app launches
- Log streaming over the main WebSocket connection

You don't need to create WebSocket managers, handle deep links manually, or add any code to your App struct.

### 3. Add Agent Bindings to Your Views

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

### 4. Connect Your Device

**For Simulators (Automatic):**
Simulators automatically connect to `ws://127.0.0.1:8765` - no setup needed!

**For Physical Devices (Deep Link Pairing):**

1. Configure your app in the CLI:
   ```bash
   pnpm agenteract add-config . my-app native --scheme yourapp
   ```

2. Start the dev server:
   ```bash
   pnpm agenteract dev
   ```

3. Connect your device:
   ```bash
   pnpm agenteract connect
   ```

4. Scan the QR code with your device camera, or select your device from the list

The app will receive the deep link, save the configuration, and connect automatically!

### 5. Use the Logger (Optional)

Send logs to both Xcode console and the agent server:

```swift
import Agenteract

AppLogger.info("User logged in")
AppLogger.error("Failed to fetch data")
AppLogger.debug("Cache hit for key: \(key)")
```

## Deep Linking & Configuration

### How Deep Link Pairing Works

1. **CLI generates URL**: When you run `pnpm agenteract connect yourapp`, the CLI generates a deep link:
   ```
   yourapp://agenteract/config?host=192.168.1.5&port=8765&token=abc123
   ```

2. **Device receives link**: The deep link opens your app (via QR code scan or simulator injection)

3. **App parses config**: `AgentDebugBridge` automatically catches the URL and extracts:
   - `host`: Server IP address
   - `port`: WebSocket port (usually 8765)
   - `token`: Authentication token

4. **Config persists**: Settings are saved to `UserDefaults` automatically

5. **Auto-reconnect**: Future app launches use the saved config

### URL Scheme Format

Your app must be configured to handle deep links in the format:
```
<your-scheme>://agenteract/config?host=<ip>&port=<port>&token=<token>
```

Where `<your-scheme>` matches the URL scheme you configured in Info.plist/Xcode.

### Security

- **Localhost connections**: No token required for simulators (connects to `127.0.0.1`)
- **Remote connections**: Token authentication required for physical devices
- **Token storage**: Tokens are stored securely in UserDefaults
- **Manual override**: Users can always reconfigure by scanning a new QR code

### Troubleshooting Deep Links

**App doesn't open when scanning QR code:**
- Verify URL scheme is configured in Info.plist
- Check that the scheme matches what you used in `add-config --scheme`
- On iOS 14+, you may need to approve the deep link prompt

**Connection fails after deep linking:**
- Check that the agent server is running
- Verify you're on the same network as the server
- Look for connection errors in Xcode console

**Want to reset configuration:**
- Simply scan a new QR code to update settings
- Or clear UserDefaults: `UserDefaults.standard.removeObject(forKey: "com.agenteract.config")`

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
      type: 'xcode',
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
- **AgentDebugBridge.swift**: Manages a single WebSocket connection for all communication (commands, hierarchy, logs), handles deep link configuration, and persists settings
- **Logger.swift**: Logging utility that sends logs to both Xcode console and the agent server via the main WebSocket connection

## Troubleshooting

### Agent server not connecting

**For Simulators:**
Make sure:
1. The agent server is running (`pnpm agenteract dev`)
2. Your `projectName` matches the config
3. Simulator automatically connects to `127.0.0.1:8765` (no deep linking needed)

**For Physical Devices:**
1. Ensure you've completed deep link pairing (`pnpm agenteract connect`)
2. Verify the app received and saved the configuration (check Xcode console for `[Agenteract] Config saved`)
3. Confirm you're on the same WiFi network as your development machine
4. Check for authentication errors in the agent server logs

### View hierarchy is empty

Ensure:
1. Views have `testID` properties set via `.agentBinding()`
2. The `AgentDebugBridge` is added to your view hierarchy
3. The app is fully loaded before querying hierarchy

## License

MIT

## Contributing

Contributions welcome! Please see the main [Agenteract repository](https://github.com/agenteract/agenteract) for contribution guidelines.
