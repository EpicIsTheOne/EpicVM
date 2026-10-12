# A protected locator keeps services independent of the chosen data drive.
function Get-EpicVMDataRoot {
 param([string]$Locator=(Join-Path $env:ProgramData 'EpicVM\storage.json'))
 $default=Join-Path $env:ProgramData 'EpicVM'
 if(-not(Test-Path -LiteralPath $Locator)){return $default}
 if((Get-Item -LiteralPath $Locator).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Storage locator cannot be a link.'}
 $saved=Get-Content -LiteralPath $Locator -Raw -Encoding UTF8|ConvertFrom-Json
 $path=[string]$saved.dataRoot
 if($saved.schema -ne 1 -or $path -notmatch '^[A-Za-z]:\\' -or $path.Contains('..') -or $path.Contains('"')){throw 'Invalid protected EpicVM storage location.'}
 $path=[IO.Path]::GetFullPath($path).TrimEnd('\')
 if($path.Length -lt 4 -or -not(Test-Path -LiteralPath $path -PathType Container)){throw 'The selected EpicVM data drive is unavailable. Reconnect it before starting hosting.'}
 $walk=$path
 while($walk){if((Get-Item -LiteralPath $walk).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'EpicVM data cannot traverse links.'};$parent=Split-Path -Parent $walk;if($parent -eq $walk){break};$walk=$parent}
 return $path
}
