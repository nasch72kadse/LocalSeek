<p align="center">
  <img src="Apps/LocalSeek/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" width="96" height="96" alt="LocalSeek">
</p>

<h1 align="center">LocalSeek</h1>

<p align="center"><strong>Find files by name, content, or meaning. Keep the search on your Mac.</strong></p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&logoColor=white" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple_Silicon-M1%2B-2563eb" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Search-on_device-0f766e" alt="On-device search">
</p>

<p align="center">
  <a href="https://github.com/nasch72kadse/LocalSeek/releases">Downloads</a> ·
  <a href="docs/INSTALLATION.md">Installation</a> ·
  <a href="docs/BUILDING.md">Build from source</a> ·
  <a href="docs/ARCHITECTURE.md">How it works</a>
</p>

LocalSeek is a native macOS menu bar app for searching folders you choose. It combines
file-name search, full-text search, and multilingual semantic search using a local
embedding model. Document processing and searches run on your Mac, without a cloud API
or a separate search server.

## Highlights

- **Search beyond file names.** Combine exact content matches with semantic similarity,
  including questions in one language and documents in another.
- **Read documents and scans.** Extract text from PDFs, Office files, email, text files,
  and images. Apple Vision handles OCR in an isolated helper process.
- **Keep up with changes.** Process file-system events, preserve unchanged embeddings,
  cache OCR results, and resume queued work after a restart.
- **Search larger collections.** SQLite/FTS5 stores the index; an optional in-memory
  HNSW index accelerates vector search when the collection grows.
- **Work from the keyboard.** Open search with **⌘⇧Space**, filter results, preview files,
  mark favorites, and reveal originals in Finder.
- **Install once.** The DMG includes the model, OCR helper, native libraries, and Metal
  components. End users do not need Homebrew, Python, Ollama, or developer tools.

## Get started

1. Open [Releases](https://github.com/nasch72kadse/LocalSeek/releases) and download the
   `.dmg` from the version you want to try. Development builds are marked **Pre-release**.
2. Open the DMG, drag **LocalSeek.app** to **Applications**, and launch it.
3. Choose the folders to index during setup or in Settings.
4. Press **⌘⇧Space** and start searching. The shortcut can be changed in Settings.

**Requirements:** Apple Silicon (M1 or later), macOS 14 or later. Intel Macs, Windows,
and Linux are not supported. The current build has been exercised on an Apple M3 with
macOS 27.0.1; macOS 14/M1 remain deployment targets without a separate runtime validation.

See the [installation guide](docs/INSTALLATION.md) for signing details and troubleshooting.

## Search your way

Use file-name search or choose **Hybrid**, **Exact**, or **Semantic** content search.
Filters can be combined with a query or used on their own:

```text
backup procedure ext:pdf path:Projects after:2026-01-01 minsize:1MB
favorite:true
```

Available filters: `ext:`, `type:`, `path:`, `before:`, `after:`, `minsize:`,
`maxsize:`, `source:`, and `favorite:true`.

Press **Return** to open the original, **Space** outside the text field for a preview,
or **Esc** to close search. The context menu can reveal a file in Finder or copy its path.
Search, menus, and settings currently use German labels.

## Supported content

| Format | Indexed content |
| --- | --- |
| PDF | Embedded text and OCR for scanned pages |
| DOCX | Paragraphs, headings, tables, headers, footers, comments, and footnotes |
| PPTX | Slide text, slide order, and notes |
| XLSX | Cell values, formulas, and stored calculation results |
| TXT, CSV, TSV, Markdown, JSON, XML, YAML | Text and structured text |
| HTML, RTF, EML | Extracted text; common MIME structures for email |
| Raster images | OCR through Apple Vision |

Legacy Office formats, Apple iWork files, arbitrary ZIP archives, and email attachments
are not indexed. See [extraction limits](docs/ARCHITECTURE.md#extraction-limits) for bounds
and format-specific limitations.

## Privacy and offline behavior

LocalSeek does not send document contents or search queries to a cloud search service.
The downloaded app uses its bundled model; it does not download one during normal use.
The first source build does need internet access for pinned dependencies and the model.

The local index contains extracted document text. It lives in
`~/Library/Application Support/LocalSeek/` and should be protected like the original files.
Diagnostic exports omit document contents, file paths, and search queries.

Indexing does not download cloud-only placeholders. Previously indexed content can
remain searchable while a source is offline. Opening an original file is an explicit
action and may cause its cloud file provider to download it.

## Development

`dev` is the development branch; `main` is reserved for promoted versions. The build
and local release guides describe the current **`dev`** tooling. Switch to `dev` before
following them.

```bash
git clone https://github.com/nasch72kadse/LocalSeek.git
cd LocalSeek
git switch dev
```

Start with the [build guide](docs/BUILDING.md). Every successful release build produces
`build/LocalSeek.dmg`. Unit and integration tests, bundle checks, and an offline self-test
guard the release path.

| Guide | What it covers |
| --- | --- |
| [Installation](docs/INSTALLATION.md) | Install the app on another Mac |
| [Building and testing](docs/BUILDING.md) | Dependencies, model setup, tests, and packaging |
| [Architecture](docs/ARCHITECTURE.md) | Indexing, OCR isolation, search, and resource limits |
| [GitHub Actions](docs/GITHUB-ACTIONS.md) | Hosted builds, artifacts, and Apple signing secrets |
| [Local releases](docs/LOCAL-RELEASE.md) | Sign, notarize, and publish from your own Mac |
| [Contributing](CONTRIBUTING.md) | Changes, bug reports, and validation |
| [Security](SECURITY.md) | Handling sensitive reports and local data |

## License

The project code does **not** currently have an open-source license. See [LICENSE](LICENSE)
for its existing terms. Bundled dependencies and the model retain their own licenses;
see [third-party notices](THIRD_PARTY_NOTICES.md).
