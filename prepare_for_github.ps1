# Cloud Arena - GitHub Preparation Script
# This script prepares the project for GitHub upload
# Run this AFTER reviewing the analysis report

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Cloud Arena - GitHub Preparation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Backup current .gitignore
Write-Host "[1/6] Backing up current .gitignore..." -ForegroundColor Yellow
if (Test-Path ".gitignore") {
    Copy-Item ".gitignore" ".gitignore.old"
    Write-Host "  ✓ Backed up to .gitignore.old" -ForegroundColor Green
}

# Step 2: Replace with recommended .gitignore
Write-Host "[2/6] Updating .gitignore..." -ForegroundColor Yellow
if (Test-Path ".gitignore.recommended") {
    Copy-Item ".gitignore.recommended" ".gitignore" -Force
    Write-Host "  ✓ Updated .gitignore with recommended version" -ForegroundColor Green
} else {
    Write-Host "  ✗ .gitignore.recommended not found!" -ForegroundColor Red
    exit 1
}

# Step 3: Check for sensitive files
Write-Host "[3/6] Checking for sensitive files..." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Checking export_presets.cfg for keystore paths..." -ForegroundColor Gray
if (Test-Path "godot\export_presets.cfg") {
    $content = Get-Content "godot\export_presets.cfg" -Raw
    if ($content -match "release_keystore=.*[^""]" -or $content -match "keystore_pass=.*[^android]") {
        Write-Host "  ⚠️  WARNING: Found custom keystore configuration!" -ForegroundColor Red
        Write-Host "     Review godot\export_presets.cfg before pushing" -ForegroundColor Red
    } else {
        Write-Host "  ✓ Only default debug keystore found (safe)" -ForegroundColor Green
    }
}

Write-Host "  Checking for .env files..." -ForegroundColor Gray
$envFiles = Get-ChildItem -Recurse -Filter ".env*" -ErrorAction SilentlyContinue
if ($envFiles) {
    Write-Host "  ⚠️  Found .env files: $($envFiles.Name -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "  ✓ No .env files found" -ForegroundColor Green
}

Write-Host "  Checking for keystore files..." -ForegroundColor Gray
$keystores = Get-ChildItem -Recurse -Filter "*.keystore" -ErrorAction SilentlyContinue
if ($keystores) {
    Write-Host "  ⚠️  Found keystore files: $($keystores.Name -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "  ✓ No keystore files found" -ForegroundColor Green
}

# Step 4: Show what will be ignored
Write-Host ""
Write-Host "[4/6] Verifying files to be excluded..." -ForegroundColor Yellow
$excludedSize = 0

$excludeChecks = @(
    @{Path="Godot_v4.7-stable_win64.exe"; Name="Godot Executable"},
    @{Path="build"; Name="Build Artifacts"},
    @{Path="dist"; Name="Distribution Packages"},
    @{Path="godot\.godot"; Name="Godot Cache"},
    @{Path="__pycache__"; Name="Python Cache"}
)

foreach ($check in $excludeChecks) {
    if (Test-Path $check.Path) {
        $size = (Get-ChildItem $check.Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $sizeMB = [math]::Round($size / 1MB, 2)
        $excludedSize += $size
        Write-Host "  ✓ Will exclude: $($check.Name) ($sizeMB MB)" -ForegroundColor Green
    }
}

# Step 5: Calculate final size
Write-Host ""
Write-Host "[5/6] Calculating upload size..." -ForegroundColor Yellow
$totalSize = (Get-ChildItem -Path . -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
$finalSize = $totalSize - $excludedSize
$finalSizeMB = [math]::Round($finalSize / 1MB, 2)

Write-Host "  Current project size: $([math]::Round($totalSize/1MB,2)) MB" -ForegroundColor Gray
Write-Host "  Files to exclude: $([math]::Round($excludedSize/1MB,2)) MB" -ForegroundColor Gray
Write-Host "  Estimated GitHub upload: $finalSizeMB MB" -ForegroundColor Cyan

# Step 6: Show Git status
Write-Host ""
Write-Host "[6/6] Git status check..." -ForegroundColor Yellow
Write-Host ""

try {
    git status --short 2>$null | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
} catch {
    Write-Host "  Git not initialized or not available" -ForegroundColor Yellow
}

# Final summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PREPARATION COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Review the changes above" -ForegroundColor White
Write-Host "  2. Check godot/export_presets.cfg for sensitive data" -ForegroundColor White
Write-Host "  3. Run: git add .gitignore" -ForegroundColor White
Write-Host "  4. Run: git status (verify excludes)" -ForegroundColor White
Write-Host "  5. Run: git add ." -ForegroundColor White
Write-Host "  6. Run: git commit -m 'Prepare for GitHub deployment'" -ForegroundColor White
Write-Host "  7. Run: git push origin main" -ForegroundColor White
Write-Host ""
Write-Host "Estimated upload size: $finalSizeMB MB" -ForegroundColor Cyan
Write-Host ""
