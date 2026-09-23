# escape=`
ARG BASE_IMAGE=mcr.microsoft.com/dotnet/framework/runtime:4.8-windowsservercore-ltsc2022
FROM ${BASE_IMAGE}

SHELL ["cmd", "/S", "/C"]
RUN curl -fSL -o C:\vs_buildtools.exe https://aka.ms/vs/17/release/vs_buildtools.exe `
    && (start /w C:\vs_buildtools.exe --quiet --wait --norestart --nocache `
        --installPath C:\BuildTools `
        --add Microsoft.VisualStudio.Workload.VCTools `
        --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        --add Microsoft.VisualStudio.Component.Windows11SDK.22621 `
        || IF "%ERRORLEVEL%"=="3010" EXIT 0) `
    && del /q C:\vs_buildtools.exe

ARG MOONBIT_VERSION=latest
ENV MOON_HOME=C:\moon
ENV MOONBIT_INSTALL_VERSION=${MOONBIT_VERSION}
COPY windows/install.ps1 C:/install.ps1
RUN powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\install.ps1
COPY windows/smoke.cmd C:/smoke.cmd
WORKDIR C:/work
CMD ["cmd.exe"]
