param($path)
(dir $path).FullName | Set-Clipboard
# OmitFromCoverageReport: a unit test would just restate it - trivial filesystem passthrough