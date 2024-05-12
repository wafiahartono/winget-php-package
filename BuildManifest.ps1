[CmdletBinding(PositionalBinding = $false)]

Param(
  [Parameter(Position = 0)]
  [string] $Package = "PHP.PHP",
  [string] $OutDir = "manifests",
  [switch] $CreateLinks
)

Function FetchResource($Group, $Tag, $Uri) {
  $TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "BuildManifest"
  if (!(Test-Path $TempDir)) { New-Item -ItemType Directory $TempDir | Out-Null }

  $CacheInfoPath = Join-Path $TempDir "$Group.CacheInfo.json"
  if (!(Test-Path $CacheInfoPath)) { New-Item -ItemType File $CacheInfoPath | Out-Null }
  $CacheInfo = (Get-Content $CacheInfoPath | ConvertFrom-Json -AsHashtable) ?? @{}
  if (!$CacheInfo.$Tag) { $CacheInfo.$Tag = @{} }

  $CachePath = Join-Path $TempDir "$Group`_$Tag.cache"
  if (
    ($LastCheck = $CacheInfo.$Tag.LastCheck) -and
    (((Get-Date) - (Get-Date -UnixTimeSeconds $LastCheck)).TotalHours -lt 1) -and
    (Test-Path $CachePath)
  ) {
    Write-Verbose "Resource $Group`:$Tag cache hit"
    return Get-Content $CachePath
  }
  else {
    Write-Verbose "Resource $Group`:$Tag cache miss. Fetching..."
    $Headers = @{}
    if (($ETag = $CacheInfo.$Tag.ETag) -and (Test-Path $CachePath)) {
      Write-Verbose "Resource $Group`:$Tag ETag: $ETag"
      $Headers."If-None-Match" = $ETag
    }
    try {
      $Response = Invoke-WebRequest $Uri -Headers $Headers -OutFile $CachePath -PassThru
      Write-Verbose "Resource $Group`:$Tag fetched"
      if ($Etag = $Response.Headers.ETag) { $CacheInfo.$Tag.ETag = "$ETag" }
      return $Response.Content
    }
    catch [Microsoft.PowerShell.Commands.HttpResponseException] {
      if ($_.Exception.StatusCode -eq "NotModified") {
        Write-Verbose "Resource $Group`:$Tag not modified since last fetch"
        return Get-Content $CachePath
      }
      throw $_
    }
    finally {
      $CacheInfo.$Tag.LastCheck = [int](Get-Date -UFormat "%s")
      $CacheInfo | ConvertTo-Json | Out-File $CacheInfoPath
    }
  }
}

