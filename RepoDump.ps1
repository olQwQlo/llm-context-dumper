param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$RootPath,

  [string]$OutPath,

  # ========== “ディレクトリごと” 本文を非表示（ツリーには残す） ==========
  [string[]]$HideDirNames = @(
    ".git", ".svn", ".hg",
    "node_modules", "bower_components", "vendor",
    "dist", "build", "out", ".next", ".nuxt", ".svelte-kit",
    ".turbo", ".cache", ".parcel-cache",
    "coverage", ".nyc_output",
    "bin", "obj", "target",
    ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ".gradle", ".idea", ".vscode",
    ".terraform", ".terragrunt-cache"
  ),

  # ========== “ファイル単体” 本文を非表示（ツリーには残す） ==========
  [string[]]$HideFilePatterns = @(
    "*.exe", "*.dll", "*.so", "*.dylib", "*.a", "*.lib",
    "*.pdb", "*.obj", "*.o", "*.class", "*.jar", "*.war",
    "*.png", "*.jpg", "*.jpeg", "*.gif", "*.webp", "*.ico", "*.svg",
    "*.mp4", "*.mov", "*.mkv", "*.avi", "*.mp3", "*.wav", "*.flac",
    "*.zip", "*.7z", "*.rar", "*.tar", "*.gz", "*.bz2", "*.xz",
    "*.pdf", "*.doc", "*.docx", "*.ppt", "*.pptx", "*.xls", "*.xlsx",
    "*.ttf", "*.otf", "*.woff", "*.woff2",
    "*.db", "*.sqlite", "*.sqlite3",
    "*.log",
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml"
  ),

  # ========== 機微情報: “存在は示すが本文は伏せる” ==========
  [string[]]$RedactFilePatterns = @(
    ".env", "*.env", ".env.*",
    "*.pem", "*.key", "*.pfx", "*.p12", "*.kdbx",
    "id_rsa", "id_ed25519", "known_hosts",
    ".npmrc", ".pypirc", ".dockerconfigjson"
  ),
  [string[]]$RedactDirNames = @(".aws", ".ssh", ".gnupg"),

  # envでも中身を出してよい例外
  [string[]]$AllowEnvNames = @(".env.sample", ".env.example", ".env.template"),

  # 念のため（巨大ファイル・バイナリ）
  [int]$MaxFileSizeMB = 5,

  # ========== 改善: .gitignore 簡易取り込み ==========
  [switch]$UseGitignore,

  # ========== 改善: 進捗表示 ==========
  [switch]$ShowProgress,

  # ========== 改善: CSVプレビュー行数 ==========
  [int]$CsvPreviewLines = 5,

  # ========== 設定ファイル（任意） ==========
  # 指定がなければスクリプト同階層の RepoDump.json を探す
  [string]$ConfigFile,

  # ========== 改善: PS7 での並列読み込み（順序は維持） ==========
  [switch]$ParallelRead,
  [int]$ThrottleLimit = 4
)


if (-not $OutPath) {
  $base = $(if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path -LiteralPath ".").Path })
  $OutPath = Join-Path -Path $base -ChildPath "dump.md"
}

Write-Host "[DEBUG] Script started. RootPath: $RootPath"
Write-Host "[DEBUG] OutPath: $OutPath"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------
# 設定ファイル読み込み（上書き）
# ---------------------------
$configPath = if ($ConfigFile) { $ConfigFile } else { Join-Path $PSScriptRoot "RepoDump.json" }
if (Test-Path -LiteralPath $configPath) {
  try {
    $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.HideDirNames) { $HideDirNames = @($cfg.HideDirNames) }
    if ($cfg.HideFilePatterns) { $HideFilePatterns = @($cfg.HideFilePatterns) }
    if ($cfg.RedactDirNames) { $RedactDirNames = @($cfg.RedactDirNames) }
    if ($cfg.RedactFilePatterns) { $RedactFilePatterns = @($cfg.RedactFilePatterns) }
    if ($cfg.AllowEnvNames) { $AllowEnvNames = @($cfg.AllowEnvNames) }
    Write-Host "[INFO] Loaded configuration from: $configPath"
  }
  catch {
    Write-Warning "Failed to load configuration from $configPath : $_"
  }
}

