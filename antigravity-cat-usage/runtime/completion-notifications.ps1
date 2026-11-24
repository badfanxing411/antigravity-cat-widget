if(!('AgyCompletionWindowLayer' -as [type])){
  Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class AgyCompletionWindowLayer {
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]public static extern IntPtr GetWindow(IntPtr h,uint command);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]public static extern IntPtr GetWindowLongPtr(IntPtr h,int i);
 [DllImport("user32.dll",EntryPoint="SetWindowLongPtrW")]public static extern IntPtr SetWindowLongPtr(IntPtr h,int i,IntPtr value);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
}
'@
}

function Test-CompletionFullscreen([IntPtr]$Handle){
  if($Handle-eq [IntPtr]::Zero -or ![AgyCompletionWindowLayer]::IsWindow($Handle)){return $false}
  $rect=New-Object AgyCompletionWindowLayer+Rect
  if(![AgyCompletionWindowLayer]::GetWindowRect($Handle,[ref]$rect)){return $false}
  $area=[Windows.Forms.Screen]::FromHandle($Handle).Bounds
  return $rect.Left-le $area.Left -and $rect.Top-le $area.Top -and $rect.Right-ge $area.Right -and $rect.Bottom-ge $area.Bottom
}
function Stop-TemporaryCompletion {
  $state=$script:completionTemporary;$script:completionTemporary=$null
  if(!$state){return}
  if($state.timer){$state.timer.Stop()}
  try{
    if([AgyCompletionWindowLayer]::IsWindow($script:widgetHandle)){
      $script:window.Topmost=$state.topmost
      [AgyCompletionWindowLayer]::SetWindowLongPtr($script:widgetHandle,-20,$state.style)|Out-Null
      $owner=if([AgyCompletionWindowLayer]::IsWindow($state.owner)){$state.owner}else{[IntPtr]::Zero}
      $band=if(($state.style.ToInt64()-band 8)-ne 0){[IntPtr](-1)}else{[IntPtr](-2)}
      # Demote and place the detached widget before restoring its owner. An
      # owned window near the front can otherwise raise Antigravity with it.
      if($state.position){[AgyCompletionWindowLayer]::SetWindowPos($script:widgetHandle,$band,$state.position.left,$state.position.top,0,0,0x211)|Out-Null}
      else{[AgyCompletionWindowLayer]::SetWindowPos($script:widgetHandle,$band,0,0,0,0,0x213)|Out-Null}
      if(!$state.visible){$script:window.Hide()}
      $after=if($owner-ne [IntPtr]::Zero){[AgyCompletionWindowLayer]::GetWindow($owner,3)}else{$state.previous}
      while($after-ne [IntPtr]::Zero -and [AgyCompletionWindowLayer]::IsWindow($after) -and ($after-eq $script:widgetHandle -or ![AgyCompletionWindowLayer]::IsWindowVisible($after))){$after=[AgyCompletionWindowLayer]::GetWindow($after,3)}
      if($after-eq $script:widgetHandle -or ![AgyCompletionWindowLayer]::IsWindow($after) -or ([AgyCompletionWindowLayer]::GetWindowLongPtr($after,-20).ToInt64()-band 8)-ne ($state.style.ToInt64()-band 8)){$after=[IntPtr]::Zero}
      [AgyCompletionWindowLayer]::SetWindowPos($script:widgetHandle,$after,0,0,0,0,0x213)|Out-Null
      [AgyCompletionWindowLayer]::SetWindowLongPtr($script:widgetHandle,-8,$owner)|Out-Null
    }
  }catch{}
  $script:lastPosition=$null;$script:attachedHost=[IntPtr]::Zero
}
function Start-TemporaryCompletion([int]$DurationMs=7000) {
  if($script:completionTemporary){return $true}
  $foreground=[AgyCompletionWindowLayer]::GetForegroundWindow()
  $script:completionTemporary=@{owner=[AgyCompletionWindowLayer]::GetWindowLongPtr($script:widgetHandle,-8);style=[AgyCompletionWindowLayer]::GetWindowLongPtr($script:widgetHandle,-20);topmost=$script:window.Topmost;visible=$script:window.IsVisible;previous=[AgyCompletionWindowLayer]::GetWindow($script:widgetHandle,3);foreground=$foreground;fullscreen=(Test-CompletionFullscreen $foreground);expiresAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()+$DurationMs;timer=$null;position=$null}
  try{
    if($script:occlusionRecovery){$script:occlusionRecovery.Configure([IntPtr]::Zero,$false)}
    if($script:hostFollower){$script:hostFollower.Detach()}
    [AgyCompletionWindowLayer]::SetWindowLongPtr($script:widgetHandle,-8,[IntPtr]::Zero)|Out-Null
    $script:window.Show()
    $style=$script:completionTemporary.style.ToInt64()-bor 0x08000020
    [AgyCompletionWindowLayer]::SetWindowLongPtr($script:widgetHandle,-20,[IntPtr]$style)|Out-Null
    $script:window.Topmost=$true
    # Detaching removes the host clip. Fit an off-screen reminder temporarily,
    # without writing desktop/drag preferences or moving an already-safe one.
    $flags=0x13;$x=0;$y=0;$rect=New-Object AgyCompletionWindowLayer+Rect
    if([AgyCompletionWindowLayer]::GetWindowRect($script:widgetHandle,[ref]$rect)){
      $area=[Windows.Forms.Screen]::FromHandle($script:widgetHandle).WorkingArea
      $x=[Math]::Max($area.Left,[Math]::Min($area.Right-($rect.Right-$rect.Left),$rect.Left))
      $y=[Math]::Max($area.Top,[Math]::Min($area.Bottom-($rect.Bottom-$rect.Top),$rect.Top))
      if($x-ne $rect.Left -or $y-ne $rect.Top){$script:completionTemporary.position=@{left=$rect.Left;top=$rect.Top};$flags=0x11}
    }
    if(![AgyCompletionWindowLayer]::SetWindowPos($script:widgetHandle,[IntPtr](-1),$x,$y,0,0,$flags)){throw 'Temporary reminder layer failed'}
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({
      if(!$script:completionTemporary){return}
      try{
        $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $active=Test-WidgetCompletionHostForeground
        $foreground=[AgyCompletionWindowLayer]::GetForegroundWindow()
        $leftFullscreen=$script:completionTemporary.fullscreen -and ($foreground-ne $script:completionTemporary.foreground -or !(Test-CompletionFullscreen $foreground))
        if($active -or $leftFullscreen){Dismiss-CompletionNotification;if(!$script:collapsed){Hide-Quota -KeepCompletion}}
        # An error while opening the scene must never leave a topmost
        # click-through reminder layer pinned on screen. This independent
        # deadline works even when sceneDeadline was never set.
        elseif($now-ge $script:completionTemporary.expiresAt){Hide-Quota}
        elseif($script:sceneDeadline-gt 0 -and $now-ge $script:sceneDeadline){Hide-Quota}
      }catch{try{Stop-TemporaryCompletion}catch{}}
    })
    $script:completionTemporary.timer=$timer;$timer.Start();return $true
  }catch{
    Stop-TemporaryCompletion;$script:completionLastError=$_.Exception.Message;return $false
  }
}

