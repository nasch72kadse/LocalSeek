# Install LocalSeek

## Requirements

- A Mac with Apple Silicon (M1 or later).
- macOS 14 or later.
- Enough local space for the app, its bundled model, and the search index.

The current app has been exercised on an Apple M3 running macOS 27.0.1. macOS 14
and M1 are deployment targets without a separate runtime validation. Intel Macs,
Windows, and Linux are not supported.

## Install from a DMG

1. Download the `.dmg` asset from [GitHub Releases](https://github.com/nasch72kadse/LocalSeek/releases).
   Development versions are marked **Pre-release**. Choose a DMG rather than GitHub's
   automatically generated source-code archives.
2. Open the DMG and drag **LocalSeek.app** onto the **Applications** shortcut.
3. Eject the disk image and launch LocalSeek from Applications.
4. Choose the folders to search. macOS may ask for permission to access them.
5. Press **⌘⇧Space** to open search. Indexing continues in the background.

The app includes the search model, OCR helper, native libraries, and Metal components.
You do not need to install Homebrew, Python, Ollama, Xcode, or a separate model.
The app currently uses German interface labels.

## Signing and macOS warnings

Read the release notes to check whether a build is Developer-ID-signed and notarized.
The local publishing workflow requires both before it uploads a release.
Development artifacts from GitHub Actions may be ad-hoc signed instead; they are not
equivalent to a notarized release and macOS may block them.

If macOS cannot verify a download, first confirm that you selected the signed release
asset. A DMG file alone does not establish trust. LocalSeek does not disable Gatekeeper
or change your Mac's security settings. Managed Macs may have additional installation rules.

## First indexing pass

Select only the folders you want to search. The first pass extracts content and
creates local embeddings, so large collections and scanned PDFs can take longer.
Results become available progressively. You can pause indexing from the menu bar.

Cloud-only placeholders are not downloaded for indexing. Opening an original file
can explicitly trigger a download by its file provider. Cached indexed text can remain
searchable while a source is offline.

## Moving to another Mac

Copy the DMG to the other Mac and repeat the installation steps. The package carries
its runtime dependencies, not the original Mac's folders, index, credentials, or preferences.
Select folders and let LocalSeek build a new index on the destination Mac.

## Local data

The index is stored at `~/Library/Application Support/LocalSeek/index.sqlite`.
Model files may also be stored in the adjacent `models/` directory. The index contains
extracted document text and should be protected like the original documents.

See [architecture](ARCHITECTURE.md) for indexing behavior and limits, or
[building](BUILDING.md) to create your own app package.