# ---------------------------
# 定数（マジックナンバー排除）
# ---------------------------
$script:BinaryDetectionBufferSize = 4096

# ---------------------------
# 小物ユーティリティ
# ---------------------------
function Resolve-FullPath([string]$p) { (Resolve-Path -LiteralPath $p).Path }

function Get-RelativePath([string]$root, [string]$fullPath) {
  if ($fullPath.StartsWith($root)) {
    return $fullPath.Substring($root.Length).TrimStart('\', '/')
  }
  return $fullPath
}

function Normalize-Rel([string]$rel) { $rel.Replace("\", "/") }

function Is-NameIn([string]$name, [string[]]$names) {
  foreach ($n in $names) { if ($name -ieq $n) { return $true } }
  return $false
}

function Is-MatchAnyPattern([string]$name, [string[]]$patterns) {
  foreach ($pat in $patterns) { if ($name -like $pat) { return $true } }
  return $false
}

# レビュー案に沿って統合：ディレクトリ名＋ファイル名パターンをまとめて判定
function Test-PathMatchesPattern(
  [string]$relPath,
  [string[]]$dirNames,
  [string[]]$filePatterns
) {
  $parts = @($relPath -split "[\\/]")
  if ($parts.Count -gt 1) {
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
      if (Is-NameIn $parts[$i] $dirNames) { return $true }
    }
  }
  $leaf = $parts[-1]
  if (Is-MatchAnyPattern $leaf $filePatterns) { return $true }
  return $false
}


function Get-HiddenAncestorRel([string]$relPath, [string[]]$hideDirNames, [bool]$isDirectory = $false) {
  $parts = @($relPath -split "[\\/]" | Where-Object { $_ -ne "" })
  if ($parts.Count -eq 0) { return $null }

  $limit = $(if ($isDirectory) { $parts.Count } elseif ($parts.Count -gt 1) { $parts.Count - 1 } else { 0 })
  if ($limit -le 0) { return $null }

  $accum = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $limit; $i++) {
    $name = $parts[$i]
    if (Is-NameIn $name $hideDirNames) {
      $accum.Add($name) | Out-Null
      return ($accum -join "/")
    }
    $accum.Add($name) | Out-Null
  }

  return $null
}

function Detect-SensitiveContent([string]$text) {
  $hits = New-Object System.Collections.Generic.List[string]

  if ($text -match "ghp_[A-Za-z0-9]{24,}") { $hits.Add("GitHub token") | Out-Null }
  if ($text -match "github_pat_[A-Za-z0-9_]{20,}") { $hits.Add("GitHub PAT") | Out-Null }
  if ($text -match "AKIA[0-9A-Z]{16}") { $hits.Add("AWS Access Key") | Out-Null }
  if ($text -match "-----BEGIN (?:RSA|OPENSSH|EC) PRIVATE KEY-----") { $hits.Add("Private key block") | Out-Null }
  if ($text -match "\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b") { $hits.Add("JWT-like token") | Out-Null }

  return $hits.ToArray()
}

function Get-LangFromExtension([string]$ext) {
  switch ($ext.ToLowerInvariant()) {
    ".ps1" { "powershell" } ".psm1" { "powershell" } ".psd1" { "powershell" }
    ".js" { "javascript" } ".ts" { "typescript" } ".tsx" { "tsx" } ".jsx" { "jsx" }
    ".py" { "python" } ".rb" { "ruby" } ".go" { "go" } ".rs" { "rust" }
    ".java" { "java" } ".cs" { "csharp" } ".cpp" { "cpp" } ".c" { "c" } ".h" { "c" } ".hpp" { "cpp" }
    ".json" { "json" } ".yml" { "yaml" } ".yaml" { "yaml" } ".xml" { "xml" }
    ".md" { "markdown" } ".html" { "html" } ".css" { "css" } ".sql" { "sql" }
    default { "" }
  }
}

function Test-IsProbablyBinary([string]$filePath) {
  # “意図”: 先頭数KBにNULLバイトが混ざるならバイナリ扱い（高速で雑に強い）
  $fs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $buf = New-Object byte[] $script:BinaryDetectionBufferSize
    $read = $fs.Read($buf, 0, $buf.Length)
    for ($i = 0; $i -lt $read; $i++) { if ($buf[$i] -eq 0) { return $true } }
    return $false
  }
  finally { $fs.Dispose() }
}

