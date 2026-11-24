param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'agent-common.ps1')
. (Join-Path $PSScriptRoot 'supervisor-task.ps1')
$appDir=Split-Path $PSScriptRoot -Parent
$info=Get-WidgetSupervisorInfo $appDir
if(!('AgyWidgetSupervisorNative' -as [type])){
Add-Type -TypeDefinition @'
using System;using System.Collections.Generic;using System.Diagnostics;using System.Runtime.InteropServices;using System.Text;
public sealed class AgyWidgetSupervisorHost {public long handle;public int pid;public long started;public bool visible;}
public static class AgyWidgetSupervisorNative {
 static readonly int Session=CurrentSession();
 static int CurrentSession(){using(var process=Process.GetCurrentProcess())return process.SessionId;}
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [StructLayout(LayoutKind.Sequential)] struct Rect {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")]static extern bool EnumWindows(EnumProc cb,IntPtr p);
 [DllImport("user32.dll")]public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")]static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")]static extern IntPtr GetWindow(IntPtr h,uint cmd);
 [DllImport("user32.dll")]static extern bool GetClientRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]static extern IntPtr GetWindowLongPtr(IntPtr h,int index);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetClassName(IntPtr h,StringBuilder text,int size);
 [DllImport("dwmapi.dll")]static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out uint value,int size);
 public static bool MainWindowStyle(long style,long extended){return (extended&0x80)==0&&(extended&0x08000000)==0;}
 public static int ProcessId(IntPtr h){uint value;GetWindowThreadProcessId(h,out value);return (int)value;}
 static bool AntigravityProcess(Process process){
  return process.SessionId==Session&&process.ProcessName.Equals("Antigravity",StringComparison.OrdinalIgnoreCase);
 }
 public static AgyWidgetSupervisorHost Inspect(IntPtr h){
  try{
   if(!IsWindow(h)||GetWindow(h,4)!=IntPtr.Zero||!MainWindowStyle(GetWindowLongPtr(h,-16).ToInt64(),GetWindowLongPtr(h,-20).ToInt64()))return null;
   var cls=new StringBuilder(128);GetClassName(h,cls,128);if(cls.ToString()!="Chrome_WidgetWin_1")return null;
   Rect r;if(!GetClientRect(h,out r)||r.Right-r.Left<360||r.Bottom-r.Top<200)return null;
   using(var process=Process.GetProcessById(ProcessId(h))){
    if(!AntigravityProcess(process))return null;
    uint cloaked;bool visible=IsWindowVisible(h)&&!IsIconic(h)&&(DwmGetWindowAttribute(h,14,out cloaked,4)!=0||cloaked==0);
    return new AgyWidgetSupervisorHost{handle=h.ToInt64(),pid=process.Id,started=process.StartTime.ToUniversalTime().Ticks,visible=visible};
   }
  }catch{return null;}
 }
 public static AgyWidgetSupervisorHost[] Hosts(){var hosts=new List<AgyWidgetSupervisorHost>();EnumWindows((h,p)=>{var host=Inspect(h);if(host!=null)hosts.Add(host);return true;},IntPtr.Zero);return hosts.ToArray();}
}
'@
}

function Test-WidgetSupervisorPause($Pause,$Hosts){
  if(!$Pause){return $false}
  if($Pause.desktop){return $true}
  foreach($item in @($Hosts)){
    if([long]$Pause.host-gt 0 -and [long]$item.handle-eq [long]$Pause.host){
      if([int]$Pause.hostPid-gt 0 -and [int]$item.pid-ne [int]$Pause.hostPid){continue}
      if([long]$Pause.hostStarted-gt 0 -and [long]$item.started-ne [long]$Pause.hostStarted){continue}
      return $true
    }
  }
  return $false
}

function Get-WidgetSupervisorRunningGui([string]$DataDir,[string]$ExpectedAppDir){
  $process=$null
  try{
    $runtime=Get-Content -LiteralPath (Join-Path $DataDir 'runtime.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $handle=[IntPtr]([long]$runtime.widget)
    if(![AgyWidgetSupervisorNative]::IsWindow($handle) -or [AgyWidgetSupervisorNative]::ProcessId($handle)-ne [int]$runtime.pid){return $false}
    $process=Get-Process -Id ([int]$runtime.pid) -ErrorAction Stop
    if($process.ProcessName-notin @('powershell','pwsh')){return $false}
    if($runtime.processStartedAt){
      if(([DateTime]$runtime.processStartedAt).ToUniversalTime()-ne $process.StartTime.ToUniversalTime()){return $false}
    }else{
      $recorded=([DateTime]$runtime.startedAt).ToUniversalTime()
      $gap=($recorded-$process.StartTime.ToUniversalTime()).TotalSeconds
      if($gap-lt 0 -or $gap-gt 120){return $false}
    }
    $command=(Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$runtime.pid) -ErrorAction Stop).CommandLine
    $scriptFile=Join-Path $ExpectedAppDir 'widget.ps1'
    return $command.IndexOf(('"'+$scriptFile+'"'),[StringComparison]::OrdinalIgnoreCase)-ge 0
  }catch{return $false}finally{if($process){$process.Dispose()}}
}

