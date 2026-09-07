$ErrorActionPreference = 'Stop'
$nativeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../native'))
$dependencies = Get-Content (Join-Path $nativeRoot 'dependencies.json') -Raw | ConvertFrom-Json
foreach ($dependency in @($dependencies.peercast, $dependencies.tls)) {
    $destination = Join-Path $nativeRoot $dependency.directory
    if (-not (Test-Path $destination)) {
        & git clone --no-checkout --filter=blob:none $dependency.url $destination
        if ($LASTEXITCODE -ne 0) { throw 'Source checkout failed' }
        & git -C $destination fetch --depth 1 origin $dependency.revision
        if ($LASTEXITCODE -ne 0) { throw 'Pinned revision fetch failed' }
        & git -C $destination checkout --detach $dependency.revision
        if ($LASTEXITCODE -ne 0) { throw 'Pinned checkout failed' }
    }
    $actual = & git -C $destination rev-parse HEAD
    if ($actual -ne $dependency.revision) { throw "Unexpected revision in $destination. Existing checkout was not changed." }
    $changes = & git -C $destination status --porcelain
    if ($changes) { throw "Local changes in $destination. Existing checkout was not changed." }
    Write-Output "$($dependency.directory): $actual"
}
