# Wait for Antigravity main window to be visibly rendered and interactive.
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
if(!('AgyWidgetHostReadiness' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
public static class AgyWidgetHostReadiness {
 [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
 [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
 static readonly object Gate=new object();
 static IntPtr pendingTarget;
 static Task<bool> pending;
 static Task<bool> StartProbe(IntPtr handle){
  return Task.Factory.StartNew(()=>HasInterface(handle),CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);
 }
 public static bool Poll(IntPtr handle){
  lock(Gate){
   if(handle==IntPtr.Zero)return false;
   if(pending==null){pendingTarget=handle;pending=StartProbe(handle);return false;}
   if(!pending.IsCompleted)return false;
   bool ready=pendingTarget==handle&&pending.Status==TaskStatus.RanToCompletion&&pending.Result;
   pendingTarget=handle;pending=StartProbe(handle);
   return ready;
  }
 }
 public static bool HasInterface(IntPtr handle){
  if(handle==IntPtr.Zero||!IsWindow(handle)||!IsWindowVisible(handle)||IsIconic(handle))return false;
  Rect r;
  if(!GetClientRect(handle,out r)||r.Right-r.Left<360||r.Bottom-r.Top<200)return false;
  try{
   var root=AutomationElement.FromHandle(handle);
   if(root!=null){
    var usable=new AndCondition(new PropertyCondition(AutomationElement.IsEnabledProperty,true),new PropertyCondition(AutomationElement.IsOffscreenProperty,false));
    var anyControl=root.FindFirst(TreeScope.Descendants,new AndCondition(usable,new OrCondition(
      new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit),
      new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Document),
      new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Button),
      new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.TabItem)
    )));
    if(anyControl!=null)return true;
   }
  }catch{}
  // Antigravity Electron windows may expose minimal UIA when accessibility is off;
  // a visible full-sized Chromium window is still ready once stable for two ticks.
  return true;
 }
}
'@ -ReferencedAssemblies ([Windows.Automation.AutomationElement].Assembly.Location),([Windows.Automation.ControlType].Assembly.Location),([Windows.Point].Assembly.Location)
}
function New-WidgetReadinessState {
  return [pscustomobject]@{host=[IntPtr]::Zero;ready=$false;candidate=$false;lastProbe=-1000L;desktopStarted=$false}
}
function Test-WidgetHostReady {
  param($State,[IntPtr]$HostHandle,[long]$Now,[scriptblock]$Probe={param($h)[AgyWidgetHostReadiness]::Poll($h)})
  if($State.host-ne $HostHandle){$State.host=$HostHandle;$State.ready=$false;$State.candidate=$false;$State.lastProbe=$Now-1000}
  if($HostHandle-eq [IntPtr]::Zero){return $false}
  if($State.ready){return $true}
  if($Now-$State.lastProbe-lt 1000){return $false}
  $State.lastProbe=$Now
  $hasInterface=[bool](& $Probe $HostHandle)
  if($hasInterface -and $State.candidate){$State.ready=$true}
  $State.candidate=$hasInterface
  return [bool]$State.ready
}
