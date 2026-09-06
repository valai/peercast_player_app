# Dot-source: . .\scripts\dev-env.ps1
param(
    [string]$FlutterRoot = 'C:\develop\sdks\flutter',
    [string]$JavaRoot = 'C:\develop\sdks\jdk-17.0.20.1+1',
    [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk"
)
$ErrorActionPreference = 'Stop'
foreach ($file in @("$FlutterRoot\bin\flutter.bat", "$JavaRoot\bin\java.exe", "$AndroidSdk\platform-tools\adb.exe")) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing development tool: $file" }
}
$env:JAVA_HOME = $JavaRoot
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk
$env:PATH = "$FlutterRoot\bin;$JavaRoot\bin;$AndroidSdk\platform-tools;$AndroidSdk\cmdline-tools\latest\bin;$env:PATH"
Write-Host "Flutter: $FlutterRoot"
Write-Host "Java: $JavaRoot"
Write-Host "Android: $AndroidSdk"
