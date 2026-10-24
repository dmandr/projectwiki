# Experimental local retrieval

Opt-in Docker Compose deployment, separate from the normal wiki. Git remains authoritative; this experiment cannot write the book. The agreed eventual topology is a cloud primary and a read-only boat replica. The Mac is the initial benchmark host. No cloud deployment or index replication is configured here.

## Start, use and rollback

From the application checkout:

```sh
./projectbook/rag.sh start
./projectbook/rag.sh status
./projectbook/rag.sh benchmark
./projectbook/rag.sh logs
```

- Wiki: http://127.0.0.1:4570/Home
- MCP: http://127.0.0.1:4570/mcp
- Existing writable wiki at port 4569 is unaffected. The experimental wiki and indexer share its **read-only** book mount, so saved changes become index candidates.
- MCP adds `search_knowledge(query, path, limit, mode)` and `get_search_index_status`. Modes: `hybrid` (default), `semantic`, `keyword`. Existing literal search remains available. Experimental document/memory writes are disabled.
- This step does not change the Web UI search box or your existing Codex MCP configuration. To compare, add a separate MCP connection pointing to port 4570; keep the current connection for writes.
- No Qdrant/indexer ports are published. Only the wiki's loopback port is exposed. This is not a production/cloud authentication setup.

```sh
./projectbook/rag.sh stop   # remove experimental containers/network, retain generated volumes
./projectbook/rag.sh start  # reuse model/cache/index
./projectbook/rag.sh clean  # also delete ONLY this experiment's model/cache/vector volumes
```

Rollback does not modify documents, the main container, its image or Git history. This experiment's application changes remain uncommitted until review. To remove the code later, review the diff and discard only the RAG changes; do not reset unrelated work.

## Components

- Qdrant 1.20.0, image pinned by digest; local persistent named volume.
- FastEmbed 0.9.0 + ONNX Runtime CPU. Model: `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`, quantized ONNX distribution `Qdrant/paraphrase-multilingual-MiniLM-L12-v2-onnx-Q`, pinned revision `faf4aa4225822f3bc6376869cb1164e8e3feedd0`. 384-dimensional vectors, 128 input tokens, Apache-2.0 model license.
- Python 3.12 Debian image pinned by digest; full installed dependency versions in `requirements.lock`. `requirements.txt` records direct dependencies. ARM64 tested here; AMD64/other hosts still need their own build/benchmark.
- pypdf 6.21.2 with AES support extracts text by page; Poppler `pdftotext` is the fallback for PDFs the primary parser cannot handle. Reports identify the extractor. No OCR, image interpretation or reliable table reconstruction.
- BM25 lexical retrieval over chunk/title/heading text, combined with vector rank using reciprocal rank fusion. This is an initial small-corpus implementation; BM25 scans the local chunk corpus. Scores are relevance signals, not confidence/proof.

Only model files are downloaded from Hugging Face. Book content is processed locally and sent only to the local Qdrant service. No paid embedding API, GPU or separate generative model is used. With the pinned files cached, model loading works offline.

## Consistency and indexing

The worker reads regular Markdown/PDF blobs from a fixed Git commit, not uncommitted checkout contents. Hidden/reserved paths, symlinks, images and agent-memory files are excluded in this first experiment. Markdown source is split by headings into short chunks. Model-token windows ensure content is not silently truncated; responses carry the original excerpt with line bounds, or PDF page number. Long chunks can have several vectors pointing to the same excerpt; results are deduplicated.

Every 60 seconds, check the configured book ref. An unchanged commit/schema/model skips indexing. Changed files reuse cached extraction/vectors by source SHA, path, model revision and schema. For the prototype, Qdrant receives a complete new collection (including reused vectors), not in-place partial updates. Publishing switches an alias atomically after a manifest is saved. Search uses one generation throughout; interrupted builds leave the old generation usable. One prior generation is retained. Generated caches accumulate until `clean`; automatic cache pruning is a future improvement.

The MCP result includes the indexed and current book revisions, overall stale status, per-hit source SHA/stale marker and URL. Never use search excerpts as a complete document replacement. Read the current Markdown through `read_document` before editing. An index can lag after a save/pull; ordinary document search remains available. File extraction failures are reported explicitly and do not masquerade as indexed content.

Limits: Markdown 2 MiB, PDF 100 MiB/3,000 pages, 1 GiB address-space and 100 CPU seconds/120 wall seconds per PDF worker, 20 MiB decoded page stream, query 500 characters, up to 20 returned chunks. pypdf may fail on complex/encrypted/malformed files; scans require a later OCR step. Empty extracted pages can be blank/decorative or scanned; absence of text does not prove a scan. JSON reports contain private book paths and belong in the generated volume, never in the public app repo.

## Measurement

`benchmark.py` sends six Russian/English queries in each search mode and writes detailed private results to `/state/benchmark.json`. Index status exposes extraction/embedding/upload/overall times, cache hits and per-PDF page coverage. The first model download is separate setup cost. Full indexing and cached regeneration must be distinguished; Docker image build/download time is not indexing time.

Indexer limit: 4 CPU, 4 GiB RAM; Qdrant: 2 CPU, 2 GiB. Benchmark uses CPU only inside Docker on the Mac. These are resource limits, not measured usage or minimum requirements. Cloud estimates must account for actual CPU architecture, allocation and storage; do not scale Apple CPU timings directly to arbitrary AWS vCPUs. Run the same commands on the eventual cloud server.

Tests:

```sh
docker exec projectbook-rag-rag-1 python -m unittest -v test_service
```

Full numeric results are recorded after the benchmark in the application's verification log. Document contents and detailed private paths are excluded from that public log.
