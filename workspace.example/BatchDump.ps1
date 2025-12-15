<#
.SYNOPSIS
BatchDump.ps1 - 複数のディレクトリをまとめてダンプするラッパースクリプト

.DESCRIPTION
workspace.json (または指定された設定ファイル) に定義されたターゲットリストに基づいて、
RepoDump.ps1 を順次実行し、Markdownファイルを一括生成します。

.EXAMPLE
.\BatchDump.ps1

.EXAMPLE
.\BatchDump.ps1 -ConfigFile "MyConfig.json" -OutDir ".\output"
#>

param(
    [string]$ConfigFile = "workspace.json",
    [string]$OutDir = ".",
    [string]$RepoDumpScript = "..\RepoDump.ps1",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# -------------------------------------------------------------
# ユーティリティ関数
# -------------------------------------------------------------
function Write-Log([string]$msg, [string]$color = "White") {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $msg" -ForegroundColor $color
}

# -------------------------------------------------------------
# 準備
# -------------------------------------------------------------
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }

# 親ディレクトリ（プロジェクトルート）
$projectRoot = Split-Path -Parent $scriptRoot

$configPath = Resolve-Path -Path $ConfigFile -ErrorAction SilentlyContinue
if (-not $configPath) {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 1
}

$repoDumpPath = Resolve-Path -Path $RepoDumpScript -ErrorAction SilentlyContinue
if (-not $repoDumpPath) {
    Write-Error "RepoDump script not found: $RepoDumpScript"
    exit 1
}

# 出力ディレクトリ作成
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    Write-Log "Created output directory: $OutDir" "Cyan"
}

# 設定読み込み
try {
    $json = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $targets = $json.Targets
}
catch {
    Write-Error "Failed to parse JSON config: $_"
    exit 1
}

if (-not $targets) {
    Write-Warning "No targets found in configuration."
    exit 0
}

Write-Log "Loaded configuration from $($configPath.Path)" "Green"
Write-Log "Found $($targets.Count) targets." "Green"

# -------------------------------------------------------------
# メイン処理
# -------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$successCount = 0
$failCount = 0

foreach ($t in $targets) {
    $name = $t.Name
    $relPath = $t.Path

    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($relPath)) {
        Write-Warning "Skipping invalid target entry: Name='$name', Path='$relPath'"
        continue
    }

    # パス解決（プロジェクトルート基準）
    $targetFullPath = $null
    if (Split-Path $relPath -IsAbsolute) {
        $targetFullPath = $relPath
    }
    else {
        $targetFullPath = Join-Path $projectRoot $relPath
    }
    
    if (-not (Test-Path -LiteralPath $targetFullPath)) {
        Write-Warning "Target path not found: $targetFullPath (Name: $name). Skipping."
        $failCount++
        continue
    }
    $targetFullPath = (Resolve-Path -LiteralPath $targetFullPath).Path

    # 出力ファイル名
    $outFile = Join-Path $OutDir "${timestamp}_${name}.md"
    if (-not (Split-Path $outFile -IsAbsolute)) {
        $outFile = Join-Path $scriptRoot $outFile
    }

    Write-Log "Processing target: [$name] -> $relPath" "Cyan"
    
    try {
        # RepoDump.ps1 呼び出し
        $params = @{
            RootPath     = $targetFullPath
            OutPath      = $outFile
            UseGitignore = $true
        }

        # サブプロセスで実行
        & $repoDumpPath.Path @params | Out-Null

        if ($LASTEXITCODE -eq 0 -and (Test-Path $outFile)) {
            Write-Log "  -> Success: $outFile" "Gray"
            $successCount++
        }
        else {
            Write-Log "  -> Failed (ExitCode: $LASTEXITCODE)" "Red"
            $failCount++
        }
    }
    catch {
        Write-Log "  -> Error: $_" "Red"
        $failCount++
    }
}

# -------------------------------------------------------------
# 完了
# -------------------------------------------------------------
Write-Host ""
Write-Log "Batch dump completed." "Green"
Write-Log "Success: $successCount, Failed: $failCount" $(if ($failCount -gt 0) { "Red" }else { "Green" })
