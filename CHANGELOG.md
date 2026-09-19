# Changelog

Each entry names the Open WebUI version this starter pins and says whether
moving to it changes your data. Take a backup before any upgrade (see
"Backups, upgrading, restoring" in the README).

## 0.11.3 (2026-09-18)

Initial release. Pins Open WebUI 0.11.3 by tag and image digest. No data
migration.

Since the first publication: the model hub client runs offline and the
embedding and reranking auto-update checks are off (`HF_HUB_OFFLINE=1`,
`RAG_EMBEDDING_MODEL_AUTO_UPDATE=false`, `RAG_RERANKING_MODEL_AUTO_UPDATE=false`,
each overridable). The first document upload used to ask Hugging Face for
a newer revision of the bundled embedding model, fail to write into the
read-only model cache, and print an error trace before using the bundled
model anyway. No data change; a Restart picks it up on the Develop path
after merging.
