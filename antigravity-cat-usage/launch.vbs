Option Explicit
Dim widgetShell, widgetFiles, widgetRoot, winDir, widgetCommand
Set widgetShell = CreateObject("WScript.Shell")
Set widgetFiles = CreateObject("Scripting.FileSystemObject")
widgetRoot = widgetFiles.GetParentFolderName(WScript.ScriptFullName)
winDir = widgetShell.ExpandEnvironmentStrings("%WINDIR%")
widgetCommand = """" & winDir & "\System32\conhost.exe"" --headless """ & winDir & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & widgetRoot & "\runtime\start-supervisor.ps1"""
widgetShell.Run widgetCommand, 0, False
