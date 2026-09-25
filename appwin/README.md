# appwin

Turns a local veb (or vweb) server into a desktop app — without bundling
Chromium. It shows your page in the OS's own web engine (WebView2 on
Windows, WebKitGTK on Linux, WKWebView/Cocoa on macOS) through
[ttytm/webview](https://github.com/ttytm/webview), the same approach Tauri
uses. The result is a few hundred KB and one process, not Electron's 100MB+
bundled browser and separate renderer process.

## Install
```
v install ttytm.webview
v install --git https://github.com/<you>/appwin
```
Then build webview's small C layer once (rebuild any time you update it):
```
# Linux/macOS
v ~/.vmodules/ttytm/webview/build.vsh
# Windows PowerShell
v $HOME/.vmodules/ttytm/webview/build.vsh
```
**Linux** also needs WebKitGTK installed: `sudo apt install libgtk-3-dev libwebkit2gtk-4.0-dev` (or your distro's equivalent). **Windows 10/11** already has WebView2. **macOS** needs nothing extra.

## Use
```v
import appwin
import veb

fn main() {
	mut app := &App{ /* ... your db etc, e.g. under appwin.data_dir('MyApp') ... */ }
	spawn fn (mut app App) {
		veb.run_at[App, Context](mut app, host: '127.0.0.1', port: 8787, family: .ip) or {}
	}(mut app)

	appwin.run(title: 'My App', url: 'http://127.0.0.1:8787', port: 8787)
	exit(0) // window closed -> quit the whole app, server thread included
}
```

## Windows build note
`ttytm.webview`'s own C layer is best built with `gcc` (its docs recommend
`v -cc gcc run .`). If your app also does HTTPS with `net.http` and you hit
the `asn1parse.o` / mbedtls `.C`-as-C++ build error with gcc, switch just
your app's own build to tcc (`v -cc tcc -o App.exe .`); the webview library
is a separate prebuilt step and isn't affected by that flag. If linking
still fails, this is the one part of `appwin` I haven't been able to test —
open an issue with the error.

## Publish on VPM
Put this folder in its own GitHub repo, fill in `v.mod`, then add it at
https://vpm.vlang.io (or install directly with
`v install --git https://github.com/<you>/appwin`).
