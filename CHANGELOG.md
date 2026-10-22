# Changelog

## v1.0.1 (2026-10-22) — supported

- **Install:** `curl` autoinstaller from **GitHub Releases** (not `raw.githubusercontent.com`).
- Native: binary + `SHA256SUMS` from this release; Docker: public `ghcr.io/astrum-studio/asterisk24-connector`.
- Autoinstaller: no `git`, works with `curl | bash -s`.
- Optional `--ghcr-token` only for private registries.

## v1.0.0 — deprecated

Broken install paths (raw CDN cache, bad `SHA256SUMS` paths, piped autoinstaller). **Use v1.0.1.**
