# Nexa Insight — iOS Import Backend

Thin backend that imports a YouTube episode, transcribes/translates/chapters it,
and serves the packaged episode (mp3 + bilingual sentences) to the iOS app.

## Requirements

Python 3.12+, `ffmpeg`, `yt-dlp`, and an API key for the configured
transcription + text models.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -e 'backend/[dev]'
cp backend/.env.example backend/.env   # set NEXA_INSIGHT_OPENAI_API_KEY
```

## Run

```bash
./backend/scripts/dev.sh
```

The API listens on `http://0.0.0.0:8000` (reachable from the iPhone on the same
network via the Mac's LAN IP). The worker polls for queued import jobs.

## Verify

```bash
cd backend && python -m pytest -q
```

## Endpoints

- `POST /api/episodes/import` — `{ "url": "<youtube>" }`
- `GET  /api/episodes` / `GET /api/episodes/{id}` / `GET /api/episodes/{id}/job`
- `POST /api/jobs/{id}/retry`
- `GET  /api/episodes/{id}/bundle` — metadata + chapters + bilingual sentences
- `GET  /api/episodes/{id}/audio` — mp3 (404 for caption-only episodes)
