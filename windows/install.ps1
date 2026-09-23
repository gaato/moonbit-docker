$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Invoke-WebRequest -Uri 'https://cli.moonbitlang.com/install/powershell.ps1' -OutFile 'C:\moonbit-installer.ps1'
& 'C:\moonbit-installer.ps1'
if ($LASTEXITCODE -ne 0) { throw "MoonBit installer failed with exit code $LASTEXITCODE" }

& "$env:MOON_HOME\bin\moon.exe" version --all
if ($LASTEXITCODE -ne 0) { throw "moon version failed with exit code $LASTEXITCODE" }

# Windows base images keep Path in the machine environment. Replacing it with
# Dockerfile ENV PATH can hide system tools such as powershell.exe.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
[Environment]::SetEnvironmentVariable('Path', "$env:MOON_HOME\bin;$machinePath", 'Machine')

Remove-Item 'C:\moonbit-installer.ps1'
