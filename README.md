# Windows Package Manager PHP Repository

This repository hosts PHP package manifests for the Windows Package Manager (winget).
It contains PHP package manifests and a PowerShell script to automate manifest building.

> PHP binaries are sourced from [windows.php.net](https://windows.php.net/).

## Usage

### Installing PHP Package

Before installing packages from local manifest files, enable the `LocalManifestFiles` winget setting by running `winget settings --enable LocalManifestFiles` in an elevated session.

> Enabling this setting may pose security risks.[*](https://learn.microsoft.com/en-us/windows/package-manager/winget/install#local-install)

To install a PHP package, execute the following command within this repository's root directory:

```powershell
winget install --manifest PHP\PHP\8\3\8.3.6   # Installs PHP version 8.3.6
```

The `--manifest` parameter accepts a path to the directory containing the package manifest files.

>The installation process may take a relatively long time. This delay can be caused by winget performing a malware scan for archive-type packages installed from local manifests. To disable malware scanning during local manifest installations, use the `--ignore-local-archive-malware-scan` parameter with the `winget install` command. **Use with caution**.

Alternatively, create a junction that points to the latest version of a package manifest to simplify the installation command:

```powershell
New-Item -ItemType Junction PHP.PHP.8.3 -Target (Resolve-Path .\PHP\PHP\8\3\8.3.6\)
```

Then, install the package as follows:

```powershell
winget install --manifest PHP.PHP.8.3
```

> Manually creating multiple junctions for many packages can be cumbersome. The `BuildManifest.ps1` script automates this task using the `-CreateLinks` parameter.

### Building PHP Package Manifests

> Requires PowerShell 7+.

The `BuildManifest.ps1` PowerShell script, located in the `BuildManifest\PHP.PHP` folder, provides a functionality to automatically build PHP package manifests.

This script retrieves PHP release information from [windows.php.net](https://windows.php.net/downloads/releases/releases.json) including supported PHP versions, binary download links, and corresponding SHA256 checksums.

The script uses template manifest files (`BuildManifest\PHP.PHP\template*.yaml`) to build the manifests by substituting placeholders (prefixed by `$`) with the correct values obtained from the release information.

To use the script, call it in a PowerShell session from the root of this repository.

```powershell
.\BuildManifest\PHP.PHP\BuildManifest.ps1
```
##### Parameters

###### `-RepositoryPath`

Optional parameter to specify the repository root path. Defaults to the current working directory.

###### `-CreateLinks`

Optional parameter to create junctions for the latest version of the package manifests, named with the package ID. The junctions will be placed in the `-RepositoryPath` and replaces existing junction.

> Currently, this parameter cannot be used separately. Calling the script with this parameter will also build package manifests, thus replacing any existing manifest files.

#### TS (Thread Safe) and NTS (Non-Thread Safe) Build

> For more information about the difference between TS and NTS build, refer to [windows.php.net](https://windows.php.net/).

NTS builds are placed under the default identifier (without "NTS"), while TS builds include a "TS" accessory.

```
Entity          Value                  Build
-----------------------------------------------
Directory       PHP\PHP\8\3\8.3.6      NTS
Directory       PHP\PHP\8\3\TS\8.3.6   TS

Package ID      PHP.PHP.8.3            NTS
Package ID      PHP.PHP.8.3.TS         TS

Command alias   php83                  NTS
Command alias   php83ts                TS
```

## Limitations

This repository only provides manifests for the latest supported version of PHP at the time of creation and doesn't include older releases.

The installer download links for the binaries will stop working when a new version becomes available. This occurs on the provider server.
