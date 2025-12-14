param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$RootPath,

  [string]$OutPath = (Join-Path (Get-Location) "dump.md"),

  # ========== “ディレクトリごと” 本文を非表示（ツリーには残す） ==========
  [string[]]$HideDirNames = @(
    ".git",".svn",".hg",
    "node_modules","bower_components","vendor",
    "dist","build","out",".next",".nuxt",".svelte-kit",
    ".turbo",".cache",".parcel-cache",
    "coverage",".nyc_output",
    "bin","obj","target",
    ".venv","venv","__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ".gradle",".idea",".vscode",
    ".terraform",".terragrunt-cache"
  ),

  # ========== “ファイル単体” 本文を非表示（ツリーには残す） ==========
  [string[]]$HideFilePatterns = @(
    "*.exe","*.dll","*.so","*.dylib","*.a","*.lib",
    "*.pdb","*.obj","*.o","*.class","*.jar","*.war",
    "*.png","*.jpg","*.jpeg","*.gif","*.webp","*.ico","*.svg",
    "*.mp4","*.mov","*.mkv","*.avi","*.mp3","*.wav","*.flac",
    "*.zip","*.7z","*.rar","*.tar","*.gz","*.bz2","*.xz",
    "*.pdf","*.doc","*.docx","*.ppt","*.pptx","*.xls","*.xlsx",
    "*.ttf","*.otf","*.woff","*.woff2",
    "*.db","*.sqlite","*.sqlite3",
    "*.log"
  ),

  # ========== 機微情報: “存在は示すが本文は伏せる” ==========
  [string[]]$RedactFilePatterns = @(
    ".env","*.env",".env.*",
    "*.pem","*.key","*.pfx","*.p12","*.kdbx",
    "id_rsa","id_ed25519","known_hosts",
    ".npmrc",".pypirc",".dockerconfigjson"
  ),
  [string[]]$RedactDirNames = @(".aws",".ssh",".gnupg"),

  # envでも中身を出してよい例外
  [string[]]$AllowEnvNames = @(".env.sample",".env.example",".env.template"),

  # 念のため（巨大ファイル・バイナリ）
  [int]$MaxFileSizeMB = 5,

  # ========== 改善: .gitignore 簡易取り込み ==========
  [switch]$UseGitignore,

  # ========== 改善: 進捗表示 ==========
  [switch]$ShowProgress,

  # ========== 改善: PS7 での並列読み込み（順序は維持） ==========
  [switch]$ParallelRead,
  [int]$ThrottleLimit = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------
# 定数（マジックナンバー排除）
# ---------------------------
$script:BinaryDetectionBufferSize = 4096

# ---------------------------
# 小物ユーティリティ
# ---------------------------
function Resolve-FullPath([string]$p) { (Resolve-Path -LiteralPath $p).Path }

function Normalize-Rel([string]$rel) { $rel.Replace("\","/") }

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
  $parts = $relPath -split "[\\/]"
  if ($parts.Count -gt 1) {
    foreach ($p in $parts[0..($parts.Count-2)]) {
      if (Is-NameIn $p $dirNames) { return $true }
    }
  }
  $leaf = $parts[-1]
  if (Is-MatchAnyPattern $leaf $filePatterns) { return $true }
  return $false
}

function Get-LangFromExtension([string]$ext) {
  switch ($ext.ToLowerInvariant()) {
    ".ps1" { "powershell" } ".psm1" { "powershell" } ".psd1" { "powershell" }
    ".js"  { "javascript" } ".ts"  { "typescript" } ".tsx" { "tsx" } ".jsx" { "jsx" }
    ".py"  { "python" } ".rb" { "ruby" } ".go" { "go" } ".rs" { "rust" }
    ".java"{ "java" } ".cs" { "csharp" } ".cpp" { "cpp" } ".c" { "c" } ".h" { "c" } ".hpp" { "cpp" }
    ".json"{ "json" } ".yml" { "yaml" } ".yaml" { "yaml" } ".xml" { "xml" }
    ".md"  { "markdown" } ".html"{ "html" } ".css" { "css" } ".sql" { "sql" }
    default { "" }
  }
}

function Test-IsProbablyBinary([string]$filePath) {
  # “意図”: 先頭数KBにNULLバイトが混ざるならバイナリ扱い（高速で雑に強い）
  $fs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $buf = New-Object byte[] $script:BinaryDetectionBufferSize
    $read = $fs.Read($buf, 0, $buf.Length)
    for ($i=0; $i -lt $read; $i++) { if ($buf[$i] -eq 0) { return $true } }
    return $false
  } finally { $fs.Dispose() }
}

