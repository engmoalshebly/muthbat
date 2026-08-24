$f = "D:\Dafter\mobile\lib\features\merchant\presentation\screens\merchant_home_screen.dart"
$lines = Get-Content $f

for ($i = 0; $i -lt $lines.Count; $i++) {
    # Fix payment card gradient
    $lines[$i] = $lines[$i] -replace 'const LinearGradient\(', 'LinearGradient('
    $lines[$i] = $lines[$i] -replace 'Color\(0xFFF0FDF4\)', 'AppColors.paymentGreen.withValues(alpha: 0.06)'
    $lines[$i] = $lines[$i] -replace 'Color\(0xFFDCFCE7\)', 'AppColors.paymentGreen.withValues(alpha: 0.04)'
    
    # Fix purple team card
    $lines[$i] = $lines[$i] -replace 'const Color\(0xFF7C3AED\)', 'AppColors.secondaryDark'
    $lines[$i] = $lines[$i] -replace 'const Color\(0xFFFAF5FF\)', 'AppColors.secondaryDark.withValues(alpha: 0.08)'
    $lines[$i] = $lines[$i] -replace 'const Color\(0xFFF3E8FF\)', 'AppColors.secondaryDark.withValues(alpha: 0.2)'
}

# Also fix the accentColor for payment card - find the line with 0xFF16A34A
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '0xFF16A34A') {
        $lines[$i] = $lines[$i] -replace 'const Color\(0xFF16A34A\)', 'AppColors.paymentGreen'
    }
}

Set-Content $f -Value $lines
Write-Output "Done"
