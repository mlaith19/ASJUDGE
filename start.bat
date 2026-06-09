@echo off
title Arabian Show Judge - Server
chcp 65001 >nul

:: ── Check Node.js ──────────────────────────────────────────────
where node >nul 2>&1
if errorlevel 1 (
    echo.
    echo  [ERROR] Node.js is not installed.
    echo  Download from https://nodejs.org  (LTS version)
    echo.
    pause
    exit /b 1
)

:: ── Install dependencies if missing ────────────────────────────
if not exist "%~dp0server\node_modules\" (
    echo  [+] Installing dependencies (first run)...
    cd /d "%~dp0server"
    npm install
    if errorlevel 1 (
        echo  [ERROR] npm install failed.
        pause
        exit /b 1
    )
)

:: ── Detect LAN IP ──────────────────────────────────────────────
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /i "IPv4" ^| findstr /v "127.0.0.1"') do (
    for /f "tokens=1" %%B in ("%%A") do set LAN_IP=%%B
)
if not defined LAN_IP set LAN_IP=localhost

:: ── Firewall rule ───────────────────────────────────────────────
netsh advfirewall firewall show rule name="Arabian Show Judge" >nul 2>&1
if errorlevel 1 (
    echo  [+] Adding firewall rule for port 5000...
    netsh advfirewall firewall add rule name="Arabian Show Judge" dir=in action=allow protocol=TCP localport=5000 >nul 2>&1
)

:: ── Start ───────────────────────────────────────────────────────
echo.
echo  ==========================================
echo   Arabian Show Judge - Backend Server
echo  ==========================================
echo.
echo  Local    : http://localhost:5000/admin
echo  Network  : http://%LAN_IP%:5000/admin
echo.
echo  Username : admin
echo  Password : admin123
echo.
echo  Enter the Network address in the tablet app.
echo  Press CTRL+C to stop the server.
echo.

cd /d "%~dp0server"
node src/server.js
pause