if($CheckOnly){return [pscustomobject]@{ok=$true;info=$info;hosts=@([AgyWidgetSupervisorNative]::Hosts())}}

$mutex=[Threading.Mutex]::new($false,('Local\AntigravityCatSupervisor-'+$info.Sid))
$owned=$false
try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
if(!$owned){$mutex.Dispose();exit 0}
$pauseFile=Join-Path $info.DataDir 'supervisor-pause.json'
$nextLaunch=[DateTime]::MinValue
$nextStatus=[DateTime]::MinValue
$lastVisibleHostKey=''
$pendingGui=$null
$supervisorProcess=Get-Process -Id $PID
try{$processStartedAt=$supervisorProcess.StartTime.ToUniversalTime().ToString('o')}finally{$supervisorProcess.Dispose()}
try{
  while($true){
    if((Test-Path -LiteralPath (Join-Path $info.DataDir 'supervisor-disabled.flag')) -or (Test-Path -LiteralPath (Join-Path $info.DataDir 'supervisor-stop.flag'))){break}
    try{
      $hosts=@([AgyWidgetSupervisorNative]::Hosts())
      $settings=$null;try{$settings=Get-Content -LiteralPath (Join-Path $info.DataDir 'settings.json') -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
      $desktop=$settings -and $null-ne $settings.followHost -and !$settings.followHost
      $pause=$null;try{$pause=Get-Content -LiteralPath $pauseFile -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
      $paused=Test-WidgetSupervisorPause $pause $hosts
      if($pause -and !$paused){Remove-Item -LiteralPath $pauseFile -ErrorAction SilentlyContinue}
      $visible=@($hosts|Where-Object{$_.visible})
      $visibleHostKey=(@($visible|Sort-Object handle|ForEach-Object{'{0}:{1}:{2}'-f $_.handle,$_.pid,$_.started}) -join '|')
      if($visibleHostKey-ne $lastVisibleHostKey){$nextLaunch=[DateTime]::MinValue;$lastVisibleHostKey=$visibleHostKey}
      $running=Get-WidgetSupervisorRunningGui $info.DataDir $info.AppDir
      if($pendingGui -and ($running -or $pendingGui.HasExited)){$pendingGui.Dispose();$pendingGui=$null}
      if(!$paused -and ($desktop -or $visible.Count-gt 0) -and !$running -and !$pendingGui -and [DateTime]::UtcNow-ge $nextLaunch){
        $nextLaunch=[DateTime]::UtcNow.AddSeconds(10)
        $powerShell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=$powerShell
        $psi.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $info.AppDir 'runtime\start-widget.ps1')+'" -WidgetPath "'+(Join-Path $info.AppDir 'widget.ps1')+'"'
        $psi.WorkingDirectory=$info.AppDir
        $psi.UseShellExecute=$false
        $psi.CreateNoWindow=$true
        $pendingGui=[Diagnostics.Process]::Start($psi)
      }
      if([DateTime]::UtcNow-ge $nextStatus){
        Write-WidgetSupervisorJson (Join-Path $info.DataDir 'supervisor-status.json') @{pid=$PID;processStartedAt=$processStartedAt;at=[DateTime]::UtcNow.ToString('o');mainWindows=$hosts.Count;visibleWindows=$visible.Count;paused=$paused;widgetRunning=$running;taskName=$info.TaskName}
        $nextStatus=[DateTime]::UtcNow.AddSeconds(5)
      }
    }catch{try{[IO.File]::WriteAllText((Join-Path $info.DataDir 'supervisor-error.txt'),$_.Exception.Message)}catch{}}
    Start-Sleep -Milliseconds 1500
  }
}finally{
  if($pendingGui){$pendingGui.Dispose()}
  try{
    $statusFile=Join-Path $info.DataDir 'supervisor-status.json'
    $status=Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$status.pid-eq $PID){Remove-Item -LiteralPath $statusFile -ErrorAction SilentlyContinue}
  }catch{}
  try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()
}