function Read-TextFileAutoEncoding([string]$filePath, [int]$LimitLines = 0) {
  # “意図”: BOMがあれば尊重、なければUTF-8優先で読む（不明は置換で落とさない）
  $fs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true, 4096, $true)
    
    if ($LimitLines -gt 0) {
      $max = $LimitLines
      $acc = New-Object System.Collections.Generic.List[string]
      while ($max -gt 0 -and -not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { break }
        $acc.Add($line) | Out-Null
        $max--
      }
      if (-not $reader.EndOfStream) {
        $acc.Add("... (truncated first $LimitLines lines)") | Out-Null
      }
      $reader.Dispose()
      return ($acc -join [Environment]::NewLine)
    }

    $text = $reader.ReadToEnd()
    $reader.Dispose()
    return $text
  }
  finally { $fs.Dispose() }
}

# ---------------------------
# .gitignore（簡易）取り込み
# ---------------------------
function Convert-GitignoreToLikePatterns([string]$rootFull) {
  $gi = Join-Path $rootFull ".gitignore"
  if (-not (Test-Path -LiteralPath $gi)) { return [pscustomobject]@{ DirNames = @(); FilePatterns = @() } }

  $dirNames = New-Object System.Collections.Generic.List[string]
  $filePats = New-Object System.Collections.Generic.List[string]

  $lines = Get-Content -LiteralPath $gi -ErrorAction Stop
  foreach ($raw in $lines) {
    $line = $raw.Trim()
    if (-not $line) { continue }
    if ($line.StartsWith("#")) { continue }
    if ($line.StartsWith("!")) { continue } # 簡易版では否定は無視

    # 末尾 / はディレクトリ扱い（名前だけ拾う）
    if ($line.EndsWith("/")) {
      $name = ($line.TrimEnd("/") -split "[/\\]")[-1]
      if ($name) { $dirNames.Add($name) | Out-Null }
      continue
    }

    # それ以外は “拡張子系だけ拾う” に割り切る（過剰除外を避ける）
    if ($line -match "[/\\]") { continue } # 階層指定は捨てる

    if ($line -notmatch "\.") { continue } # 拡張子を含まないものはスキップ

    $pat = $line
    if (-not $pat.StartsWith("*")) { $pat = "*$pat" }
    $filePats.Add($pat) | Out-Null
  }

  return [pscustomobject]@{
    DirNames     = $dirNames.ToArray()
    FilePatterns = $filePats.ToArray()
  }
}

# ---------------------------
# メインロジック
# ---------------------------
$rootFull = Resolve-FullPath $RootPath
$maxBytes = $MaxFileSizeMB * 1MB

# .gitignore取り込み（任意）
$gi = Convert-GitignoreToLikePatterns $rootFull
if ($UseGitignore) {
  $HideDirNames = @($HideDirNames + $gi.DirNames)
  $HideFilePatterns = @($HideFilePatterns + $gi.FilePatterns)
}

