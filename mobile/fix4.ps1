$f = "D:\Dafter\mobile\lib\features\customer\presentation\screens\customer_home_screen.dart"
$c = Get-Content $f -Raw
$c = $c -replace 'const Color\(0xFFD1D5DB\)', 'AppColors.borderLight'
$c = $c -replace 'Color\(0xFFFF6B6B\)', 'AppColors.debtRed'
Set-Content $f -Value $c -NoNewline
Write-Output "Done"
