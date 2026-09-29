module appwin

// appwin gives a local V web server (veb, vweb, anything on 127.0.0.1) an
// Electron-like feel, but without bundling a browser: it shows your page in
// the OS's own native web engine via ttytm.webview (WebView2 on Windows,
// WebKitGTK on Linux, WKWebView on macOS) — the same technique Tauri uses.
// A real Chromium bundle is 100MB+ and its own process; this is a few
// hundred KB and runs the UI inside your own process.
import pushpak_jaiswal.webview
import net
import os
import time

pub struct Options {
pub:
	title  string = 'App' // window title
	url    string         // e.g. http://127.0.0.1:8787
	port   int             // if set, wait for this local port before opening the window
	width  int = 1280
	height int = 860
}

// data_dir returns (and creates) a per-user folder such as %APPDATA%\<name>
// on Windows, ~/.config/<name> on Linux, ~/Library/Application Support/<name>
// on macOS.
pub fn data_dir(name string) string {
	d := os.join_path(os.config_dir() or { '.' }, name)
	os.mkdir_all(d) or {}
	return d
}

// portable_dir returns (and creates) a "data" folder next to the exe, like
// an Electron app packed as a portable .exe with everything under one
// folder — copy or delete the whole thing and you take your data with it.
// Falls back to data_dir(name) if that folder isn't writable, which happens
// when the exe sits somewhere protected such as Program Files.
pub fn portable_dir(name string) string {
	exe := os.real_path(os.executable())
	d := os.join_path(os.dir(exe), 'data')
	os.mkdir_all(d) or { return data_dir(name) }
	probe := os.join_path(d, '.write_test')
	os.write_file(probe, '') or { return data_dir(name) }
	os.rm(probe) or {}
	return d
}

fn wait_port(port int) {
	for _ in 0 .. 100 {
		mut c := net.dial_tcp('127.0.0.1:${port}') or {
			time.sleep(100 * time.millisecond)
			continue
		}
		c.close() or {}
		return
	}
}

// run opens the native window and blocks until the user closes it. Call it
// from main(), on the main thread, after starting your server with `spawn`.
// When it returns, the window is gone; exit(0) right after it to end the
// server thread too — there is nothing left for the app to do.
pub fn run(o Options) {
	if o.port > 0 {
		wait_port(o.port)
	}
	mut w := webview.create(debug: false)
	w.set_title(o.title)
	w.set_size(o.width, o.height, .@none)
	w.navigate(o.url)
	w.run()
	w.destroy()
}
