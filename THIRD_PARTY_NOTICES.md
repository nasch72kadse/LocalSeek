# Drittanbieter

LocalSeek ist ein privates Projekt; diese Hinweise erteilen keine zusätzliche Lizenz
am eigenen Projektcode. Enthaltene Drittkomponenten behalten ihre jeweiligen Lizenzen.

| Komponente | Gepinnter Stand | Lizenz / Herkunft |
|---|---|---|
| llama.cpp, einschließlich ggml | v0.6.0, `d81235049384534c167caea52b85a694f6103d14`; vendored ggml 0.26.0 | MIT, `Licenses/llama.cpp-MIT.txt`; https://github.com/ggml-org/llama.cpp |
| hnswlib | v0.9.0, `d9b3608c83d83b46c96e25088cb1d729b29dcfe9`, unveränderte Header | Apache-2.0, `Licenses/hnswlib-APACHE.txt`; https://github.com/nmslib/hnswlib |
| GRDB.swift | 7.11.1, `b83108d10f42680d78f23fe4d4d80fc88dab3212` | MIT, `Licenses/GRDB-MIT.txt`; https://github.com/groue/GRDB.swift |
| ZIPFoundation | 0.9.20, `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` | MIT, `Licenses/ZIPFoundation-MIT.txt`; https://github.com/weichsel/ZIPFoundation |
| multilingual-e5-small | intfloat, GGUF-Q8-Konvertierung TwinSunsLLC | MIT laut ursprünglicher Modellkarte; https://huggingface.co/intfloat/multilingual-e5-small und https://huggingface.co/TwinSunsLLC/multilingual-e5-small-gguf |

Die Modellmanifest-Datei enthält Downloadherkunft und SHA-256. Das Modell wird beim
Paketbau aus einer bereits vorhandenen lokalen Datei kopiert, niemals von der App
selbst heruntergeladen. Apple-Systemframeworks und SQLite stammen aus macOS.
Die ursprüngliche MIT-Lizenz des Modells liegt in `Licenses/multilingual-e5-MIT.txt`.

Zusätzlich sind die mitgelieferten Hinweise für xxHash (BSD-2-Clause), SHA256 (Public Domain)
und rotate-bits (MIT) aus dem llama.cpp-Quellbaum in `Licenses/` enthalten.