$Releases = FetchResource -Group $Package -Tag "Releases" `
  -Uri "https://windows.php.net/downloads/releases/releases.json" | ConvertFrom-Json -AsHashtable

$Manifests = $Releases.Keys | ForEach-Object {
  $Release = $Releases.$_
  $Release.version -match "(?<Short>(?<Major>\d+)\.(?<Minor>\d+))\.\d+" | Out-Null
  $Version = @{
    Full = $Matches.0 ; Short = $Matches.Short ; Major = $Matches.Major; Minor = $Matches.Minor
  }
  return $Release.Keys | Where-Object { $_ -like "*x64" } | Sort-Object | ForEach-Object {
    $BuildName = $_
    $Buildx86 = $Release.($BuildName -replace "x64", "x86")
    $Buildx64 = $Release.$BuildName
    $IsThreadSafe = $BuildName -like "ts*"
    $InstallerBaseUrl = "https://windows.php.net/downloads/releases/"
    $ManifestPath = Join-Path -Path $Version.Major -ChildPath $Version.Minor `
      -AdditionalChildPath  @(`
        if ($IsThreadSafe) { "TS" } else { $null }, `
        $Version.Full
    )
    return @{
      PackageID          = `
        "$Package.$($Version.Short)" + $(if ($IsThreadSafe) { ".TS" } else { "" })
      PackageName        = `
        "PHP $($Version.Short)" + $(if ($IsThreadSafe) { " TS" } else { "" })
      Moniker            = `
        "php$($Version.Major)$($Version.Minor)" + $(if ($IsThreadSafe) { "ts" } else { "" })
      VersionFull        = $Version.Full
      VersionMajor       = $Version.Major
      VersionMinor       = $Version.Minor
      ReleaseDate        = $Buildx64.mtime.ToUniversalTime().ToString("yyyy-MM-dd")
      InstallerUrlx86    = "$InstallerBaseUrl$($BuildX86.zip.path)"
      InstallerSha256x86 = $Buildx86.zip.sha256
      InstallerUrlx64    = "$InstallerBaseUrl$($Buildx64.zip.path)"
      InstallerSha256x64 = $Buildx64.zip.sha256
      _ManifestPath      = $ManifestPath
    }
  }
}
Write-Verbose "Found $($Manifests.Length) manifests"

if (!(Test-Path $OutDir)) { New-Item -ItemType Directory $OutDir | Out-Null }
$OutDir = Resolve-Path $OutDir
$ManifestTemplates = @{
  Version       = @{ FileName = "template.yaml" }
  DefaultLocale = @{ FileName = "template.locale.en-US.yaml" }
  Installer     = @{ FileName = "template.installer.yaml" }
}
$ManifestTemplates.Keys | ForEach-Object {
  $ManifestTemplates.$_.Content = Get-Content -Raw `
    -Path (Join-Path $PSScriptRoot "templates" $ManifestTemplates.$_.FileName)
}

$Manifests |
ForEach-Object {
  $Manifest = $_
  $ManifestPath = Join-Path $OutDir $Manifest._ManifestPath
  $ManifestParentPath = Split-Path $ManifestPath
  if (!(Test-Path $ManifestParentPath)) { return }

  $LastVersion =
  Get-ChildItem -Directory $ManifestParentPath -Name |
  Where-Object { $_ -ne "TS" -and $_ -ne $Manifest.VersionFull } |
  ForEach-Object {
    $_ -match "(?<Major>\d+)\.(?<Minor>\d+)\.(?<Patch>\d+)" | Out-Null
    return @{
      Version = $_
      Score   = [int]$Matches.Major * 1000 + [int]$Matches.Minor * 100 + [int]$Matches.Patch
    }
  } |
  Sort-Object Score |
  Select-Object -Last 1 -ExpandProperty Version
  if (!$LastVersion) { return }

  Write-Verbose "Updating previous manifest for $($Manifest.PackageID) version $LastVersion"
  $ManifestPath = Join-Path $ManifestParentPath $LastVersion
  $FileName = $ManifestTemplates.Installer.FileName -replace "template", $Manifest.PackageID
  $Content = (Get-Content -Raw (Join-Path $ManifestPath $FileName)) `
    -replace [regex]::Escape("https://windows.php.net/downloads/releases/"), `
    "https://windows.php.net/downloads/releases/archives/"
  $Content | Out-File (Join-Path $ManifestPath $FileName) -NoNewline
}

$Manifests | ForEach-Object {
  $Manifest = $_
  $ManifestPath = Join-Path $OutDir $Manifest._ManifestPath
  if (!(Test-Path $ManifestPath)) {
    Write-Host "Upgrade available for $($Manifest.PackageID): " -NoNewline
    Write-Host $Manifest.VersionFull -ForegroundColor Green
    New-Item -ItemType Directory $ManifestPath | Out-Null
  }
  $ManifestTemplates.Keys | ForEach-Object {
    $Template = $ManifestTemplates.$_
    $Content = $Template.Content
    $Manifest.Keys | Where-Object { $_ -notlike "_*" } | ForEach-Object {
      $Content = $Content -replace "\`$$_", $Manifest.$_
    }
    $FileName = $Template.FileName -replace "template", $Manifest.PackageID
    $Content | Out-File (Join-Path $ManifestPath $FileName) -NoNewline
  }

  if ($CreateLinks) {
    New-Item -ItemType Junction $Manifest.PackageID -Target $ManifestPath -Force | Out-Null
  }
}
