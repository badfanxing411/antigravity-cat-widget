function Get-WidgetAgentPowerShellArguments([string]$AgentDir){
  $powerShell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $scriptFile=Join-Path ([IO.Path]::GetFullPath($AgentDir)) 'agent-launcher.ps1'
  return ('--headless "'+$powerShell+'" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$scriptFile+'" -Supervisor')
}

function Stop-WidgetGui {
  param([Parameter(Mandatory=$true)][string]$AppDir,[Parameter(Mandatory=$true)][string]$DataDir)
  $null=New-Item -ItemType Directory -Path $DataDir -Force
  $stopFile=Join-Path $DataDir 'stop.flag'
  $runtime=$null
  try{$runtime=Get-Content -LiteralPath (Join-Path $DataDir 'runtime.json') -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
  $guiPid=0
  if(!$runtime -or ![int]::TryParse([string]$runtime.pid,[ref]$guiPid) -or $guiPid-le 0){
    $expectedStart='"'+(Join-Path $AppDir 'runtime\start-widget.ps1')+'"'
    $expectedWidget='"'+(Join-Path $AppDir 'widget.ps1')+'"'
    $launching=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue|Where-Object{
      $_.ProcessId-ne $PID -and [string]$_.CommandLine -and ($_.CommandLine.IndexOf($expectedStart,[StringComparison]::OrdinalIgnoreCase)-ge 0 -or $_.CommandLine.IndexOf($expectedWidget,[StringComparison]::OrdinalIgnoreCase)-ge 0)
    })
    if(!$launching.Count){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
    [IO.File]::WriteAllText($stopFile,'stop')
    $deadline=[DateTime]::UtcNow.AddSeconds(6)
    do{
      $alive=@($launching|Where-Object{
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$_.ProcessId) -ErrorAction SilentlyContinue
        $current -and $current.CreationDate-eq $_.CreationDate
      })
      if(!$alive.Count){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
      Start-Sleep -Milliseconds 100
    }while([DateTime]::UtcNow-lt $deadline)
    return
  }
  $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$guiPid) -ErrorAction SilentlyContinue
  $expectedGui='"'+(Join-Path $AppDir 'widget.ps1')+'"'
  if(!$process -or $process.Name-notin @('powershell.exe','pwsh.exe') -or ![string]$process.CommandLine -or $process.CommandLine.IndexOf($expectedGui,[StringComparison]::OrdinalIgnoreCase)-lt 0){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
  [IO.File]::WriteAllText($stopFile,'stop')
  $deadline=[DateTime]::UtcNow.AddSeconds(6)
  do{
    $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$guiPid) -ErrorAction SilentlyContinue
    if(!$current -or $current.CreationDate-ne $process.CreationDate){Remove-Item -LiteralPath $stopFile -ErrorAction SilentlyContinue;return}
    Start-Sleep -Milliseconds 100
  }while([DateTime]::UtcNow-lt $deadline)
}

function Get-WidgetSupervisorInfo {
  param([Parameter(Mandatory=$true)][string]$AppDir,$Configuration=$null)
  $root=[IO.Path]::GetFullPath($AppDir).TrimEnd('\')
  $config=$Configuration
  if(!$config){$config=Get-Content -LiteralPath (Join-Path $root 'installation.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json}
  if(![string]$config.appDir -or ![string]$config.dataDir){throw 'Installation paths are missing.'}
  $data=[IO.Path]::GetFullPath([string]$config.dataDir)
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $agent=if(Get-Command Get-WidgetLauncherDir -ErrorAction SilentlyContinue){Get-WidgetLauncherDir}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AntigravityCatUsage\launcher'}
  $conhost=Join-Path $env:WINDIR 'System32\conhost.exe'
  [pscustomobject]@{AppDir=$root;DataDir=$data;Sid=$sid;TaskName=('Antigravity Cat Usage - '+$sid);TaskPath='\';Execute=$conhost;Arguments=(Get-WidgetAgentPowerShellArguments $agent);WorkingDirectory=(Join-Path $env:WINDIR 'System32');AgentDir=$agent}
}

function Get-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)]$Info)
  $tasks=@(Get-ScheduledTask -TaskPath $Info.TaskPath -ErrorAction SilentlyContinue|Where-Object{$_.TaskName-eq $Info.TaskName})
  if($tasks.Count-ge 1){return $tasks[0]}
  return $null
}

function Write-WidgetSupervisorJson([string]$File,$Value){
  $null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($File)) -Force
  $temp=$File+'.'+$PID+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
  try{
    [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($File)){[IO.File]::Replace($temp,$File,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$File)}
  }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}