if(!('AgyCompletionMonitorOutput' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Collections.Generic;
public static class AgyCompletionMonitorOutput {
  static readonly object Gate=new object();
  static readonly Queue<string> Lines=new Queue<string>();
  static string Active=null;
  public static string LastError {get;private set;}
  public static void Attach(Process process,string token){
    lock(Gate){Active=token;Lines.Clear();LastError=null;}
    process.OutputDataReceived+=(sender,args)=>{
      if(args.Data==null || args.Data.Length>2048)return;
      lock(Gate){if(Active!=token)return;if(Lines.Count>=64)Lines.Dequeue();Lines.Enqueue(args.Data);}
    };
    process.ErrorDataReceived+=(sender,args)=>{
      if(args.Data==null)return;
      lock(Gate){if(Active==token)LastError=args.Data.Length>256?args.Data.Substring(0,256):args.Data;}
    };
  }
  public static bool TryRead(out string line){lock(Gate){if(Lines.Count>0){line=Lines.Dequeue();return true;}line=null;return false;}}
  public static void Clear(){lock(Gate){Active=null;Lines.Clear();}}
}
'@
}

function Initialize-CompletionNotificationState($Settings=$null) {
  $script:completionNotificationsEnabled=if($null-ne $Settings -and $Settings.taskCompletionBubble-is [bool]){$Settings.taskCompletionBubble}else{$true}
  $script:approvalNotificationsEnabled=if($null-ne $Settings -and $Settings.approvalNotification-is [bool]){$Settings.approvalNotification}else{$true}
  $script:completionPending=$false;$script:completionPendingKind='completion';$script:completionProcess=$null;$script:completionRetryAfter=0
  $script:completionReceived=0;$script:completionDisplayCount=0;$script:completionLastError=$null
  $script:completionAcknowledgedAt=0;$script:completionTemporary=$null
}
function Clear-CompletionNotifications {$script:completionPending=$false;[AgyCompletionMonitorOutput]::Clear()}
function Dismiss-CompletionNotification {
  Stop-TemporaryCompletion
  $script:completionAcknowledgedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $script:completionPending=$false;Reset-WidgetAutoQuoteSchedule
}

function Start-CompletionMonitor {
  if(!$script:completionNotificationsEnabled -and !$script:approvalNotificationsEnabled){return}
  if($script:completionProcess){
    if(!$script:completionProcess.HasExited){return}
    $script:completionLastError=[AgyCompletionMonitorOutput]::LastError
    $script:completionProcess.Dispose();$script:completionProcess=$null
  }
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  if($now-lt $script:completionRetryAfter){return}
  $process=$null
  try{
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=[string]$script:config.nodePath
    $monitorArguments='"'+(Join-Path $script:appDir 'runtime\completion-monitor.mjs')+'"'
    if($script:dataDir){$monitorArguments+=' "'+(Join-Path $script:dataDir 'completion-monitor-state.json')+'"'}
    $start.Arguments=$monitorArguments
    $start.WorkingDirectory=$script:appDir;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start
    [AgyCompletionMonitorOutput]::Attach($process,[Guid]::NewGuid().ToString('N'))
    if(!$process.Start()){throw 'The reply monitor did not start.'}
    $process.BeginOutputReadLine();$process.BeginErrorReadLine()
    $script:completionProcess=$process;$script:completionLastError=$null;$script:completionRetryAfter=$now+5000
  }catch{
    [AgyCompletionMonitorOutput]::Clear()
    if($process){try{if(!$process.HasExited){$process.Kill();$null=$process.WaitForExit(200)}}catch{};$process.Dispose()};$script:completionProcess=$null
    $script:completionLastError=$_.Exception.Message;$script:completionRetryAfter=$now+5000
  }
}
function Stop-CompletionMonitor {
  Stop-TemporaryCompletion
  [AgyCompletionMonitorOutput]::Clear()
  if(!$script:completionProcess){return}
  try{
    if(!$script:completionProcess.HasExited){
      $script:completionProcess.StandardInput.Close()
      if(!$script:completionProcess.WaitForExit(200)){$script:completionProcess.Kill();$null=$script:completionProcess.WaitForExit(200)}
    }
  }catch{}
  $script:completionProcess.Dispose();$script:completionProcess=$null
}
function Set-CompletionNotificationEnabled([bool]$Enabled) {
  if($Enabled-eq $script:completionNotificationsEnabled){return}
  $script:completionNotificationsEnabled=$Enabled;$script:completionRetryAfter=0
  if($Enabled -or $script:approvalNotificationsEnabled){Start-CompletionMonitor}
  else{
    Stop-CompletionMonitor;Clear-CompletionNotifications
    $script:completionLastError=$null
    if(!$script:collapsed -and $script:bubbleMode-in @('completion','approval')){Hide-Quota}
  }
  Reset-WidgetAutoQuoteSchedule;Save-Settings
}
function Set-ApprovalNotificationEnabled([bool]$Enabled) {
  if($Enabled-eq $script:approvalNotificationsEnabled){return}
  $script:approvalNotificationsEnabled=$Enabled;$script:completionRetryAfter=0
  if($Enabled -or $script:completionNotificationsEnabled){Start-CompletionMonitor}
  else{
    Stop-CompletionMonitor;Clear-CompletionNotifications
    $script:completionLastError=$null
    if(!$script:collapsed -and $script:bubbleMode-in @('completion','approval')){Hide-Quota}
  }
  Reset-WidgetAutoQuoteSchedule;Save-Settings
}
function Receive-CompletionMonitorLine([string]$Line) {
  if((!$script:completionNotificationsEnabled -and !$script:approvalNotificationsEnabled) -or $Line.Length-gt 2048){return}
  try{
    $event=$Line|ConvertFrom-Json
    if($event.type-notin @('completion','approval') -or $event.sessionId-isnot [string] -or $event.turnId-isnot [string] -or !$event.sessionId -or !$event.turnId){return}
    if($event.type-eq 'completion' -and !$script:completionNotificationsEnabled){return}
    if($event.type-eq 'approval' -and !$script:approvalNotificationsEnabled){return}
    if($null-eq $event.endedAt -or [double]$event.endedAt-lt $script:completionAcknowledgedAt){return}
    $script:completionReceived++;$script:completionPending=$true;$script:completionPendingKind=[string]$event.type
  }catch{}
}
function Read-CompletionMonitorOutput {
  $line=$null
  for($i=0;$i-lt 64 -and [AgyCompletionMonitorOutput]::TryRead([ref]$line);$i++){
    Receive-CompletionMonitorLine $line;$line=$null
  }
}
function Test-CompletionDisplayAllowed([bool]$Visible) {
  return $Visible -and $script:window.IsVisible -and ![bool]$script:drag -and !$script:context.IsOpen -and !$script:settingsSizePreview -and !(Test-WidgetEditorOpen) -and (Test-WidgetCompletionForeground)
}
function Pause-CompletionNotification {
  Stop-TemporaryCompletion
  if(!$script:collapsed -and $script:bubbleMode-in @('completion','approval')){Hide-Quota -KeepCompletion}
}
function Tick-CompletionNotifications([bool]$Visible) {
  if(!$script:completionNotificationsEnabled -and !$script:approvalNotificationsEnabled){return}
  Read-CompletionMonitorOutput;Start-CompletionMonitor
  $busy=[bool]$script:drag -or $script:context.IsOpen -or $script:settingsSizePreview -or (Test-WidgetEditorOpen)
  if($busy){Pause-CompletionNotification;return}
  if($script:completionTemporary){return}
  $foreground=Test-WidgetCompletionHostForeground
  if($foreground){
    if(!(Test-CompletionDisplayAllowed $Visible)){Pause-CompletionNotification;return}
  }elseif(!$script:collapsed){
    if($script:bubbleMode-in @('completion','approval')){Pause-CompletionNotification};return
  }
  if(!$script:completionPending -or !$script:collapsed -or ($script:closeTimer -and $script:closeTimer.IsEnabled)){return}
  $mode=if($script:completionPendingKind-eq 'approval'){'approval'}else{'completion'}
  $tempMs=if($mode-eq 'approval'){11000}else{7000}
  if(!$foreground -and !(Start-TemporaryCompletion $tempMs)){return}
  Open-WidgetBubble $mode;$script:completionDisplayCount++
  Play-WidgetNotifySound
}
function Get-CompletionNotificationStatus {
  $monitorPid=0
  if($script:completionProcess){try{if(!$script:completionProcess.HasExited){$monitorPid=$script:completionProcess.Id}}catch{}}
  return @{enabled=[bool]$script:completionNotificationsEnabled;approvalEnabled=[bool]$script:approvalNotificationsEnabled;pending=[bool]$script:completionPending;temporaryTopmost=[bool]$script:completionTemporary;showing=(!$script:collapsed -and $script:bubbleMode-in @('completion','approval'));received=$script:completionReceived;displayCount=$script:completionDisplayCount;monitorPid=$monitorPid;error=$script:completionLastError}
}
