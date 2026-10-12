# Build a modified 7-Zip installer for Windows 11.
# This script does not download, install, register, or replace software.
[CmdletBinding()]
param(
    [ValidateSet('x64')]
    [string]$Architecture = 'x64',

    [string]$VisualStudioPath,

    # Optional override; defaults to the Lang directory beside this script.
    [string]$LanguageDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourceRoot = $PSScriptRoot
$initialEnvironment = @{}
Get-ChildItem Env: | ForEach-Object { $initialEnvironment[$_.Name] = $_.Value }

function Set-VsEnvironment {
    param([Parameter(Mandatory = $true)][string]$Target)

    # Start each architecture from the same caller environment.
    Get-ChildItem Env: | ForEach-Object {
        if (-not $initialEnvironment.ContainsKey($_.Name)) {
            [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process')
        }
    }
    foreach ($name in $initialEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $initialEnvironment[$name], 'Process')
    }
    $targetArg = if ($Target -eq 'x86') { 'amd64_x86' } else { 'amd64' }
    $command = 'call "{0}" {1} >nul && set' -f $script:vcvars, $targetArg
    $lines = @(& $env:ComSpec /d /s /c $command)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to initialize Visual Studio compiler environment for $Target."
    }
    foreach ($line in $lines) {
        $equals = $line.IndexOf('=')
        if ($equals -gt 0) {
            [Environment]::SetEnvironmentVariable($line.Substring(0, $equals), $line.Substring($equals + 1), 'Process')
        }
    }
    if ($env:VSCMD_ARG_TGT_ARCH -ne $Target) {
        throw "Visual Studio compiler target does not match $Target."
    }
}

function Invoke-NMakeProject {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$BuildName,
        [Parameter(Mandatory = $true)][string]$TargetArch,
        [string[]]$Definitions = @()
    )

    Set-VsEnvironment -Target $TargetArch
    foreach ($tool in @('cl.exe', 'link.exe', 'nmake.exe', 'rc.exe')) {
        if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "Required Visual Studio tool missing: $tool"
        }
    }
    if ($TargetArch -eq 'x64' -and -not (Get-Command 'ml64.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'ml64.exe is missing. Install the MSVC x64/x86 build tools.'
    }
    if ($TargetArch -eq 'x86' -and -not (Get-Command 'ml.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'ml.exe is missing. Install the MSVC x64/x86 build tools.'
    }

    $projectPath = Join-Path $sourceRoot $Directory
    if (-not (Test-Path -LiteralPath (Join-Path $projectPath 'makefile') -PathType Leaf)) {
        throw "Project makefile missing: $projectPath"
    }

    $buildName = "$BuildName-$TargetArch"
    $buildPath = Join-Path $script:buildRoot $buildName
    $tempPath = Join-Path $buildPath 'temp'
    New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
    $savedTemp = $env:TEMP
    $savedTmp = $env:TMP
    # C makefiles are three directories below the repository root; CPP makefiles are four.
    $relativeOutput = if ($Directory.StartsWith('C\')) {
        "..\..\..\build\win11-$Architecture\$buildName"
    } else {
        "..\..\..\..\build\win11-$Architecture\$buildName"
    }
    $makeArgs = @('/nologo', '/B', '/f', 'makefile', "PLATFORM=$TargetArch", "O=$relativeOutput", 'CC=cl', "CFLAGS_COMMON=/Fd$relativeOutput\compiler.pdb") + $Definitions

    Write-Host "Building $BuildName for $TargetArch..."
    Push-Location -LiteralPath $projectPath
    try {
        $env:TEMP = $tempPath
        $env:TMP = $tempPath
        & nmake.exe @makeArgs | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Build failed for $BuildName ($TargetArch), exit code $LASTEXITCODE."
        }
    }
    finally {
        $env:TEMP = $savedTemp
        $env:TMP = $savedTmp
        Pop-Location
    }

    $programLine = [string](Get-Content -LiteralPath (Join-Path $projectPath 'makefile') -TotalCount 1)
    $programName = ($programLine -replace '^PROG\s*=\s*', '').Trim()
    $outputFile = Join-Path $buildPath ([IO.Path]::GetFileName($programName))
    if (-not (Test-Path -LiteralPath $outputFile -PathType Leaf)) {
        throw "Expected build output not found: $outputFile"
    }
    return $outputFile
}

function Add-FileToInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$Stub,
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $output = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        foreach ($source in @($Stub, $Archive)) {
            $sourceStream = [IO.File]::OpenRead($source)
            try { $sourceStream.CopyTo($output) } finally { $sourceStream.Dispose() }
        }
    }
    finally {
        $output.Dispose()
    }
}

