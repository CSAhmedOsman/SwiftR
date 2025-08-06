# SwiftR

[![Join the chat at https://gitter.im/adamhartford/SwiftR](https://badges.gitter.im/adamhartford/SwiftR.svg)](https://gitter.im/adamhartford/SwiftR?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

SwiftR is a powerful SignalR client library for iOS, written in Swift. It allows seamless communication with SignalR servers using WebSockets or other transports. Originally based on the now-archived `adamhartford/SwiftR`, this version includes major upgrades for modern iOS development.

---

## 🚀 What's New

* 🔄 Migrated from `UIWebView` to `WKWebView` for modern compatibility and performance.
* 📦 Now supports both CocoaPods and Swift Package Manager (SPM).
* 🧼 Codebase cleaned and refactored for Swift 5+, Xcode 15+, and iOS 14+.
* 💬 Added documentation and inline comments (Arabic & English).
* ✅ Compatibility with modern iOS lifecycles and best practices.
* 📡 Updated for compatibility with SignalR 2.x (ASP.NET Framework).

---

## 📦 Installation

### CocoaPods

```ruby
pod 'SwiftR', :git => 'https://github.com/CSAhmedOsman/SwiftR.git', :branch => 'master'
```

Then run:

```bash
pod install
```

### Swift Package Manager (SPM)

1. In Xcode, open your project settings.
2. Go to the **Package Dependencies** tab.
3. Click the `+` button and enter:

```
https://github.com/CSAhmedOsman/SwiftR.git
```

4. Choose the `main` branch or set a version once releases are tagged.

---

## 💡 Usage

```swift
let connection = SignalR("http://localhost:5000")

let hub = Hub("chatHub")
hub.on("receiveMessage") { args in
    let message = args![0] as! String
    print("Received: \(message)")
}

connection.addHub(hub)

connection.started = {
    print("Connected")
    hub.invoke("send", arguments: ["Hello from Swift!"])
}

connection.start()
```

---

## 🛠 Features

* ✅ Connect to multiple hubs
* ✅ Register event handlers for server methods
* ✅ Send data to server via `invoke`
* 🔁 Reconnection handling
* 🧾 Error logging & status tracking
* 🌍 Supports persistent connections and hub-based messaging

---

## 🌐 SignalR Version

This library works with **SignalR 2.x** servers. Server version 2.1 is confirmed compatible. For ASP.NET Core SignalR (3.0+), this client is **not** compatible.

---

## 📘 Documentation

All main components are documented inline. Key classes:

* `SignalR`: Main connection manager
* `Hub`: Represents a SignalR hub
* `HubConnection`: Holds connection options & state

### Transport Methods

```swift
connection.transport = .auto            // Default
connection.transport = .webSockets
connection.transport = .serverSentEvents
connection.transport = .foreverFrame
connection.transport = .longPolling
```

### Connection Lifecycle Events

```swift
connection.started = { print("Started") }
connection.connected = { print("Connected: \(connection.connectionID)") }
connection.connectionSlow = { print("Connection is slow") }
connection.reconnecting = { print("Reconnecting...") }
connection.reconnected = { print("Reconnected") }
connection.disconnected = { print("Disconnected") }
```

### Manual Reconnect Example

```swift
connection.disconnected = {
    print("Disconnected... Retrying in 5 seconds")
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        connection.start()
    }
}
```

### Sending Query Strings or Headers

```swift
connection.queryString = ["token": "abc123"]
connection.headers = ["X-Auth": "Bearer abc123"]
```

---

## 🔗 Demo Server

Try it using the original demo server:

[http://swiftr.azurewebsites.net](http://swiftr.azurewebsites.net)

Source: [SwiftRChat](https://github.com/adamhartford/SwiftRChat)

Also see: [SignalR Application (ASP.NET)](https://github.com/adamhartford/SignalRApplication)

---

## 🤝 Contributing

Contributions are welcome! Please fork the repo and submit a PR.

* ✅ Make sure code is SwiftLint clean
* ✅ Add tests if necessary
* ✅ Keep documentation up to date

---

## 📄 License

MIT License

---

## 🙌 Author

Maintained and modernized by [Ahmed Osman El-Harby](https://github.com/CSAhmedOsman)
