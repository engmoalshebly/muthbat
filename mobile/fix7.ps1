$f = <NRP> = Get-Content $f -Raw
$c = $c -replace 'const Color\(0xFFE7F8EE\)', 'AppColors.successLight'
$c = $c -replace 'const Color\(0xFF25D366\)\.withValues\(alpha: 0\.4\)', 'AppColors.secondary.withValues(alpha: 0.4)'
$c = $c -replace 'const Color\(0xFF25D366\)\.withValues\(alpha: 0\.08\)', 'AppColors.secondary.withValues(alpha: 0.08)'
$c = $c -replace 'Color\(0xFF25D366\)', 'AppColors.secondary'
$c = $c -replace 'Color\(0xFF0F5132\)', 'AppColors.secondaryDark'
$c = $c -replace '0xFF0F5132', 'AppColors.secondaryDark'
$c = $c -replace 'Color\(0xFF128C7E\)', 'AppColors.secondaryDark'
Set-Content $f -Value $c -NoNewline
Write-Output "Done"
