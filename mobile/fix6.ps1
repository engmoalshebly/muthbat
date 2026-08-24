$f = "D:\Dafter\mobile\lib\features\merchant\presentation\screens\customer_ledger_screen.dart"
$c = Get-Content $f -Raw
# Replace FFD6D6 color (error light)
$c = [regex]::Replace($c, 'const <PERSON>)', 'AppColors.errorLight')
# Replace <LOCATION> color (debt red)  
$c = [regex]::Replace($c, 'const Color\(0xFFFF6B6B\)', 'AppColors.debtRed')
Set-Content $f -Value $c -NoNewline
Write-Output "Done"
