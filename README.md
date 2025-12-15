# repo-to-markdown-ps 📄➡️📦

A high-performance PowerShell script that converts an entire project directory into a single Markdown file.
Designed to create **context for LLMs** (ChatGPT, Claude, Gemini, etc.).

## ✨ Features

- **🌲 Visual File Tree**: Generates a clear directory structure at the top.
- **🚫 Smart Filtering**:
  - Respects `.gitignore` (optional).
  - Automatically hides `node_modules`, `.git`, binaries, and build artifacts.
  - **Security Redaction**: Hides contents of secrets (`.env`, private keys) while keeping the file structure.
- **🚀 High Performance**: Supports parallel reading (`-ParallelRead`) for large repositories using PowerShell 7+.
- **📝 Markdown Output**: Code blocks are properly formatted with language extensions for syntax highlighting.

## 🚀 Usage

Download `RepoDump.ps1` and run it in your terminal.

### Setup (Optional)

To customize exclusion rules and redaction patterns, copy `RepoDump.json.example` to `RepoDump.json`:

```powershell
Copy-Item RepoDump.json.example RepoDump.json
```

### Basic Usage

```powershell
./RepoDump.ps1 -RootPath "C:\Projects\MyApp"
```

This generates `dump.md` in the current directory.

### Advanced Usage

```powershell
./RepoDump.ps1 `
  -RootPath "C:\Projects\MyApp" `
  -OutPath "./context.md" `
  -UseGitignore `
  -ParallelRead `
  -ShowProgress
```

## 📦 Batch Dump Tool

For managing multiple context dumps (e.g., separating "Whole Project", "Backend", "Frontend"), use the batch tool provided in the `workspace.example` directory.

### Setup

1. Copy the example workspace to create your own working environment:
   ```powershell
   Copy-Item -Recurse workspace.example workspace
   ```
   The `workspace` directory is ignored by git, providing a clean sandbox for your dumps.

2. Edit `workspace/workspace.json` to define your targets. Paths are relative to the project root.
   ```json
   {
     "Targets": [
       { "Name": "WholeProject", "Path": "." },
       { "Name": "Backend", "Path": "backend" }
     ]
   }
   ```

### Usage

```powershell
cd workspace
./BatchDump.ps1
```

This will generate timestamped markdown files (e.g., `20251216_120000_WholeProject.md`) inside the `workspace` directory.

## ⚙️ Parameters

| Parameter | Description | Default |
| :--- | :--- | :--- |
| `-RootPath` | Target directory path (Required). | - |
| `-OutPath` | Output file path. | `./dump.md` |
| `-UseGitignore` | Use `.gitignore` to exclude files. | `false` |
| `-ParallelRead` | Enable parallel processing (Requires PS 7+). | `false` |
| `-ThrottleLimit` | Concurrency limit for parallel reading. | `4` |
| `-ShowProgress` | Show progress bar during processing. | `false` |
| `-CsvPreviewLines` | Number of lines to preview for CSV files. | `5` |
| `-ConfigFile` | Path to a custom configuration JSON file. | `RepoDump.json` |
| `-MaxFileSizeMB` | Skip files larger than this size. | `5` (MB) |

## 🛡️ Security Note

This script attempts to redact sensitive files (like `.env`, `id_rsa`, `*.pem`) by default. However, **always review the output file** before uploading it to any third-party AI service to ensure no secrets are leaked.

## 📄 License

MIT License