# “伏せたディレクトリ” を Files セクションで 1回だけ説明するための集合
function Get-TreeLines([string]$rootFull, [hashtable]$DetectedSecrets) {
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Dump")
  $lines.Add("")
  $lines.Add("## Tree")
  $lines.Add("")
  $lines.Add("```text")
  $lines.Add((Split-Path -Leaf $rootFull))

  function Walk([string]$dir, [string]$prefix, [string]$relFromRoot) {
    $children = @(Get-ChildItem -LiteralPath $dir -Force | Sort-Object @{Expression = "PSIsContainer"; Descending = $true }, Name)

    for ($i = 0; $i -lt $children.Count; $i++) {
      $item = $children[$i]
      $isLast = ($i -eq $children.Count - 1)
      $branch = $(if ($isLast) { "└─ " } else { "├─ " })
      $nextPrefix = $prefix + $(if ($isLast) { "   " } else { "│  " })

      if ($item.PSIsContainer) {
        $childRel = $(if ([string]::IsNullOrEmpty($relFromRoot)) { $item.Name } else { "$relFromRoot/$($item.Name)" })


        if (Is-NameIn $item.Name $HideDirNames) {
          $lines.Add("$prefix$branch$($item.Name)/ [DIR:本文非表示]")
          continue
        }

        $lines.Add("$prefix$branch$($item.Name)/")
        Walk $item.FullName $nextPrefix $childRel
      }
      else {
        $leafRel = $(if ([string]::IsNullOrEmpty($relFromRoot)) { $item.Name } else { "$relFromRoot/$($item.Name)" })
        $tag = ""

        if (Is-MatchAnyPattern $item.Name $HideFilePatterns) { $tag = " [FILE:本文非表示]" }
        elseif (Test-PathMatchesPattern $leafRel $RedactDirNames $RedactFilePatterns -and -not (Is-NameIn $item.Name $AllowEnvNames)) { $tag = " [機微:本文非表示]" }
        elseif ($DetectedSecrets.ContainsKey($leafRel)) {
          $tag = " [機微:本文非表示:検出項目 " + ($DetectedSecrets[$leafRel] -join ", ") + "]"
        }

        $lines.Add("$prefix$branch$($item.Name)$tag")
      }
    }
  }

  Walk $rootFull "" ""
  $lines.Add('```')
  $lines.Add("")
  return $lines
}

# 早期フィルタ：-File を使ってまず “ファイルだけ” 列挙（大規模で効く）
$allFiles = @(
  Get-ChildItem -LiteralPath $rootFull -Recurse -Force -File |
  Sort-Object @{Expression = { $_.DirectoryName }; Ascending = $true }, @{Expression = { $_.Name }; Ascending = $true }
)

# 自己参照（このスクリプト自身）を除外
$allFiles = @($allFiles | Where-Object { $_.FullName -ne $PSCommandPath })
Write-Host "[DEBUG] Found $($allFiles.Count) files to process."

$writtenHiddenDir = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
$DetectedSecretMap = @{}

# 並列読み込みを使う場合も順序は維持したいので、結果は一旦貯める
$results = New-Object System.Collections.Generic.List[psobject]

function Classify-File([System.IO.FileInfo]$fileInfo) {
  $rel = Normalize-Rel (Get-RelativePath $rootFull $fileInfo.FullName)

  $hiddenDirRel = Get-HiddenAncestorRel $rel $HideDirNames

  $isHiddenFile = Is-MatchAnyPattern $fileInfo.Name $HideFilePatterns
  $isRedact = (Test-PathMatchesPattern $rel $RedactDirNames $RedactFilePatterns) -and -not (Is-NameIn $fileInfo.Name $AllowEnvNames)


  return [pscustomobject]@{
    Rel          = $rel
    HiddenDirRel = $hiddenDirRel
    IsHiddenFile = $isHiddenFile
    IsRedacted   = $isRedact
    SizeBytes    = $fileInfo.Length
    FullName     = $fileInfo.FullName
    Name         = $fileInfo.Name
  }
}

