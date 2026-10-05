param($installationTracker)

# UTF-8 mode: on Windows, Python otherwise encodes a piped stdout, and open() without encoding=, with the
# legacy ANSI code page, raising UnicodeEncodeError on characters like em dashes. Linux/macOS already default
# to UTF-8 via the locale. Moot from Python 3.15, where UTF-8 mode becomes the default (PEP 686).
$stage = $installationTracker.StartStage('python-utf8')
Install-UserEnvironmentVariable $stage 'PYTHONUTF8' '1'
$installationTracker.EndStage($stage)
# OmitFromCoverageReport: a single call to Install-UserEnvironmentVariable, which prat tests
