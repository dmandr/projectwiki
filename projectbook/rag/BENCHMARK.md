# Local retrieval experiment: 2026-10-24

## Environment

- Mac: Apple M3 Max, 16 CPU cores, 64 GiB RAM.
- Docker Desktop Linux ARM64 VM: 16 CPUs, approximately 23.4 GiB RAM available to Docker.
- Indexer capped at 4 CPUs/4 GiB; Qdrant at 2 CPUs/2 GiB. CPU-only ONNX inference, batch size 16, four model threads. No GPU or cloud model API.
- Quantized multilingual MiniLM, 384-dimensional vectors, pinned model revision and package/image versions in the experiment sources.

## Full indexing (no extraction/embedding cache)

| Measurement | Observed |
| --- | ---: |
| Input | 101 Markdown files + 29 PDFs (209,255,586 PDF bytes) |
| Indexed | All 101 Markdown files + text from 24 PDFs |
| PDF pages parsed | 1,218 |
| PDF pages with no extracted text | 17 |
| Searchable vector chunks | 9,773 |
| Full pass, model files already downloaded | **249.450 seconds (4 min 9 sec)** |
| Text extraction | 57.954 seconds |
| Token windows and embedding generation | 180.980 seconds |
| Qdrant uploads | 1.057 seconds |
| Other time | Git reads, cache serialization, generation setup/publication |
| Model initialization in that pass | 0.436 seconds |
| Initial model download/load observed in setup | 25.351 seconds; network-dependent, separate from full pass |
| Sampled peak indexer Docker memory usage | About 1.54 GiB |
| Sampled peak Qdrant Docker memory usage | 243.6 MiB |
| Sampled peak indexer CPU | About 400% (four cores) |
| Model cache on disk | About 241 MiB |
| Generated state/cache | About 47 MiB at measurement |
| Qdrant storage | About 85 MiB, including retained generations |

The full pass had zero cache hits. A few diagnostic requests/tests ran while indexing, so this is an end-to-end operational measurement, not an isolated CPU microbenchmark. Container memory sampling was every ~10 seconds and can miss shorter peaks. An observed cgroup high-water mark was about 1.64 GiB including memory accounted by the cgroup.

All 29 PDFs opened after enabling AES support and a Poppler fallback. 24 supplied text. Five files (including three copies of one document) supplied none; no OCR was attempted. Two manuals required the AES dependency; one complex 24-page PDF used Poppler after pypdf hit its stream token limit. Empty pages can be decorative/blank or scanned. Text extraction does not guarantee preservation of tables, layout, or reading order.

## Cached regeneration and search

- Forced regeneration at the same Git revision: **2.094 seconds**, 130 cache hits, no text extraction or embedding inference, 0.874 seconds uploading vectors. This is a new Qdrant generation from cached data, not a full re-embedding. Normal polling of an unchanged revision skips generation entirely.
- Six Russian/English queries in each mode, including engine maintenance, charging controls and radio documentation. Small exploratory set, not a recall/precision benchmark.
- Semantic search: median **6.1 ms**, maximum **687.2 ms** including the first model/load/index warm-up request after restart.
- Hybrid search: median **11.4 ms**, maximum **12.1 ms** with the model warm.
- Keyword search: median **6.3 ms**, maximum **6.6 ms**.
- Two scoped end-to-end MCP requests from the Mac: **37 ms and 38 ms** with warm services.

Service timings exclude agent reasoning and remote network latency. Results included useful engine Markdown and English PDF sections for Russian queries, but also irrelevant neighboring hits. This compact model is a baseline; ranking needs user evaluation. No reranker, stemming, OCR or semantic quality guarantee is implied.

## Reproduce and interpret

Use `rag.sh start`, `status`, `benchmark`; `rebuild` measures regeneration using available caches. `clean` removes this experiment's generated volumes only, allowing a new cold setup/full index, and also requires downloading the model again. Keep full indexing, cached regeneration, model download and image build timings separate.

Detailed results with private book paths live in ignored `projectbook/.runtime/rag-index-full.json`, `rag-index-cached.json` and `rag-benchmark-full.json`, and in the generated `/state` volume. They must not be committed to the public app repository.

For cloud planning this establishes that this test corpus takes minutes on this CPU allocation, not days. It does not establish AWS/Raspberry throughput: run the same workload on the actual target CPU. Embedding throughput here was about 54 chunks/s, including token preparation, and end-to-end full-pass throughput about 39 chunks/s; chunk length/distribution matters more than document count alone.
