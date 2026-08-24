$f = "D:\Dafter\mobile\lib\features\merchant\presentation\screens\customer_ledger_screen.dart"
$c = Get-Content $f -Raw

# Replace dark slate gradient with brand gradient
$c = $c -replace 'colors: \[Color\(0xFF334155\), Color\(0xFF1E293B\), Color\(0xFF0F172A\)\]', 'colors: [AppColors.primaryLight, AppColors.primary, AppColors.primaryDark]'

# Replace dark slate shadow
$c = $c -replace 'const Color\(0xFF334155\)\.withValues\(alpha: 0\.28\)', 'AppColors.primary.withValues(alpha: 0.28)'

# Replace light slate accent color with accentGold
$c = $c -replace 'Color\(0xFFCBD5E1\)', 'AppColors.accentGold'

# Replace border colors
$c = $c -replace 'const Color\(0xFFE2E8F0\)', 'AppColors.borderLight'

# Category badge colors -> AppColors.badge* constants
$c = $c -replace 'const Color\(0xFFF1F5F9\)', 'AppColors.badgeGoodsBg'
$c = $c -replace 'Color\(0xFF475569\)', 'AppColors.badgeGoodsText'
$c = $c -replace 'const Color\(0xFFECFDF5\)', 'AppColors.badgeCashBg'
$c = $c -replace 'Color\(0xFF065F46\)', 'AppColors.badgeCashText'
$c = $c -replace 'const Color\(0xFFEFF6FF\)', 'AppColors.badgeRefBg'
$c = $c -replace 'Color\(0xFF1D4ED8\)', 'AppColors.badgeRefText'

# Breakdown card icon colors -> brand colors
$c = $c -replace 'const Color\(0xFF2DD4BF\)', 'AppColors.secondaryLight'
$c = $c -replace 'const Color\(0xFFFBBF24\)', 'AppColors.accentGold'

# Balance text colors
$c = $c -replace 'const <PERSON>)', 'AppColors.errorLight'
$c = $c -replace 'const Color\(0xFFC9F1E1\)', 'AppColors.successLight'
$c = <PERSON>, 'AppColors.debtRed'

Set-Content $f -Value $c -NoNewline
Write-Output "Done"
