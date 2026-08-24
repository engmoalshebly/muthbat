$f = "D:\Dafter\mobile\lib\features\merchant\presentation\screens\merchant_home_screen.dart"
$c = Get-Content $f -Raw

$replacements = @{
    'const Color(0xFFFFF5F5)' = 'AppColors.debtRed.withValues(alpha: 0.06)'
    'const Color(0xFFFFEBEB)' = 'AppColors.debtRed.withValues(alpha: 0.04)'
    'const Color(0xFFFECDD3)' = 'AppColors.debtRed.withValues(alpha: 0.2)'
    'const Color(0xFFDC2626)' = 'AppColors.debtRed'
    'const Color(0xFFF0FDF4)' = 'AppColors.paymentGreen.withValues(alpha: 0.06)'
    'const Color(0xFFDCFCE7)' = 'AppColors.paymentGreen.withValues(alpha: 0.04)'
    'const Color(0xFFA7F3D0)' = 'AppColors.paymentGreen.withValues(alpha: 0.2)'
    'const Color(0xFFD1D5DB)' = 'AppColors.borderLight'
    'const Color(0xFFE5E9EB)' = 'AppColors.borderLight'
    'const Color(0xFFEAEFF2)' = 'AppColors.borderLight'
    'const Color(0xFFEDF2F4)' = 'AppColors.borderLight'
    'Color(0xFFEDF2F4)' = 'AppColors.borderLight'
    'const Color(0xFFCBD5E1)' = 'AppColors.accentGold'
}

foreach ($k in $replacements.Keys) {
    $c = $c.Replace($k, $replacements[$k])
}

# Fix the currency card gradient - replace dark slate with brand gradient
$c = $c.Replace("'gradient': AppColors.brandGradient,`r`n        'accentColor': AppColors.accentGold,", "'gradient': AppColors.brandGradient,`r`n        'accentColor': AppColors.accentGold,")

Set-Content $f -Value $c -NoNewline
Write-Output "Done"