function Set-WidgetSupervisorPause {
  param([Parameter(Mandatory=$true)][string]$AppDir,[long]$HostHandle=0,[int]$HostPid=0)
  $info=Get-WidgetSupervisorInfo $AppDir
  if($HostHandle-le 0){try{$presence=Get-Content -LiteralPath (Join-Path $info.DataDir 'presence.json') -Raw -Encoding UTF8|ConvertFrom-Json;$HostHandle=[long]$presence.host}catch{}}
  if($HostHandle-gt 0 -and $HostPid-le 0){
    if(!('AgyWidgetSupervisorPauseNative' -as [type])){Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class AgyWidgetSupervisorPauseNative {
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 public static int ProcessId(IntPtr h){uint pid;GetWindowThreadProcessId(h,out pid);return (int)pid;}
}
'@}
    $HostPid=[AgyWidgetSupervisorPauseNative]::ProcessId([IntPtr]$HostHandle)
  }
  $started=0L
  if($HostPid-gt 0){try{$started=(Get-Process -Id $HostPid -ErrorAction Stop).StartTime.ToUniversalTime().Ticks}catch{}}
  Write-WidgetSupervisorJson (Join-Path $info.DataDir 'supervisor-pause.json') @{host=$HostHandle;hostPid=$HostPid;hostStarted=$started;at=[DateTime]::UtcNow.ToString('o')}
}

function Resume-WidgetSupervisor {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  foreach($name in @('supervisor-pause.json','supervisor-disabled.flag','supervisor-stop.flag')){
    $file=Join-Path $info.DataDir $name
    if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -ErrorAction Stop}
  }
}

function Disable-WidgetSupervisor {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  $null=New-Item -ItemType Directory -Path $info.DataDir -Force
  [IO.File]::WriteAllText((Join-Path $info.DataDir 'supervisor-disabled.flag'),'disabled')
}

function New-WidgetSupervisorTaskDefinition {
  param([Parameter(Mandatory=$true)]$Info)
  $action=New-ScheduledTaskAction -Execute $Info.Execute -Argument $Info.Arguments -WorkingDirectory $Info.WorkingDirectory
  $principal=New-ScheduledTaskPrincipal -UserId $Info.Sid -LogonType Interactive -RunLevel Limited
  $trigger=New-ScheduledTaskTrigger -AtLogOn -User $Info.Sid
  $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -Hidden -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
  New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Description 'Keep the Antigravity Cat quota widget attached to the current user Antigravity main window.'
}

function Register-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  foreach($relative in @('supervisor.vbs','runtime\supervisor.ps1','widget.ps1')){if(!(Test-Path -LiteralPath (Join-Path $info.AppDir $relative))){throw "Missing supervisor file: $relative"}}
  $existing=Get-WidgetSupervisorTask $info
  if($existing -and [string]$existing.State-eq 'Running'){Stop-WidgetSupervisorTask $AppDir}
  Resume-WidgetSupervisor $AppDir
  $definition=New-WidgetSupervisorTaskDefinition $info
  Register-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -InputObject $definition -Force -ErrorAction Stop|Out-Null
  Start-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -ErrorAction Stop
  return $info
}

function Start-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  $task=Get-WidgetSupervisorTask $info
  if(!$task){throw 'Supervisor task is not installed.'}
  Resume-WidgetSupervisor $AppDir
  Start-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -ErrorAction Stop
}

function Stop-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir,$Configuration=$null)
  $info=Get-WidgetSupervisorInfo $AppDir $Configuration
  $task=Get-WidgetSupervisorTask $info
  $expectedScript='"'+(Join-Path $info.AppDir 'runtime\supervisor.ps1')+'"'
  $stableScript='"'+(Join-Path $info.AgentDir 'agent-launcher.ps1')+'"'
  $processes=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue|Where-Object{
    $_.ProcessId-ne $PID -and [string]$_.CommandLine -and ($_.CommandLine.IndexOf($expectedScript,[StringComparison]::OrdinalIgnoreCase)-ge 0 -or $_.CommandLine.IndexOf($stableScript,[StringComparison]::OrdinalIgnoreCase)-ge 0)
  })
  $null=New-Item -ItemType Directory -Path $info.DataDir -Force
  [IO.File]::WriteAllText((Join-Path $info.DataDir 'supervisor-stop.flag'),'stop')
  if($task -and [string]$task.State-eq 'Running'){
    Stop-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -ErrorAction SilentlyContinue
  }
  $deadline=[DateTime]::UtcNow.AddSeconds(6)
  do{
    $running=$false
    foreach($process in $processes){
      $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$process.ProcessId) -ErrorAction SilentlyContinue
      if($current -and $current.CreationDate-eq $process.CreationDate){$running=$true}
    }
    if(!$running){return}
    Start-Sleep -Milliseconds 150
  }while([DateTime]::UtcNow-lt $deadline)
}

function Unregister-WidgetSupervisorTask {
  param([Parameter(Mandatory=$true)][string]$AppDir)
  $info=Get-WidgetSupervisorInfo $AppDir
  $task=Get-WidgetSupervisorTask $info
  Disable-WidgetSupervisor $AppDir
  Stop-WidgetSupervisorTask $AppDir
  if($task){Unregister-ScheduledTask -TaskName $info.TaskName -TaskPath $info.TaskPath -Confirm:$false -ErrorAction SilentlyContinue}
}
