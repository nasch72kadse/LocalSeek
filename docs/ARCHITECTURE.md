# Architecture and indexing behavior

This guide describes the current `dev` implementation. LocalSeek runs as a macOS
menu bar app with a local SQLite index, a native embedding bridge, and an isolated OCR helper.

## Data flow

```mermaid
flowchart LR
    F[Selected folders] --> S[Metadata scan and file events]
    S --> Q[Persistent job queue]
    Q --> E[Content extraction]
    E --> O[Isolated OCR helper]
    E --> C[Text chunks]
    O --> C
    C --> M[Local E5 embeddings]
    M --> D[(SQLite and FTS5)]
    C --> D
    D --> R[Exact and hybrid search]
    D --> H[Optional in-memory HNSW index]
    H --> R
```

SQLite is the authoritative data store. Extracted text, embeddings, file metadata,
job progress, and OCR cache entries are persisted locally. HNSW is an acceleration
structure that can be rebuilt; it is not the source of truth.

## Incremental indexing

File-system events normally schedule work for an individual file or a relevant
subtree. Disjoint directory events keep separate scopes; all scopes are upserted
before deletions are reconciled so cross-folder renames retain their IDs. Events are persisted with revisions so a newer change is not lost when an
older job completes. Lost events or large bursts cause a broader reconciliation.
Startup and periodic maintenance also reconcile metadata.

Unchanged metadata avoids unnecessary writes. Content versions use modification
time, size, and file identity. Changes that preserve all three cannot be detected by
that check; LocalSeek does not hash every original file during every scan.
Unchanged extracted text can reuse existing vectors.

Renames preserve IDs and vectors when device/inode identity and the confirmed absence
of the old path establish the match. Partial or failed scans do not delete cached results.
Cloud-only placeholders are not materialized for indexing.

One background job is active at a time. Metadata traversal retains its enumerator
between slices of at most 256 entries or approximately one second, then lets other
sources and content jobs proceed. A file event invalidates an overlapping full scan
so a stale generation cannot delete the newly observed row. Restarting the process
starts a fresh scan generation; partial generations never authorize deletion.

Content work yields between batches of up to
eight files or two seconds; embedding work yields between batches of up to 64 chunks
or two seconds. Up to four texts share an embedding invocation. These budgets do not
interrupt a parser or an inference call already in progress. PDFs process up to 16
pages or the remaining time budget per slice. Completed pages, metadata stamps, OCR
keys, and the next page are persisted in SQLite. A restart can resume that work;
changes to the file invalidate it. Existing successful content stays searchable until
the replacement is complete. One in-flight OCR call can still use its page timeout.
Status counts use coalesced asynchronous database snapshots, and favorite IDs are
re-read only when a transactional revision changes.

## OCR isolation

Apple Vision runs in the bundled `LocalSeekOCR` process. The parent passes private
temporary raster snapshots rather than original source paths or database access.
It can kill a stalled helper without blocking the indexing queue indefinitely.

On `dev`, accurate OCR has a bounded attempt of up to ten seconds. If it stalls, a
fresh helper retries with fast OCR assigned to the CPU. Both attempts share a
30-second budget per image or scanned PDF page. The fallback can be less accurate
and supports fewer languages. German and English use real image fixtures in tests.

Cancellation and deadlines terminate the helper. Failures are recorded per file
with bounded retries; previous successful content is retained and the queue continues.

Successful OCR is cached by raster bytes, language, OCR version, and macOS version.
The cache allows up to 64 MiB of JSON payload and 32,768 entries, with an inactivity
limit of 30 days. SQLite overhead is additional. PDF rendering is still required;
failed OCR is not cached as a successful result.

## Search

- File-name search uses indexed file metadata.
- Exact content search uses SQLite FTS5/BM25.
- Semantic search embeds the query with the local multilingual E5 model.
- Hybrid search combines full-text and vector results at document level.
- Exact and vector candidate limits count distinct files, retaining each file's best
  chunk. A long PDF cannot fill the candidate set and hide smaller matching files.
- Filename queries use GRDB's cancellation-aware asynchronous readers. Superseded
  queries interrupt their own SQL work without cancelling unrelated readers.

For collections of at least 50,000 vectors, a background task may build a HNSW graph
in memory. Its estimated budget is one eighth of physical RAM, capped at 2 GiB.
Memory pressure discards the graph; it is rebuilt after restarting the app.

Exact vector search remains available while the graph is unavailable or when
revision tracking or memory limits prevent its use. Filtered queries can use HNSW:
small eligible subsets use an exact search directly; broader filters expand
the graph candidate set up to 8,192 vectors. Candidates are checked against current database
filters and visibility, and is reranked using exact similarity. If too few eligible
documents or chunks survive, an exact filtered search fills the request.
Approximate candidate selection does not guarantee perfect top-k recall.

## Extraction limits

| Boundary | Limit |
| --- | --- |
| Input file / expanded Office archive | 50 MiB |
| Individual ZIP part | 16 MiB |
| ZIP entries | 20,000 |
| XML elements / nesting depth | 500,000 / 128 |
| PDF pages | 1,000 |
| OCR raster edge | 4,096 pixels |
| Email MIME depth / parts | 12 / 200 |
| Cumulative email raw-part processing | 200 MiB |

DTDs and external XML entities are rejected. Office features such as SmartArt or
linked objects are not fully covered. Email extraction does not decrypt S/MIME or
PGP content and does not index attachments. XLSX extraction reads stored results;
it does not recalculate workbooks.

## Storage and resource use

The index is stored under `~/Library/Application Support/LocalSeek/`. The directory
uses mode `0700`; database/WAL/SHM files use `0600`. Extracted content makes the index
sensitive even when diagnostics omit document text, paths, and queries.

Jobs resume from persistent state after interruption. Maintenance performs periodic
reconciliation and integrity checks. Model contexts are released after 120 seconds
of inactivity. Thermal state, low-power mode, and optional battery pauses reduce work,
but do not impose a strict CPU-percentage limit on Apple framework calls.

Indexing speed depends on file count and format, extracted chunk count, scan/OCR work,
storage latency, CPU/GPU resources, available memory, and cloud file-provider state.
A collection of text files and an equally sized collection of scanned PDFs are
different workloads. Native component benchmarks should not be treated as end-to-end
measurements or a substitute for testing a representative collection.
