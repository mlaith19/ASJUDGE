@echo off
title Arabian Show Judge - Server
echo.
echo  ==========================================
echo   Arabian Show Judge - Backend Server
echo  ==========================================
echo.
echo  Admin Panel : http://localhost:5000/admin
echo  LAN Address : http://192.168.1.55:5000/admin
echo.
echo  Username: admin
echo  Password: admin123
echo.
echo  Press CTRL+C to stop the server
echo.

:: Open firewall port (requires admin - will prompt if not already open)
netsh advfirewall firewall show rule name="Arabian Show Judge" >nul 2>&1
if errorlevel 1 (
    echo  [+] Adding firewall rule for port 5000...
    netsh advfirewall firewall add rule name="Arabian Show Judge" dir=in action=allow protocol=TCP localport=5000 >nul 2>&1
)

cd /d "%~dp0server"
node src/server.js
pause
