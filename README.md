# Scout
Single-file desktop app for finding GitHub issues you can actually do. Written in V.

Setup (once, or after updating the webview module):
    v ~/.vmodules/ttytm/webview/build.vsh     (Linux/macOS)
    v %USERPROFILE%\.vmodules\ttytm\webview\build.vsh   (Windows PowerShell)

Install deps:  v install ttytm.webview
Linux also needs:  sudo apt install libgtk-3-dev libwebkit2gtk-4.0-dev

Build:  build.bat (Windows) or ./build.sh (Linux/macOS)
Run:    Scout.exe or ./Scout — opens in its own native window, no browser, no console.
Run:    Scout.exe            (opens its own window, no browser tabs to manage)

Data (keys, skills, issues) is stored in a `data\scout.db` folder next to Scout.exe — copy or move the whole Scout folder and your data goes with it, same as a portable app. If that folder can't be written to (e.g. Scout sits in Program Files), it falls back to %APPDATA%\Scout\scout.db.
The server listens only on 127.0.0.1:8787. The UI is embedded in the exe.
Everything is entered in the app: tokens, skills you know, skills you want to learn, level.
