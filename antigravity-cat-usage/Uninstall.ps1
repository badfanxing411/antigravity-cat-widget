$ErrorActionPreference='Stop'
$appDir=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
. (Join-Path $appDir 'runtime\agent-common.ps1')
. (Join-Path $appDir 'runtime\supervisor-task.ps1')

$configPath=Join-Path $appDir 'installation.json'
if(!(Test-Path -LiteralPath $configPath)){
  Write-Output '未找到 installation.json，挂件尚未安装或已被停用。'
  return
}
$config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json
$null=Unregister-WidgetSupervisorTask -AppDir $appDir
Stop-WidgetGui -AppDir $appDir -DataDir $config.dataDir
if($config.startupShortcut -and (Test-Path -LiteralPath $config.startupShortcut)){
  Remove-Item -LiteralPath $config.startupShortcut -Force -ErrorAction SilentlyContinue
}
$config|Add-Member -NotePropertyName disabledAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
Write-WidgetSupervisorJson $configPath $config
Write-Output '星猫额度挂件已停用。程序文件与个人设置（语录、角色、音效）已保留。'
