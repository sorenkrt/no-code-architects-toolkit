# Repository Guidelines

## Project Overview
No-Code Architects Toolkit (NCA): a Flask API that runs media jobs for no-code platforms like Make, Zapier and n8n. Jobs include FFmpeg video/audio processing, Whisper transcription, captions/ASS, screenshots, Python execution and cloud uploads. Outputs should be flat: clean URLs, text or simple dicts.

## Architecture & Data Flow
- `app.py` `create_app()` builds the app and the in-process job queue. It then calls `app_utils.discover_and_register_blueprints(app)`, which globs `routes/**/*.py` and registers every **module-level `Blueprint`**. Import errors are logged and swallowed, so if a route is missing, check the logs.
- Request pipeline. Keep these decorators in this order:
  ```python
  @v1_media_metadata_bp.route('/v1/media/metadata', methods=['POST'])
  @authenticate                              # services/authentication.py, X-API-Key vs config.API_KEY
  @validate_payload({...jsonschema...})      # app_utils, 400 on invalid
  @queue_task_wrapper(bypass_queue=False)    # app_utils, injects job_id/data
  def media_metadata(job_id, data): ...
  ```
- Sync vs async:
  - **Sync:** used when there is no `webhook_url` or when `bypass_queue=True`. It returns the full response envelope: `code`, `id`, `job_id`, `response`, `message`, timings and `build_number`.
  - **Async:** used when `webhook_url` is present. It returns `202 {"message":"processing"}`. A single daemon thread processes the queue and POSTs the result via `services/webhook.send_webhook`, with no retry.
  - If `MAX_QUEUE_LENGTH` is greater than 0, a full queue returns 429.
- Job status is written to `{LOCAL_STORAGE_PATH}/jobs/{job_id}.json` (queued, then running, then done). Read it back through `/v1/toolkit/job/status` and `/v1/toolkit/jobs/status`.
- Storage: `services/cloud_storage.py` `get_storage_provider()` picks S3-compatible storage if `S3_ENDPOINT_URL` is set, GCP if `GCP_BUCKET_NAME` is set, and raises otherwise. Routes only call `upload_file(path) -> url`.

## Key Directories
- `routes/v1/<category>/<action>.py`: versioned endpoints at `/v1/<category>/<action>`. Categories are audio, code, ffmpeg, image, media, s3, toolkit and video.
- `services/v1/<category>/<action>.py`: the logic for those endpoints. Services download inputs, run ffmpeg/ffprobe via `subprocess`, and return a local path or dict.
- `routes/*.py`, `services/*.py` (top level): legacy unversioned endpoints such as `/media-to-mp3`. Don't add new ones here.
- `docs/<category>/<action>.md`: one doc per endpoint, mirroring `routes/v1`. `docs/cloud-installation/` holds the deployment guides.
- `fonts/`: copied into the image at `/usr/share/fonts/custom` and used for captions.

## Development Commands
```bash
docker build -t no-code-architects-toolkit .            # slow: compiles FFmpeg 7.0.2 + libass etc.
docker run -d -p 8080:8080 -e API_KEY=... -e S3_ENDPOINT_URL=... no-code-architects-toolkit
./local.sh                                              # rebuild + run with env from .env_variables.json (needs jq)
docker compose -f docker-compose.local.minio.n8n.yml up # local stack with MinIO + n8n (.env.local.minio.n8n.example)
python generate_docs.py routes/v1/media/metadata.py [--force]  # Claude-generated endpoint docs; needs .env_shell.json
curl -X POST localhost:8080/v1/toolkit/test -H "x-api-key: $API_KEY"   # smoke check
```
In production, the app runs as `gunicorn app:app` on port 8080 (`GUNICORN_WORKERS` defaults to 2, `GUNICORN_TIMEOUT` to 300). There is no lint or format tooling.

## Code Conventions & Common Patterns
- **Blueprint naming:** `v1_<category>_<action>_bp = Blueprint('v1_<category>_<action>', __name__)`. File paths mirror URL paths. Don't edit `app.py` to register routes.
- **Handler return:** a 3-tuple `(payload, "/v1/category/action", status)`. Success returns 200 with a URL, dict or value. Failures use `except Exception as e: return str(e), endpoint, 500`.
- **Schemas** use `additionalProperties: False` and include `webhook_url` (uri) and `id` (string). Reuse existing field names (`video_url`, `media_url`, `file_url`, `text`, `response_type`) rather than inventing new ones.
- **Temp files:** use `LOCAL_STORAGE_PATH` (default `/tmp`) with `{job_id}_...` names. Use `services.file_management.download_file` for inputs. `os.remove` outputs after `upload_file`.
- **Logging:** `logger.info(f"Job {job_id}: ...")`. Services raise errors and routes catch them.
- Route files start with the GPL header and `from app_utils import *`.
- **Contribution rules** (`CONTRIBUTING.md`):
  - Features should need no setup, use sensible defaults and stay low-maintenance.
  - No polling or retry features, no unused code, no heavy dependencies.
  - Don't touch unrelated files.
  - Open PRs against the `build` branch, using branch names `feature/…`, `fix/…` or `docs/…`.
- A new endpoint needs a matching `docs/<category>/<action>.md` with these sections: Overview, Endpoint, Request, Response, Error Handling, Usage Notes, Common Issues, Best Practices. See `docs/adding_routes.md`.

## Important Files
- `app.py`: app factory, queue, `queue_task` wrapper implementation.
- `app_utils.py`: `validate_payload`, `queue_task_wrapper`, `log_job_status`, blueprint discovery.
- `config.py`: env config. Raises at import if `API_KEY` is unset. `validate_env_vars` checks the storage variables.
- `services/authentication.py`, `services/cloud_storage.py`, `services/file_management.py`, `services/webhook.py`.
- `Dockerfile`, `docker-compose*.yml` (Traefik + Let's Encrypt for production), `.env.example`.
- `version.py`, `build_number.txt`: bumped by CI on every push to `build`. **Never edit these by hand.**

## Runtime/Tooling Preferences
- Python 3.11 (`python:3.11-slim`). The target runtime is Docker, because the app depends on a custom-built FFmpeg, libass, Whisper (`base` model preloaded) and Playwright Chromium.
- `requirements.txt` is unpinned. `jsonschema`, `playwright` and `openai-whisper` are also pip-installed in the Dockerfile. `jsonschema` is not in `requirements.txt`, so add it there if you run the app outside Docker.
- Environment variables:
  - Required: `API_KEY`, plus one storage backend.
  - S3 backend: `S3_ENDPOINT_URL`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET_NAME`, `S3_REGION`.
  - GCP backend: `GCP_BUCKET_NAME`, `GCP_SA_CREDENTIALS`.
  - Optional: `LOCAL_STORAGE_PATH`, `MAX_QUEUE_LENGTH`, `GDRIVE_USER`.

## Testing & QA
- There is no automated test suite: no pytest and no tests in CI. The only CI workflow is `.github/workflows/update-build-number.yml`.
- `/v1/toolkit/test` is a health-check endpoint, not a test suite.
- To verify a change, build the image, run it, and exercise the endpoint with curl. Test both sync mode (no `webhook_url`) and async mode (with `webhook_url`, for example a webhook.site URL). Check the job status file and the uploaded output URL.
