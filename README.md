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

### Basic Usage

```powershell
./RepoDump.ps1 -RootPath "C:\Projects\MyApp"
