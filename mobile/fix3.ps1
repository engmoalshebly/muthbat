$f = "D:\Dafter\mobile\lib\features\merchant\presentation\screens\merchant_home_screen.dart"
$c = Get-Content $f -Raw
$c = $c -replace 'const Color\(0xFF059669\)', 'AppColors.paymentGreen'
Set-Content $f -Value $c -NoNewline
Write-Output "Done"
