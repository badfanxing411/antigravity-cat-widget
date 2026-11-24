param(
  [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$appDir = Join-Path $projectRoot 'antigravity-cat-usage'
$pkg = [IO.File]::ReadAllText((Join-Path $appDir 'package.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$version = [string]$pkg.version
if (!$version) { $version = '1.0.0' }

if (!$OutDir) { $OutDir = Join-Path $projectRoot 'dist' }
$null = New-Item -ItemType Directory -Path $OutDir -Force

$bundleName = "antigravity-cat-widget-v$version-windows"
$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ("agy-cat-stage-" + [Guid]::NewGuid().ToString('N'))
$stageDir = Join-Path $stageRoot $bundleName
$zipPath = Join-Path $OutDir ($bundleName + '.zip')
$shaPath = Join-Path $OutDir 'SHA256SUMS.txt'

# Files excluded from distributable release archives (machine-local state & dev outputs)
$excludeNames = @(
  'installation.json', 'settings.json', 'runtime.json', 'presence.json',
  'status.json', 'ledger.json', 'preview.png', 'Thumbs.db', '.DS_Store', 'Desktop.ini'
)
$excludeDirs = @('dist', '.git', '.test-state', 'node_modules')

try {
  $null = New-Item -ItemType Directory -Path $stageDir -Force
  $rootFiles = Get-ChildItem -LiteralPath $projectRoot -Force
  foreach ($entry in $rootFiles) {
    if ($entry.PSIsContainer) {
      if ($excludeDirs -contains $entry.Name) { continue }
      $destSub = Join-Path $stageDir $entry.Name
      $null = New-Item -ItemType Directory -Path $destSub -Force
      Get-ChildItem -LiteralPath $entry.FullName -Recurse -Force | ForEach-Object {
        $rel = $_.FullName.Substring($entry.FullName.Length).TrimStart('\')
        $parts = $rel -split '\\'
        if (($parts | Where-Object { $excludeDirs -contains $_ }).Count -gt 0) { return }
        if (!$_.PSIsContainer) {
          if ($excludeNames -contains $_.Name -or $_.Name -like '*-status.json' -or $_.Name -like '*-error.txt' -or $_.Extension -in @('.flag','.tmp','.bak','.zip')) { return }
          $target = Join-Path $destSub $rel
          $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
          Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
      }
    } else {
      if ($excludeNames -contains $entry.Name -or $entry.Extension -in @('.zip','.tmp','.bak')) { continue }
      Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $stageDir $entry.Name) -Force
    }
  }

  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($stageRoot, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)

  $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $line = "$hash  $([IO.Path]::GetFileName($zipPath))"
  [IO.File]::WriteAllText($shaPath, $line + "`n", [Text.UTF8Encoding]::new($false))

  $sizeMb = [Math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
  Write-Output "打包完成！"
  Write-Output "压缩包：$zipPath ($sizeMb MB)"
  Write-Output "SHA256：$hash"
  Write-Output "校验文件：$shaPath"
} finally {
  if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
