param(
  [switch]$CheckOnly,
  [switch]$PatchDesktopShortcut,
  [switch]$SkipShortcutPatch
)
$ErrorActionPreference='Stop'
$appDir=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
. (Join-Path $appDir 'runtime\agent-common.ps1')
. (Join-Path $appDir 'runtime\supervisor-task.ps1')

$localData=Get-WidgetLocalApplicationData
if(!$localData){throw 'Local application data folder unavailable.'}
$dataDir=Join-Path $localData 'AntigravityCatUsage\state'
$nodeCommand=Get-Command node.exe -ErrorAction SilentlyContinue
if(!$nodeCommand){throw '需要 Node.js 20 或更高版本。请先从 https://nodejs.org/ 安装 Node.js 后再运行安装脚本。'}
$node=$nodeCommand.Source
$nodeMajor=[int]((& $node --version).TrimStart('v').Split('.')[0])
if($nodeMajor-lt 20){throw "当前 Node.js 版本过低（v$nodeMajor），需要 Node.js 20 或更高版本。请访问 https://nodejs.org/ 升级。"}

$pkg=Read-WidgetJsonFile (Join-Path $appDir 'package.json')
$version=if($pkg -and $pkg.version){[string]$pkg.version}else{'1.0.0'}
$startup=Get-WidgetKnownFolderPath ([Guid]'B97D20BB-F46A-4C97-BA10-5E3608430854')
$shortcut=Join-Path $startup 'Antigravity Cat Usage.lnk'
$launcherDir=Get-WidgetLauncherDir

$config=@{
  version=$version
  appDir=$appDir
  dataDir=$dataDir
  nodePath=$node
  startupShortcut=$shortcut
  launcherDir=$launcherDir
  installedAt=[DateTime]::UtcNow.ToString('o')
}

if($CheckOnly){
  @{ok=$true;version=$version;appDir=$appDir;dataDir=$dataDir;nodePath=$node;startupShortcut=$shortcut}|ConvertTo-Json
  return
}

$null=New-Item -ItemType Directory -Path $dataDir -Force
try{Stop-WidgetSupervisorTask -AppDir $appDir -Configuration $config}catch{}
try{Stop-WidgetGui -AppDir $appDir -DataDir $dataDir}catch{}
Install-WidgetLauncher -AppDir $appDir -DataDir $dataDir
Write-WidgetSupervisorJson (Join-Path $appDir 'installation.json') $config

$link=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
$link.TargetPath=Join-Path $env:WINDIR 'System32\conhost.exe'
$link.Arguments=Get-WidgetAgentPowerShellArguments $launcherDir
$link.WorkingDirectory=Join-Path $env:WINDIR 'System32'
$link.WindowStyle=7
$link.Description='Antigravity Cat: Gemini subscription quota widget'
$link.Save()

$task=Register-WidgetSupervisorTask -AppDir $appDir
Write-Output ("星猫额度挂件 v$version 安装完成！守护任务已启动：$($task.TaskName)")

$shortcutHelper=Join-Path $appDir 'Configure-Shortcut.ps1'
if(!$SkipShortcutPatch -and (Test-Path -LiteralPath $shortcutHelper)){
  $shouldPatch=$PatchDesktopShortcut
  if(!$shouldPatch -and [Environment]::UserInteractive){
    try{
      $statusLines=@(& $shortcutHelper -Action Status 2>$null)
      $needsPatch=@($statusLines|Where-Object{$_ -match '已开启额度接口：False'})
      if($needsPatch.Count -gt 0){
        Write-Output ''
        Write-Output '检测到桌面上的 Antigravity 快捷方式尚未开启本机额度接口参数（--remote-debugging-port=0）。'
        $ans=Read-Host '是否自动为桌面 Antigravity 快捷方式添加该参数，以便直接点桌面图标读取实时额度？[Y/n]'
        if(!$ans -or $ans.Trim() -match '^(y|yes)$'){$shouldPatch=$true}
      }
    }catch{}
  }
  if($shouldPatch){
    try{& $shortcutHelper -Action Enable}catch{Write-Warning $_.Exception.Message}
  }
}

Write-Output ''
Write-Output '使用提示：若 Antigravity 当前已打开，请完全退出后重新启动，星猫即可自动出现并读取实时额度。'
