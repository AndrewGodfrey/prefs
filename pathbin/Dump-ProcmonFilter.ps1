param([string] $filterName)

$regPath = 'HKCU:\Software\Sysinternals\Process Monitor\'
if (-not (Test-Path $regPath)) {
    throw "Sysinternals reg path not found"
}

$key = Get-Item -Path $regPath
$propertyName = 'Filter#' + $filterName
$property = $key.GetValue($propertyName)

if ($null -eq $property) { throw "Filter '$filterName' not found" }
if ($key.GetValueKind($propertyName) -ne "Binary") { throw "Unexpected datatype for filter '$filterName'" }

$result = ""

$result += @"
[byte[]] `$binaryData = @(
"@
$numOnLine = 0;
$startNewLine = $true
$first = $true
foreach ($b in $property) {
    if ($first) { $first = $false }
    else { $result += "," }
    if ($startNewLine) {
        $result += "`n    "
        $startNewLine = $false
        $numOnLine = 0
    } else {
        $result += " "
    }
    $result += ([string] $b)

    $numOnLine += 1

    if ($numOnLine -ge 32) {
        $startNewLine = $true
    }
}
$result += ")`n"

echo $result