if ($ParallelRead -and $PSVersionTable.PSVersion.Major -ge 7) {
  Write-Host "[DEBUG] Mode: Parallel (PS7+)"
  # まず分類だけは直列で（軽い）。読み込みだけ並列
  $classified = @(
    foreach ($f in $allFiles) { Classify-File $f }
  )


  $total = $classified.Count

  $readables = $classified | Where-Object {
    -not $_.HiddenDirRel -and -not $_.IsHiddenFile -and -not $_.IsRedacted -and $_.SizeBytes -le $maxBytes
  }

  $readMap = $readables | ForEach-Object -Parallel {
    # パラレル側では $using: を使う
    $full = $_.FullName
    $rel = $_.Rel

    # バイナリ判定→テキスト読み込み
    $isBin = $false
    $fs = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $buf = New-Object byte[] $using:script:BinaryDetectionBufferSize
      $read = $fs.Read($buf, 0, $buf.Length)
      for ($i = 0; $i -lt $read; $i++) { if ($buf[$i] -eq 0) { $isBin = $true; break } }
    }
    finally { $fs.Dispose() }

    if ($isBin) {
      return [pscustomobject]@{ Rel = $rel; Kind = "Binary"; Content = $null }
    }

    $fs2 = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $reader = New-Object System.IO.StreamReader($fs2, [System.Text.Encoding]::UTF8, $true, 4096, $true)
      
      $isCsv = $rel.EndsWith(".csv", [StringComparison]::OrdinalIgnoreCase)
      $limit = if ($isCsv) { $using:CsvPreviewLines } else { 0 }
      $text = $null

      if ($limit -gt 0) {
        $acc = New-Object System.Collections.Generic.List[string]
        $max = $limit
        while ($max -gt 0 -and -not $reader.EndOfStream) {
          $line = $reader.ReadLine()
          if ($null -eq $line) { break }
          $acc.Add($line) | Out-Null
          $max--
        }
        if (-not $reader.EndOfStream) {
          $acc.Add("... (truncated first $limit lines)") | Out-Null
        }
        $text = ($acc -join [Environment]::NewLine)
      }
      else {
        $text = $reader.ReadToEnd()
      }

      $reader.Dispose()
      $det = @(Detect-SensitiveContent $text)
      if ($det.Count -gt 0) {
        return [pscustomobject]@{ Rel = $rel; Kind = "Sensitive"; Detections = $det }
      }
      return [pscustomobject]@{ Rel = $rel; Kind = "Text"; Content = $text }
    }
    finally { $fs2.Dispose() }
  } -ThrottleLimit $ThrottleLimit

  # Rel -> read result
  $readDict = @{}
  foreach ($r in $readMap) { $readDict[$r.Rel] = $r }

  for ($i = 0; $i -lt $classified.Count; $i++) {
    $c = $classified[$i]
    if ($ShowProgress) {
      $pct = [int](($i + 1) * 100 / [Math]::Max(1, $total))
      Write-Progress -Activity "ファイル処理中" -Status "$($i+1)/$total" -PercentComplete $pct
    }

    # ディレクトリ単位非表示
    if ($c.HiddenDirRel) {
      if (-not $writtenHiddenDir.Contains($c.HiddenDirRel)) {
        $results.Add([pscustomobject]@{ Order = $i; Type = "HiddenDir"; Rel = $c.HiddenDirRel }) | Out-Null
        [void]$writtenHiddenDir.Add($c.HiddenDirRel)
      }
      continue
    }

    if ($c.IsHiddenFile) { $results.Add([pscustomobject]@{ Order = $i; Type = "HiddenFile"; Rel = $c.Rel }) | Out-Null; continue }
    if ($c.IsRedacted) { $results.Add([pscustomobject]@{ Order = $i; Type = "Redacted"; Rel = $c.Rel }) | Out-Null; continue }

    if ($c.SizeBytes -gt $maxBytes) { $results.Add([pscustomobject]@{ Order = $i; Type = "TooLarge"; Rel = $c.Rel; Size = $c.SizeBytes }) | Out-Null; continue }

    $rr = $readDict[$c.Rel]
    if ($null -eq $rr) {
      # 読み対象でない＝ここには来ないはずだが保険
      $results.Add([pscustomobject]@{ Order = $i; Type = "Skipped"; Rel = $c.Rel }) | Out-Null
      continue
    }

    if ($rr.Kind -eq "Binary") {
      $results.Add([pscustomobject]@{ Order = $i; Type = "Binary"; Rel = $c.Rel }) | Out-Null
      continue
    }

    if ($rr.Kind -eq "Sensitive") {
      $DetectedSecretMap[$c.Rel] = $rr.Detections
      $results.Add([pscustomobject]@{ Order = $i; Type = "Sensitive"; Rel = $c.Rel; Detections = $rr.Detections }) | Out-Null
      continue
    }

    $results.Add([pscustomobject]@{
        Order = $i; Type = "Text"; Rel = $c.Rel; FullName = $c.FullName; Name = $c.Name; Content = $rr.Content
      }) | Out-Null
  }

  if ($ShowProgress) { Write-Progress -Activity "ファイル処理中" -Completed }
}
else {
  Write-Host "[DEBUG] Mode: Serial (PS5.1 or requested)"
  # 直列版（読みやすさ優先）
  $total = $allFiles.Count
  for ($i = 0; $i -lt $allFiles.Count; $i++) {
    $fileInfo = $allFiles[$i]
    Write-Host "[DEBUG] Processing ($($i+1)/$total): $($fileInfo.Name)"
    $c = Classify-File $fileInfo

    if ($ShowProgress) {
      $pct = [int](($i + 1) * 100 / [Math]::Max(1, $total))
      Write-Progress -Activity "ファイル処理中" -Status "$($i+1)/$total" -PercentComplete $pct
    }

    if ($c.HiddenDirRel) {
      if (-not $writtenHiddenDir.Contains($c.HiddenDirRel)) {
        $results.Add([pscustomobject]@{ Order = $i; Type = "HiddenDir"; Rel = $c.HiddenDirRel }) | Out-Null
        [void]$writtenHiddenDir.Add($c.HiddenDirRel)
      }
      continue
    }

    if ($c.IsHiddenFile) { $results.Add([pscustomobject]@{ Order = $i; Type = "HiddenFile"; Rel = $c.Rel }) | Out-Null; continue }
    if ($c.IsRedacted) { $results.Add([pscustomobject]@{ Order = $i; Type = "Redacted"; Rel = $c.Rel }) | Out-Null; continue }

    if ($c.SizeBytes -gt $maxBytes) { $results.Add([pscustomobject]@{ Order = $i; Type = "TooLarge"; Rel = $c.Rel; Size = $c.SizeBytes }) | Out-Null; continue }

    if (Test-IsProbablyBinary $c.FullName) { $results.Add([pscustomobject]@{ Order = $i; Type = "Binary"; Rel = $c.Rel }) | Out-Null; continue }

    $limit = 0
    if ($c.Name.EndsWith(".csv", [StringComparison]::OrdinalIgnoreCase)) { $limit = $CsvPreviewLines }

    $text = Read-TextFileAutoEncoding $c.FullName $limit
    $detected = @(Detect-SensitiveContent $text)
    if ($detected.Count -gt 0) {
      $DetectedSecretMap[$c.Rel] = $detected
      $results.Add([pscustomobject]@{ Order = $i; Type = "Sensitive"; Rel = $c.Rel; Detections = $detected }) | Out-Null
      continue
    }
    $results.Add([pscustomobject]@{
        Order = $i; Type = "Text"; Rel = $c.Rel; FullName = $c.FullName; Name = $c.Name; Content = $text
      }) | Out-Null
  }

  if ($ShowProgress) { Write-Progress -Activity "ファイル処理中" -Completed }
}

