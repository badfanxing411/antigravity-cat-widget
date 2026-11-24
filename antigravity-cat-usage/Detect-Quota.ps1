param([switch]$Json)
$ErrorActionPreference='Stop'
$nodeCommand=Get-Command node.exe -ErrorAction SilentlyContinue
if(!$nodeCommand){throw '未找到 Node.js，请先安装 Node.js 20 或更高版本。'}
$script=Join-Path $PSScriptRoot 'runtime\detect-quota.mjs'
if($Json){& $nodeCommand.Source $script --json}else{& $nodeCommand.Source $script}
exit $LASTEXITCODE
