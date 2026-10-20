# Third-party notices

The terms for LocalSeek's own code are stated in [LICENSE](LICENSE). This document
does not grant additional rights to that code. Third-party components retain their
respective licenses.

| Component | Pinned version | License and source |
| --- | --- | --- |
| llama.cpp, including ggml | v0.6.0, `d81235049384534c167caea52b85a694f6103d14`; bundled ggml 0.26.0 | [MIT](Licenses/llama.cpp-MIT.txt) · [upstream](https://github.com/ggml-org/llama.cpp) |
| hnswlib | v0.9.0, `d9b3608c83d83b46c96e25088cb1d729b29dcfe9`; unmodified headers | [Apache-2.0](Licenses/hnswlib-APACHE.txt) · [upstream](https://github.com/nmslib/hnswlib) |
| GRDB.swift | 7.11.1, `b83108d10f42680d78f23fe4d4d80fc88dab3212` | [MIT](Licenses/GRDB-MIT.txt) · [upstream](https://github.com/groue/GRDB.swift) |
| ZIPFoundation | 0.9.20, `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` | [MIT](Licenses/ZIPFoundation-MIT.txt) · [upstream](https://github.com/weichsel/ZIPFoundation) |
| multilingual-e5-small | intfloat model; Q8 GGUF conversion by TwinSunsLLC | [MIT](Licenses/multilingual-e5-MIT.txt) · [model](https://huggingface.co/intfloat/multilingual-e5-small) · [conversion](https://huggingface.co/TwinSunsLLC/multilingual-e5-small-gguf) |

[The model manifest](Models/manifest.json) records provenance and SHA-256. Packaging
copies a verified local model into the app; the app does not download it at runtime.
Apple frameworks and SQLite are supplied by macOS.

Additional notices from llama.cpp cover [xxHash](Licenses/xxHash-BSD2.txt)
(BSD-2-Clause), [SHA256](Licenses/SHA256-Public-domain.txt) (public domain), and
[rotate-bits](Licenses/rotate-bits-MIT.txt) (MIT). License texts remain in `Licenses/`.
