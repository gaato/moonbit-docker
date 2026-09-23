$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Invoke-WebRequest -Uri 'https://cli.moonbitlang.com/install/powershell.ps1' -OutFile 'C:\moonbit-installer.ps1'
& 'C:\moonbit-installer.ps1'
if ($LASTEXITCODE -ne 0) { throw "MoonBit installer failed with exit code $LASTEXITCODE" }

& "$env:MOON_HOME\bin\moon.exe" version --all
if ($LASTEXITCODE -ne 0) { throw "moon version failed with exit code $LASTEXITCODE" }

Remove-Item 'C:\moonbit-installer.ps1'