function Read-TextFileAutoEncoding([string]$filePath) {
  # “意図”: BOMがあれば尊重、なければUTF-8優先で読む（不明は置換で落とさない）
  $fs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true, 4096, $true)
    $text = $reader.ReadToEnd()
    $reader.Dispose()
    return $text
  } finally { $fs.Dispose() }
}

# ---------------------------
# .gitignore（簡易）取り込み
# ---------------------------
function Convert-GitignoreToLikePatterns([string]$rootFull) {
  $gi = Join-Path $rootFull ".gitignore"
  if (-not (Test-Path -LiteralPath $gi)) { return [pscustomobject]@{ DirNames=@(); FilePatterns=@() } }

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
      $name = $line.TrimEnd("/").Split("/","\")[-1]
      if ($name) { $dirNames.Add($name) | Out-Null }
      continue
    }

    # それ以外は “-like でそれっぽく” 使う（完全互換ではない）
    $pat = $line.Replace("/", "*").Replace("\", "*")
    if ($pat -notlike "*`**") { } # 何もしない（見た目の保険）
    if ($pat -notlike "*") { $pat = "*$pat*" }
    $filePats.Add($pat) | Out-Null
  }

  return [pscustomobject]@{
    DirNames      = $dirNames.ToArray()
    FilePatterns  = $filePats.ToArray()
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
  $HideDirNames      = @($HideDirNames + $gi.DirNames)
  $HideFilePatterns  = @($HideFilePatterns + $gi.FilePatterns)
}

# “伏せたディレクトリ” を Files セクションで 1回だけ説明するための集合
$HiddenDirRelSet = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)

function Get-TreeLines([string]$rootFull) {
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Dump")
  $lines.Add("")
  $lines.Add("## Tree")
  $lines.Add("")
  $lines.Add("```text")
  $lines.Add((Split-Path -Leaf $rootFull))

  function Walk([string]$dir, [string]$prefix, [string]$relFromRoot) {
    $children = Get-ChildItem -LiteralPath $dir -Force | Sort-Object @{Expression="PSIsContainer";Descending=$true}, Name

    for ($i=0; $i -lt $children.Count; $i++) {
      $item = $children[$i]
      $isLast = ($i -eq $children.Count - 1)
      $branch = if ($isLast) { "└─ " } else { "├─ " }
      $nextPrefix = $prefix + (if ($isLast) { "   " } else { "│  " })

      if ($item.PSIsContainer) {
        $childRel = if ([string]::IsNullOrEmpty($relFromRoot)) { $item.Name } else { "$relFromRoot/$($item.Name)" }

        if (Is-NameIn $item.Name $HideDirNames) {
          $lines.Add("$prefix$branch$($item.Name)/ [DIR:本文非表示]")
          [void]$HiddenDirRelSet.Add($childRel)
          continue
        }

        $lines.Add("$prefix$branch$($item.Name)/")
        Walk $item.FullName $nextPrefix $childRel
      }
      else {
        $leafRel = if ([string]::IsNullOrEmpty($relFromRoot)) { $item.Name } else { "$relFromRoot/$($item.Name)" }
        $tag = ""

        if (Is-MatchAnyPattern $item.Name $HideFilePatterns) { $tag = " [FILE:本文非表示]" }
        elseif (Test-PathMatchesPattern $leafRel $RedactDirNames $RedactFilePatterns -and -not (Is-NameIn $item.Name $AllowEnvNames)) { $tag = " [機微:本文非表示]" }

        $lines.Add("$prefix$branch$($item.Name)$tag")
      }
    }
  }

  Walk $rootFull "" ""
  $lines.Add("```")
  $lines.Add("")
  return $lines
}

