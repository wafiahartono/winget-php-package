Param(
  [string] $RepositoryPath = $PWD.Path,
  [switch] $CreateLinks
)

$Publisher = "PHP" ; $Package = "PHP"
$Identifier = "$Publisher.$Package"

$RepositoryPath = Resolve-Path $RepositoryPath

Function FetchResource($Identifier, $Tag, $Uri) {
  $TempPath = Join-Path ([System.IO.Path]::GetTempPath()) "BuildManifest"
  if (!(Test-Path $TempPath)) { New-Item -ItemType Directory $TempPath | Out-Null }

  $CacheInfoPath = Join-Path $TempPath "$Identifier.Cache.json"
  if (!(Test-Path $CacheInfoPath)) { New-Item -ItemType File $CacheInfoPath | Out-Null }
  $CacheInfo = (Get-Content $CacheInfoPath | ConvertFrom-Json -AsHashtable) ?? @{}
  if (!$CacheInfo.$Tag) { $CacheInfo.$Tag = @{} }

  $CachePath = Join-Path $TempPath "$Identifier.$Tag"
  if (
    ($Last = $CacheInfo.$Tag.LastCheck) -and
    (((Get-Date) - (Get-Date -UnixTimeSeconds $Last)).TotalHours -lt 1) -and
    (Test-Path $CachePath)
  ) {
    Write-Host "Resource $Identifier.$Tag cache hit"
    return Get-Content $CachePath
  }
  else {
    $Headers = @{}
    if (($ETag = $CacheInfo.$Tag.ETag) -and (Test-Path $CachePath)) {
      Write-Host "Fetching resource $Identifier.$Tag with ETag..."
      $Headers."If-None-Match" = $ETag
    }
    else {
      Write-Host "Fetching resource $Identifier.$Tag..."
    }
    try {
      $Response = Invoke-WebRequest $Uri -Headers $Headers -OutFile $CachePath -PassThru
      Write-Host "Resource $Identifier.$Tag fetched"
      if ($Etag = $Response.Headers.ETag[0]) { $CacheInfo.$Tag.ETag = $ETag }
      return $Response
    }
    catch [Microsoft.PowerShell.Commands.HttpResponseException] {
      if ($_.Exception.StatusCode -ne "NotModified") { throw $_ }
      Write-Host "Resource $Identifier.$Tag not modified since last fetch"
      return Get-Content $CachePath
    }
    finally {
      $CacheInfo.$Tag.LastCheck = [int](Get-Date -UFormat "%s")
      $CacheInfo | ConvertTo-Json | Out-File $CacheInfoPath
    }
  }
}

$Releases = FetchResource $Identifier "Releases" `
  "https://windows.php.net/downloads/releases/releases.json" | ConvertFrom-Json -AsHashtable

$Manifests = $Releases.Keys | ForEach-Object {
  $Release = $Releases.$_
  $Release.version -match "(?<Short>(?<Major>\d+)\.(?<Minor>\d+))\.\d+" | Out-Null
  $Version = @{
    Full = $Matches.0 ; Short = $Matches.Short ; Major = $Matches.Major; Minor = $Matches.Minor
  }
  return $Release.Keys | Where-Object { $_ -like "*x64" } | ForEach-Object {
    $Name = $_
    $Buildx86 = $Release.($Name -replace "x64", "x86")
    $Buildx64 = $Release.$Name
    $ThreadSafe = $Name -like "ts*"
    $InstallerBaseUrl = "https://windows.php.net/downloads/releases/"
    $Path = Join-Path $Version.Major $Version.Minor
    if ($ThreadSafe) { $Path = Join-Path $Path "TS" }
    $Path = Join-Path $Path $Version.Full
    return @{
      PackageID          = if ($ThreadSafe) { "$Identifier.$($Version.Short).TS" } else
      { "$Identifier.$($Version.Short)" }
      PackageName        = if ($ThreadSafe) { "PHP $($Version.Short) TS" } else
      { "PHP $($Version.Short)" }
      Moniker            = if ($ThreadSafe) { "php$($Version.Major)$($Version.Minor)ts" } else
      { "php$($Version.Major)$($Version.Minor)" }
      VersionFull        = $Version.Full
      VersionShort       = $Version.Short
      VersionMajor       = $Version.Major
      VersionMinor       = $Version.Minor
      ReleaseDate        = $Buildx64.mtime.ToUniversalTime().ToString("yyyy-MM-dd")
      InstallerUrlx86    = "$InstallerBaseUrl$($BuildX86.zip.path)"
      InstallerSha256x86 = $Buildx86.zip.sha256
      InstallerUrlx64    = "$InstallerBaseUrl$($Buildx64.zip.path)"
      InstallerSha256x64 = $Buildx64.zip.sha256
      _Path              = $Path
    }
  }
}

$PackagePath = Join-Path $RepositoryPath $Publisher $Package
if (!(Test-Path $PackagePath)) { New-Item -ItemType Directory $PackagePath | Out-Null }
$ManifestSpecs = @{
  Version       = @{ FileName = "template.yaml" }
  DefaultLocale = @{ FileName = "template.locale.en-US.yaml" }
  Installer     = @{ FileName = "template.installer.yaml" }
}
$ManifestSpecs.Keys | ForEach-Object {
  $ManifestSpecs.$_.Template = Get-Content -Raw `
    -Path (Join-Path $PSScriptRoot $ManifestSpecs.$_.FileName)
}
$Manifests | ForEach-Object {
  $Manifest = $_
  $ManifestPath = Join-Path $PackagePath $Manifest._Path
  if (!(Test-Path $ManifestPath)) { New-Item -ItemType Directory $ManifestPath | Out-Null }
  $ManifestSpecs.Keys | ForEach-Object {
    $Spec = $ManifestSpecs.$_
    $Content = $Spec.Template
    $Manifest.Keys | Where-Object { $_ -notlike "_*" } | ForEach-Object {
      $Content = $Content -replace "\`$$_", $Manifest.$_
    }
    $FileName = $Spec.FileName -replace "template", $Manifest.PackageID
    $Content | Out-File (Join-Path $ManifestPath $FileName) -NoNewline
  }

  if ($CreateLinks) {
    New-Item -ItemType Junction $Manifest.PackageID -Target $ManifestPath -Force | Out-Null
  }
}
