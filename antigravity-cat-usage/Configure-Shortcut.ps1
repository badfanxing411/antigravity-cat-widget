param(
  [ValidateSet('Enable','Disable','Status')]
  [string]$Action='Enable',
  [switch]$Quiet
)
$ErrorActionPreference='Stop'

function Get-AntigravityDesktopShortcuts {
  $shell=New-Object -ComObject WScript.Shell
  $dirs=@()
  try{$u=[Environment]::GetFolderPath('Desktop');if($u){$dirs+=$u}}catch{}
  try{$c=[Environment]::GetFolderPath('CommonDesktopDirectory');if($c){$dirs+=$c}}catch{}
  $found=@()
  foreach($dir in ($dirs|Select-Object -Unique)){
    if(!(Test-Path -LiteralPath $dir)){continue}
    foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -ErrorAction SilentlyContinue)){
      try{
        $sc=$shell.CreateShortcut($file.FullName)
        if($sc.TargetPath -and ([IO.Path]::GetFileName($sc.TargetPath) -ieq 'Antigravity.exe')){
          $found+=[pscustomobject]@{
            Path=$file.FullName
            Target=$sc.TargetPath
            Arguments=[string]$sc.Arguments
            Enabled=([string]$sc.Arguments -match '--remote-debugging-port=')
          }
        }
      }catch{}
    }
  }
  return ,$found
}

$shortcuts=@(Get-AntigravityDesktopShortcuts)
if($shortcuts.Count -eq 0){
  if(!$Quiet){
    Write-Output '未在桌面找到指向 Antigravity.exe 的快捷方式。'
    Write-Output '你仍可使用根目录的「启动Antigravity(含星猫额度).vbs」启动 Antigravity。'
  }
  return
}

$shell=New-Object -ComObject WScript.Shell
foreach($item in $shortcuts){
  if($Action -eq 'Status'){
    Write-Output ("[$($item.Path)] 参数：$($item.Arguments) （已开启额度接口：$($item.Enabled)）")
    continue
  }
  try{
    $sc=$shell.CreateShortcut($item.Path)
    if($Action -eq 'Enable'){
      if($sc.Arguments -notmatch '--remote-debugging-port='){
        $sc.Arguments=(($sc.Arguments.Trim()+' --remote-debugging-port=0').Trim())
        $sc.Save()
        if(!$Quiet){Write-Output ("已为桌面快捷方式添加额度调试参数：$($item.Path)")}
      }elseif(!$Quiet){
        Write-Output ("桌面快捷方式已包含调试参数，无需重复修改：$($item.Path)")
      }
    }elseif($Action -eq 'Disable'){
      if($sc.Arguments -match '--remote-debugging-port=\S*'){
        $cleaned=($sc.Arguments -replace '(?:^|\s+)--remote-debugging-port=\S*','').Trim()
        $sc.Arguments=$cleaned
        $sc.Save()
        if(!$Quiet){Write-Output ("已移除桌面快捷方式的调试参数：$($item.Path)")}
      }elseif(!$Quiet){
        Write-Output ("桌面快捷方式未设置调试参数：$($item.Path)")
      }
    }
  }catch{
    if(!$Quiet){Write-Warning ("无法修改快捷方式 $($item.Path)：$($_.Exception.Message)")}
  }
}