$tree = Get-TreeLines $rootFull

# 早期フィルタ：-File を使ってまず “ファイルだけ” 列挙（大規模で効く）
$allFiles =
  Get-ChildItem -LiteralPath $rootFull -Recurse -Force -File |
  Sort-Object @{Expression={ $_.DirectoryName };Ascending=$true}, @{Expression={ $_.Name };Ascending=$true}

$sb = New-Object System.Text.StringBuilder
foreach ($l in $tree) { [void]$sb.AppendLine($l) }
[void]$sb.AppendLine("## Files")
[void]$sb.AppendLine("")

$writtenHiddenDir = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)

# 並列読み込みを使う場合も順序は維持したいので、結果は一旦貯める
$results = New-Object System.Collections.Generic.List[psobject]

function Classify-File([System.IO.FileInfo]$fileInfo) {
  $rel = Normalize-Rel ([System.IO.Path]::GetRelativePath($rootFull, $fileInfo.FullName))

  # どの HideDir に属するか（属すなら dirRel を返す）
  $hiddenDirRel = $null
  foreach ($d in $HiddenDirRelSet) {
    if ($rel -like "$d/*") { $hiddenDirRel = $d; break }
  }

  $isHiddenFile = Is-MatchAnyPattern $fileInfo.Name $HideFilePatterns
  $isRedact = (Test-PathMatchesPattern $rel $RedactDirNames $RedactFilePatterns) -and -not (Is-NameIn $fileInfo.Name $AllowEnvNames)

  return [pscustomobject]@{
    Rel = $rel
    HiddenDirRel = $hiddenDirRel
    IsHiddenFile = $isHiddenFile
    IsRedacted   = $isRedact
    SizeBytes    = $fileInfo.Length
    FullName     = $fileInfo.FullName
    Name         = $fileInfo.Name
  }
}

