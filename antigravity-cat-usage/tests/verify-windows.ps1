$ErrorActionPreference = 'Stop'
$app = Split-Path $PSScriptRoot -Parent
Write-Host "=== Antigravity Cat Widget Windows Verification ==="

# 1. PowerShell AST syntax check
$errors = @()
Get-ChildItem $app -Recurse -Filter *.ps1 | ForEach-Object {
  $t = $null; $e = $null
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e) | Out-Null
  foreach ($err in $e) { $errors += "PS1 [$($_.Name)]: $($err.Message) L$($err.Extent.StartLineNumber)" }
}

# 2. JSON check
Get-ChildItem $app -Recurse -Filter *.json | Where-Object { $_.FullName -notmatch 'vendor' } | ForEach-Object {
  try { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json | Out-Null }
  catch { $errors += "JSON [$($_.Name)]: $($_.Exception.Message)" }
}

# 3. Node.js syntax check
Get-ChildItem "$app\runtime" -Filter *.mjs | ForEach-Object {
  $out = & node --check $_.FullName 2>&1
  if ($LASTEXITCODE -ne 0) { $errors += "MJS [$($_.Name)]: $out" }
}

# 4. Audio WAV validation
. "$app\runtime\audio.ps1"
Get-ChildItem "$app\assets\sounds\*.wav" | ForEach-Object {
  try { $null = Read-WidgetPcmWave $_.FullName }
  catch { $errors += "WAV [$($_.Name)]: $($_.Exception.Message)" }
}

# 5. Music C# compilation
$script:appDir = $app
. "$app\runtime\music.ps1"
try { Initialize-WidgetMusicTypes }
catch { $errors += "Music CS: $($_.Exception.Message)" }

# 6. Install -CheckOnly
try {
  $chk = & "$app\Install.ps1" -CheckOnly | ConvertFrom-Json
  if (!$chk.ok) { $errors += "Install -CheckOnly returned ok=false" }
} catch { $errors += "Install -CheckOnly: $($_.Exception.Message)" }

# 7. Isolated WPF CheckOnly + All quotes bubble-fit test
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('agy-cat-test-' + [Guid]::NewGuid().ToString('N'))
$instPath = Join-Path $app 'installation.json'
$hadInst = Test-Path -LiteralPath $instPath
$backupInst = if ($hadInst) { [IO.File]::ReadAllBytes($instPath) } else { $null }
try {
  $null = New-Item -ItemType Directory -Path $tmpDir -Force
  $nodePath = (Get-Command node.exe -ErrorAction Stop).Source
  @{ version='1.0.0'; appDir=$app; dataDir=$tmpDir; nodePath=$nodePath } | ConvertTo-Json | Set-Content -LiteralPath $instPath -Encoding UTF8

  $wChk = powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "$app\widget.ps1" -CheckOnly | ConvertFrom-Json
  if (!$wChk.ok -or !$wChk.imageLoaded) { $errors += "widget.ps1 -CheckOnly failed" }
  if ($wChk.bubbleTapAdvance -ne $false) { $errors += "Expected bubbleTapAdvance=false by default" }
  if ($wChk.showUsageInBubble -ne $false) { $errors += "Expected showUsageInBubble=false by default" }

  Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
  . "$app\runtime\quotes.ps1"
  . "$app\runtime\quote-layout.ps1"
  $script:appDir = $app; $script:dataDir = $tmpDir
  Initialize-WidgetQuoteLayouts $app
  $win = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $app 'widget.xaml'), [Text.Encoding]::UTF8))
  $script:ui = @{ QuoteText = $win.FindName('QuoteText') }
  $qs = Get-WidgetQuoteSettings $tmpDir
  foreach ($q in $qs.quotes) {
    $script:ui.QuoteText.Text = $q.text
    Fit-QuoteText
    if ($script:ui.QuoteText.Text -eq '…') { $errors += "Quote overflow: $($q.text)" }
  }
  Write-Host ("Verified WPF startup and all {0} built-in quotes!" -f $qs.quotes.Count)
} finally {
  if ($hadInst) { [IO.File]::WriteAllBytes($instPath, $backupInst) }
  elseif (Test-Path -LiteralPath $instPath) { Remove-Item -LiteralPath $instPath -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($errors.Count -gt 0) {
  Write-Host "VERIFICATION FAILED:" -ForegroundColor Red
  $errors | ForEach-Object { Write-Host "  - $_" }
  exit 1
}
Write-Host "ALL WINDOWS VERIFICATIONS PASSED!"
