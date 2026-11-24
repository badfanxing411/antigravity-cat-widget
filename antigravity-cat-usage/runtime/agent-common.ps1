function Get-WidgetKnownFolderPath([Guid]$Id,[string]$FallbackSpecialFolder=''){
  if(!('AgyWidgetKnownFolders' -as [type])){
    Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class AgyWidgetKnownFolders {
 [DllImport("shell32.dll")]static extern int SHGetKnownFolderPath(ref Guid id,uint flags,IntPtr token,out IntPtr path);
 public static string Read(Guid id){
  IntPtr value=IntPtr.Zero;
  try{Marshal.ThrowExceptionForHR(SHGetKnownFolderPath(ref id,0x10000,IntPtr.Zero,out value));return Marshal.PtrToStringUni(value);}
  finally{if(value!=IntPtr.Zero)Marshal.FreeCoTaskMem(value);}
 }
}
'@
  }
  try{return [AgyWidgetKnownFolders]::Read($Id)}
  catch{
    if($FallbackSpecialFolder){
      $p=[Environment]::GetFolderPath($FallbackSpecialFolder)
      if($p){return $p}
    }
    if($Id -eq [Guid]'F1B32785-6FBA-4FCF-9D55-7B8E7F157091'){
      if($env:LOCALAPPDATA){return $env:LOCALAPPDATA}
      return [Environment]::GetFolderPath('LocalApplicationData')
    }
    if($Id -eq [Guid]'B97D20BB-F46A-4C97-BA10-5E3608430854'){
      $s=[Environment]::GetFolderPath('Startup')
      if($s){return $s}
      if($env:APPDATA){return (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup')}
    }
    throw
  }
}
function Get-WidgetLocalApplicationData {
  return Get-WidgetKnownFolderPath ([Guid]'F1B32785-6FBA-4FCF-9D55-7B8E7F157091')
}
function Get-WidgetLauncherDir {
  return (Join-Path (Get-WidgetLocalApplicationData) 'AntigravityCatUsage\launcher')
}
function Read-WidgetJsonFile([string]$File) {
  if(Test-Path -LiteralPath $File){return (Get-Content -LiteralPath $File -Raw -Encoding UTF8|ConvertFrom-Json)}
  return $null
}
function Install-WidgetLauncher([string]$AppDir,[string]$DataDir) {
  $launcherDir=Get-WidgetLauncherDir
  $null=New-Item -ItemType Directory -Path $launcherDir -Force
  foreach($file in @('agent-launcher.ps1','agent-common.ps1','supervisor-task.ps1')) {
    $bytes=[IO.File]::ReadAllBytes((Join-Path $AppDir ('runtime\'+$file)))
    $target=Join-Path $launcherDir $file
    $temp=$target+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllBytes($temp,$bytes)
    if([IO.File]::Exists($target)){[IO.File]::Replace($temp,$target,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$target)}
  }
  Write-WidgetSupervisorJson (Join-Path $launcherDir 'binding.json') @{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;appDir=$AppDir;dataDir=$DataDir}
}