if ($ParallelRead -and $PSVersionTable.PSVersion.Major -ge 7) {
  # まず分類だけは直列で（軽い）。読み込みだけ並列
  $classified = foreach ($f in $allFiles) { Classify-File $f }

  $total = $classified.Count
  $idx = 0

  $readables = $classified | Where-Object {
    -not $_.HiddenDirRel -and -not $_.IsHiddenFile -and -not $_.IsRedacted -and $_.SizeBytes -le $maxBytes
  }

  $readMap = $readables | ForEach-Object -Parallel {
    # パラレル側では $using: を使う
    $full = $_.FullName
    $rel  = $_.Rel

    # バイナリ判定→テキスト読み込み
    $isBin = $false
    $fs = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $buf = New-Object byte[] $using:script:BinaryDetectionBufferSize
      $read = $fs.Read($buf, 0, $buf.Length)
      for ($i=0; $i -lt $read; $i++) { if ($buf[$i] -eq 0) { $isBin = $true; break } }
    } finally { $fs.Dispose() }

    if ($isBin) {
      return [pscustomobject]@{ Rel=$rel; Kind="Binary"; Content=$null }
    }

    $fs2 = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $reader = New-Object System.IO.StreamReader($fs2, [System.Text.Encoding]::UTF8, $true, 4096, $true)
      $text = $reader.ReadToEnd()
      $reader.Dispose()
      return [pscustomobject]@{ Rel=$rel; Kind="Text"; Content=$text }
    } finally { $fs2.Dispose() }
  } -ThrottleLimit $ThrottleLimit

  # Rel -> read result
  $readDict = @{}
  foreach ($r in $readMap) { $readDict[$r.Rel] = $r }

  for ($i=0; $i -lt $classified.Count; $i++) {
    $c = $classified[$i]
    if ($ShowProgress) {
      $pct = [int](($i+1) * 100 / [Math]::Max(1,$total))
      Write-Progress -Activity "ファイル処理中" -Status "$($i+1)/$total" -PercentComplete $pct
    }

    # ディレクトリ単位非表示
    if ($c.HiddenDirRel) {
      if (-not $writtenHiddenDir.Contains($c.HiddenDirRel)) {
        $results.Add([pscustomobject]@{ Order=$i; Type="HiddenDir"; Rel=$c.HiddenDirRel }) | Out-Null
        [void]$writtenHiddenDir.Add($c.HiddenDirRel)
      }
      continue
    }

    if ($c.IsHiddenFile) { $results.Add([pscustomobject]@{ Order=$i; Type="HiddenFile"; Rel=$c.Rel }) | Out-Null; continue }
    if ($c.IsRedacted)   { $results.Add([pscustomobject]@{ Order=$i; Type="Redacted";   Rel=$c.Rel }) | Out-Null; continue }

    if ($c.SizeBytes -gt $maxBytes) { $results.Add([pscustomobject]@{ Order=$i; Type="TooLarge"; Rel=$c.Rel; Size=$c.SizeBytes }) | Out-Null; continue }

    $rr = $readDict[$c.Rel]
    if ($null -eq $rr) {
      # 読み対象でない＝ここには来ないはずだが保険
      $results.Add([pscustomobject]@{ Order=$i; Type="Skipped"; Rel=$c.Rel }) | Out-Null
      continue
    }

    if ($rr.Kind -eq "Binary") {
      $results.Add([pscustomobject]@{ Order=$i; Type="Binary"; Rel=$c.Rel }) | Out-Null
      continue
    }

    $results.Add([pscustomobject]@{
      Order=$i; Type="Text"; Rel=$c.Rel; FullName=$c.FullName; Name=$c.Name; Content=$rr.Content
    }) | Out-Null
  }

  if ($ShowProgress) { Write-Progress -Activity "ファイル処理中" -Completed }
}
else {
  # 直列版（読みやすさ優先）
  $total = $allFiles.Count
  for ($i=0; $i -lt $allFiles.Count; $i++) {
    $fileInfo = $allFiles[$i]
    $c = Classify-File $fileInfo

    if ($ShowProgress) {
      $pct = [int](($i+1) * 100 / [Math]::Max(1,$total))
      Write-Progress -Activity "ファイル処理中" -Status "$($i+1)/$total" -PercentComplete $pct
    }

    if ($c.HiddenDirRel) {
      if (-not $writtenHiddenDir.Contains($c.HiddenDirRel)) {
        $results.Add([pscustomobject]@{ Order=$i; Type="HiddenDir"; Rel=$c.HiddenDirRel }) | Out-Null
        [void]$writtenHiddenDir.Add($c.HiddenDirRel)
      }
      continue
    }

    if ($c.IsHiddenFile) { $results.Add([pscustomobject]@{ Order=$i; Type="HiddenFile"; Rel=$c.Rel }) | Out-Null; continue }
    if ($c.IsRedacted)   { $results.Add([pscustomobject]@{ Order=$i; Type="Redacted";   Rel=$c.Rel }) | Out-Null; continue }

    if ($c.SizeBytes -gt $maxBytes) { $results.Add([pscustomobject]@{ Order=$i; Type="TooLarge"; Rel=$c.Rel; Size=$c.SizeBytes }) | Out-Null; continue }

    if (Test-IsProbablyBinary $c.FullName) { $results.Add([pscustomobject]@{ Order=$i; Type="Binary"; Rel=$c.Rel }) | Out-Null; continue }

    $text = Read-TextFileAutoEncoding $c.FullName
    $results.Add([pscustomobject]@{
      Order=$i; Type="Text"; Rel=$c.Rel; FullName=$c.FullName; Name=$c.Name; Content=$text
    }) | Out-Null
  }

  if ($ShowProgress) { Write-Progress -Activity "ファイル処理中" -Completed }
}

# ---------------------------
# Markdown 出力組み立て（順序維持）
# ---------------------------
$results = $results | Sort-Object Order

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
      [void]$sb.AppendLine(($r.Content).TrimEnd("`r","`n"))
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
Write-Host "Wrote: $OutPath"
