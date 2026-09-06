$ErrorActionPreference = 'Stop'
$flutterArguments = $args
. (Join-Path $PSScriptRoot 'dev-env.ps1')
& (Join-Path $FlutterRoot 'bin\flutter.bat') @flutterArguments
exit $LASTEXITCODE
