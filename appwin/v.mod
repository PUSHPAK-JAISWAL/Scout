Module {
	name: 'appwin'
	description: 'Runs a local veb server and shows it in a native, embedded OS webview window (WebView2 on Windows, WebKitGTK on Linux, Cocoa/WebKit on macOS) instead of Chromium — the same approach Tauri uses. No bundled browser, small binary, low memory. Quits the whole process when the window closes.'
	version: '0.1.0'
	license: 'MIT'
	dependencies: ['ttytm.webview']
}
