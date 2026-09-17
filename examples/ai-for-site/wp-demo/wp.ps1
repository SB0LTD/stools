# Thin WP-CLI wrapper: runs the phar with our local php.ini and the wp/ docroot.
# Usage:  .\wp.ps1 <wp-cli args...>
param([Parameter(ValueFromRemainingArguments = $true)] $Args)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$php  = (Get-Command php).Source
& $php -c (Join-Path $here 'php.ini') (Join-Path $here 'wp-cli.phar') `
    "--path=$(Join-Path $here 'wp')" @Args
exit $LASTEXITCODE
