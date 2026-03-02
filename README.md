# stooge-router

Simple Python utility for downloading a VPN subscription URL into a local data directory.

## Requirements

- Python 3.11+

## Setup

Create a virtual environment:

```powershell
python -m venv .venv
```

Activate it on Windows PowerShell:

```powershell
.\.venv\Scripts\Activate.ps1
```

Install dependencies:

```powershell
pip install -e .
```

## Configuration

Create `.env` from the example:

```powershell
Copy-Item .env.example .env
```

Environment variables:

- `VPN_SUBSCRIPTION_URL`: source subscription URL. If the URL contains `#`, wrap it in quotes in `.env`.
- `DATA_DIR`: directory for downloaded/intermediate files, default is `./data`
- `SUBSCRIPTION_USER_AGENT`: HTTP `User-Agent` used for the subscription request
- `SINGBOX_CLASH_API_SECRET`: secret inserted into the generated legacy-compatible sing-box config
- `SINGBOX_CHECK_BIN`: optional explicit path/command for the `sing-box` binary used for config validation
- `MINIO_ENDPOINT`: MinIO endpoint, for example `minio.example.local:9000`
- `MINIO_ACCESS_KEY`: MinIO access key
- `MINIO_SECRET_KEY`: MinIO secret key
- `MINIO_BUCKET`: existing bucket name for uploads
- `MINIO_SECURE`: whether to use TLS for MinIO, defaults to `true`
- `MINIO_OBJECT_NAME`: object key to use in the bucket
- `MINIO_CONTENT_TYPE`: uploaded content type, defaults to `application/json`
- `MINIO_REGION`: optional MinIO region

## Recommended Run

The full pipeline is the primary supported entrypoint.

```powershell
python src/run_subscription_pipeline.py
```

This runs:

- download
- normalize (VLESS-only)
- sing-box config generation
- upload generated config to MinIO
- verify uploaded object in MinIO
- JSON validation
- `sing-box check -c` when `sing-box` is available in `PATH`

Final output:

- `DATA_DIR/singbox_config.json`
- uploaded MinIO object referenced by `MINIO_BUCKET` + `MINIO_OBJECT_NAME`

Standalone tools remain available for debugging/manual use, but the pipeline is the authoritative path.

## Auxiliary: Download Only

```powershell
python src/download_vpn_subscription.py
```

The script removes the `#fragment` before sending the request, follows redirects, saves the raw response, and then tries to detect:

- JSON subscription
- base64-encoded subscription text
- plain text / YAML / URI list

Files written to `DATA_DIR`:

- `raw_response.bin`
- `raw_response.txt`
- one of `subscription.json`, `subscription_decoded.txt`, or `subscription_plain.txt`
- `download_metadata.json` (compact metadata + file references, without duplicating full payload bodies)

## Auxiliary: Normalize VLESS URIs

If the subscription was decoded into `vless://...` lines, you can normalize it into structured JSON:

```powershell
python src/normalize_vless_subscription.py
```

This writes `DATA_DIR/subscription_normalized.json`.
Normalization currently supports only `vless://` URIs and fails fast if unsupported schemes are present.
Unknown VLESS query parameters are also treated as unsupported and fail normalization explicitly.

An example target sing-box config shape is stored in `src/example_singbox_config.json`.

## Auxiliary: Generate sing-box Config

If you already have `DATA_DIR/subscription_normalized.json`, generate a sing-box config with:

```powershell
python src/generate_singbox_config.py
```

This writes `DATA_DIR/singbox_config.json`.

Validation is mandatory:

- JSON syntax is always verified after writing the file
- if `SINGBOX_CHECK_BIN` is set, that binary is used for `sing-box check -c`; otherwise the script falls back to `sing-box` in `PATH`
- generated config targets the current legacy-compatible router layout
- after upload, `stat_object` is called and the remote object size must match the local file size
- `etag` is returned in the pipeline result when available from MinIO
