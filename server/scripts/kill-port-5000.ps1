# Free port 5000 on Windows - run from server folder or project root
$port = 5000
$found = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique
if ($found) {
    $found | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
    Write-Host "Stopped process(es) using port $port"
} else {
    Write-Host "No process found on port $port"
}
