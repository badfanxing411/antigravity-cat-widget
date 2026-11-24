param([switch]$Supervisor)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'supervisor-task.ps1')
. (Join-Path $PSScriptRoot 'agent-common.ps1')
try {
  $binding=Read-WidgetJsonFile (Join-Path $PSScriptRoot 'binding.json')
  if(!$binding -or !$binding.appDir -or !(Test-Path -LiteralPath $binding.appDir)){throw 'Launcher binding missing or app directory not found.'}
  if($Supervisor){& (Join-Path $binding.appDir 'runtime\supervisor.ps1')}
  else {& (Join-Path $binding.appDir 'runtime\start-supervisor.ps1')}
} catch {
  [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'launcher-diagnostic.txt'),$_.Exception.ToString(),[Text.UTF8Encoding]::new($false))
  exit 1
}