try {
    if (-not $VisualStudioPath) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
            throw 'Visual Studio discovery tool not found. Install VS 2022 Build Tools with Desktop development with C++, or specify -VisualStudioPath.'
        }
        $installations = @(& $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
        if ($LASTEXITCODE -ne 0 -or $installations.Count -eq 0) {
            throw 'Visual Studio 2022 C++ tools not found. Install Desktop development with C++, including the Windows 11 SDK.'
        }
        $VisualStudioPath = [string]$installations[0]
    }

    $script:vcvars = Join-Path $VisualStudioPath 'VC\Auxiliary\Build\vcvarsall.bat'
    if (-not (Test-Path -LiteralPath $script:vcvars -PathType Leaf)) {
        throw "Compiler environment script not found: $script:vcvars"
    }

    $script:buildRoot = Join-Path $sourceRoot "build\win11-$Architecture"
    $outputDirectory = Join-Path $sourceRoot "dist\win11-$Architecture"
    $packageRoot = Join-Path $script:buildRoot ('Package-' + [guid]::NewGuid().ToString('N'))
    $payloadDirectory = Join-Path $packageRoot 'Payload'
    New-Item -ItemType Directory -Path $script:buildRoot, $outputDirectory, $payloadDirectory -Force | Out-Null

    $built = @{}
    $built['7z.dll'] = Invoke-NMakeProject 'CPP\7zip\Bundles\Format7zF' 'Format7zF' 'x64' @()
    $built['7zG.exe'] = Invoke-NMakeProject 'CPP\7zip\UI\GUI' 'GUI' 'x64' @()
    $built['7zFM.exe'] = Invoke-NMakeProject 'CPP\7zip\Bundles\Fm' 'Fm' 'x64' @()
    $built['7z.exe'] = Invoke-NMakeProject 'CPP\7zip\UI\Console' 'Console' 'x64' @()
    $built['7-zip.dll'] = Invoke-NMakeProject 'CPP\7zip\UI\Explorer' 'Explorer' 'x64' @()
    $built['7-zip32.dll'] = Invoke-NMakeProject 'CPP\7zip\UI\Explorer' 'Explorer' 'x86' @()
    $built['Uninstall.exe'] = Invoke-NMakeProject 'C\Util\7zipUninstall' 'Uninstall' 'x64' @()
    $built['7zipInstall.exe'] = Invoke-NMakeProject 'C\Util\7zipInstall' 'Installer' 'x64' @('Z7_64BIT_INSTALLER=1', 'LIBS=oleaut32.lib ole32.lib user32.lib advapi32.lib shell32.lib uuid.lib')

    foreach ($name in @('7z.dll', '7zG.exe', '7zFM.exe', '7z.exe', '7-zip.dll', '7-zip32.dll', 'Uninstall.exe')) {
        Copy-Item -LiteralPath $built[$name] -Destination (Join-Path $payloadDirectory $name) -Force
        Copy-Item -LiteralPath $built[$name] -Destination $outputDirectory -Force
    }

    if (-not $LanguageDirectory) {
        $LanguageDirectory = Join-Path $sourceRoot 'Lang'
    }
    $languageSource = Join-Path $LanguageDirectory 'zh-cn.txt'
    if (-not (Test-Path -LiteralPath $languageSource -PathType Leaf)) {
        throw "Simplified Chinese language file not found: $languageSource"
    }
    $payloadLang = Join-Path $payloadDirectory 'Lang'
    $outputLang = Join-Path $outputDirectory 'Lang'
    New-Item -ItemType Directory -Path $payloadLang, $outputLang -Force | Out-Null
    Get-ChildItem -LiteralPath $LanguageDirectory -Filter '*.txt' -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $payloadLang -Force
        Copy-Item -LiteralPath $_.FullName -Destination $outputLang -Force
    }

    foreach ($license in @('License.txt', 'unRarLicense.txt')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot "DOC\$license") -Destination $payloadDirectory -Force
    }
    if ($LanguageDirectory) {
        $helpSource = Join-Path (Split-Path -Parent $LanguageDirectory) '7-zip.chm'
        if (Test-Path -LiteralPath $helpSource -PathType Leaf) {
            Copy-Item -LiteralPath $helpSource -Destination $payloadDirectory -Force
        }
    }

    # The console program loads 7z.dll from its own directory.
    $archiver = Join-Path $outputDirectory '7z.exe'
    $archivePath = Join-Path $packageRoot 'InstallerPayload.7z'
    Push-Location -LiteralPath $payloadDirectory
    try {
        # The native installer supports LZMA, not LZMA2 or arbitrary filters.
        & $archiver a -t7z -m0=LZMA -mx=9 -mf=off -mhc=off $archivePath '*'
        if ($LASTEXITCODE -ne 0) { throw "Creating installer archive failed, exit code $LASTEXITCODE." }
    }
    finally {
        Pop-Location
    }

    $setupPath = Join-Path $outputDirectory '7z-26.04-x64-setup.exe'
    Add-FileToInstaller -Stub $built['7zipInstall.exe'] -Archive $archivePath -Destination $setupPath
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'DOC\License.txt') -Destination $outputDirectory -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'DOC\unRarLicense.txt') -Destination $outputDirectory -Force

    Write-Host "Installer created: $setupPath"
    Write-Host 'Run the setup executable as administrator to replace the installed 7-Zip and register the updated Explorer menu.'
    Write-Host "Language files included from: $LanguageDirectory"
    Write-Host "Intermediate files are kept under: $script:buildRoot"
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
