@echo off
rem 1) One-time (or after updating the webview module):
rem      v %USERPROFILE%\.vmodules\ttytm\webview\build.vsh
rem 2) Then build Scout. tcc avoids a Windows gcc/mbedtls miscompile in this
rem    project's own HTTPS code (see README); the webview library itself is
rem    prebuilt by step 1, so this flag doesn't affect it.
v -cc tcc -o Scout.exe . || exit /b 1
powershell -NoProfile -Command "$f='Scout.exe';$b=[IO.File]::ReadAllBytes($f);$p=[BitConverter]::ToInt32($b,0x3C);$b[$p+0x5C]=2;[IO.File]::WriteAllBytes($f,$b)"
echo Built Scout.exe