# ---------------------------
# Markdown 出力組み立て（順序維持）
# ---------------------------
$results = @($results.ToArray())
$tree = Get-TreeLines $rootFull $DetectedSecretMap

$sb = New-Object System.Text.StringBuilder
foreach ($l in $tree) { [void]$sb.AppendLine($l) }
[void]$sb.AppendLine("## Files")
[void]$sb.AppendLine("")

foreach ($r in $results) {
  switch ($r.Type) {
    "HiddenDir" {
      [void]$sb.AppendLine("### $($r.Rel)/")
      [void]$sb.AppendLine("")
      [void]$sb.AppendLine("> ディレクトリごと本文非表示（存在のみ記録）")
      [void]$sb.AppendLine("")
    }
    "HiddenFile" {
      [void]$sb.AppendLine("### $($r.Rel)")
      [void]$sb.AppendLine("")
      [void]$sb.AppendLine("> ファイル本文非表示（対象:ビルド成果物/バイナリ/巨大アセット等）")
      [void]$sb.AppendLine("")
    }
    "Redacted" {
      [void]$sb.AppendLine("### $($r.Rel)")
      [void]$sb.AppendLine("")
      [void]$sb.AppendLine("> 機微情報につき非表示（存在のみ記録）")
      [void]$sb.AppendLine("")
    }
    "Sensitive" {
      $det = $(if ($r.Detections) { ($r.Detections -join ", ") } else { "検出" })
      [void]$sb.AppendLine("### $($r.Rel)")
      [void]$sb.AppendLine("")
      [void]$sb.AppendLine("> 機微情報を検出したため本文非表示（検出項目: $det）")
      [void]$sb.AppendLine("")
    }
    "TooLarge" {
      [void]$sb.AppendLine("### $($r.Rel)")
      [void]$sb.AppendLine("")
      [void]$sb.AppendLine("> Skipped: file size $([Math]::Round($r.Size/1MB,2)) MB exceeds limit ($MaxFileSizeMB MB).")
      [void]$sb.AppendLine("")
    }
    "Binary" {
      [void]$sb.AppendLine("### $($r.Rel)")
      [void]$sb.AppendLine("")
      [void]$sb.AppendLine("> Skipped: detected as binary.")
      [void]$sb.AppendLine("")
    }
    "Text" {
      $ext = [System.IO.Path]::GetExtension($r.Name)
      $lang = Get-LangFromExtension $ext

      [void]$sb.AppendLine("### $($r.Rel)")
      [void]$sb.AppendLine("")
      [void]$sb.AppendLine("````$lang")
      [void]$sb.AppendLine(($r.Content).TrimEnd("`r", "`n"))
      [void]$sb.AppendLine("````")
      [void]$sb.AppendLine("")
    }
    default {
      [void]$sb.AppendLine("### $($r.Rel)")
      [void]$sb.AppendLine("")
      [void]$sb.AppendLine("> Skipped.")
      [void]$sb.AppendLine("")
    }
  }
}

# ---------------------------
# 出力
# ---------------------------
$dirOut = Split-Path -Parent $OutPath
if ($dirOut -and -not (Test-Path -LiteralPath $dirOut)) {
  New-Item -ItemType Directory -Path $dirOut | Out-Null
}
[System.IO.File]::WriteAllText($OutPath, $sb.ToString(), [System.Text.Encoding]::UTF8)

if ($DetectedSecretMap.Count -gt 0) {
  Write-Host "Sensitive content detected in:"
  foreach ($path in ($DetectedSecretMap.Keys | Sort-Object)) {
    $label = ($DetectedSecretMap[$path] -join ", ")
    Write-Host " - $path ($label)"
  }
}

Write-Host "Wrote: $OutPath"
