# Role Intel Drive/Docs endpoints for `gmail-webhook` (FastAPI)

`roleintel.py` is a drop-in `APIRouter` covering steps 3–6 of the task. The rest of the task edits code that
isn't in this repo, so steps 2, 6b and 7 are snippets to apply by hand. Nothing here has been run against
Google: only the render/parse logic is unit-tested (`pytest tests`).

## Install

1. Copy `roleintel.py` next to the service's `main.py` and add: `from roleintel import router as roleintel_router; app.include_router(roleintel_router)`.
2. Merge `requirements.txt` into the service's (`google-api-python-client`, `google-auth`).
3. Optional env: `APPLICATIONS_FOLDER_ID` (skips the `Launch - Rob > Applications` path lookup), `TOKEN_JSON_PATH`.

If the service already has a shared Google-auth helper or API-key dependency, replace `get_credentials` /
`require_key` in `roleintel.py` with those.

## Step 1: scopes

`python scripts/check_scopes.py token.json` is read-only. It exits 1 and names any missing scope among
`drive` and `documents`. Re-authorizing is yours to do.

## Step 2: allowlist the Prompt Repository

Add both IDs to whatever structure `/api/sheet/write` checks (name will vary):

```python
SHEET_WRITE_ALLOWLIST = {
    "1KRGJT1W3lPn3YzTP2O0Bz9PkRZFbfXrFr4_p3bczisQ": ["Sheet1"],  # Prompt Repository
    "1lPxHISR-T3FENgmowVUBcELENeUeH-hcifoURQIRJdA": None,          # Themes (keep its existing tab rule)
}
PROMPT_REPO_HEADER = ["Prompt ID", "Location", "Purpose", "Provider", "Variables", "Prompt",
                      "Built-in Default", "Version", "Updated", "Previous Versions"]
```

Upsert must write `PROMPT_REPO_HEADER` as row 1 when the tab is empty (`values.get` on `Sheet1!A1:J1` returns no
`values`), then upsert by `Prompt ID` (column A).

## Step 6b: Perplexity tiers in `/api/ai`

```python
PERPLEXITY_TIERS = {"regular": "sonar", "pro": "sonar-pro"}
# USD per 1M tokens (in, out). Per-request search fees apply on top: confirm current rates
# at https://docs.perplexity.ai/guides/pricing before relying on these numbers.
PRICES["sonar"] = (1.0, 1.0)
PRICES["sonar-pro"] = (3.0, 15.0)
```

In `/api/ai/health`, return `providers["perplexity"]["tiers"] = {"regular": {"model": "sonar"}, "pro": {"model": "sonar-pro"}}`.
The app picks the tier whose model is `sonar` for builds and `sonar-pro` for regenerations.

## Step 7: `folderId` on `/api/drive/save`

Add `folderId: Optional[str] = None` to the request model, then where the handler resolves the target folder:

```python
parent = req.folderId or ensure_generated_resumes_folder(drive)   # existing lookup stays the fallback
```

## Step 8: deploy and test

```bash
gcloud run services update gmail-webhook --project job-tracker-sync-507321 --region us-central1 \
  --update-env-vars APPLICATIONS_FOLDER_ID=<optional-id>      # never --set-env-vars
# (use `gcloud run deploy ... --source .` for the code change, again with --update-env-vars only)

APP_API_KEY=... python scripts/e2e_check.py https://<service-url> token.json
```

`e2e_check.py` creates `TEST.Sr Counsel.2026-10-03` with the three subfolders, checks the folder call is
idempotent, creates a two-section doc, reads it back, rewrites one section, reads again, confirms the other
section is untouched, smoke-tests `/api/jobs`, then trashes the test folder. Smoke-test `/api/sheet` by hand.

## Behaviour notes

- The Docs API cannot insert a native table-of-contents element, so "Contents" is a list of paragraphs, each
  linked to its heading via `headingId`. It is rebuilt after every create and write.
- Per spec, only the date is stored in headings, so `at` reads back as `YYYY-MM-DD` (or `""` when unknown).
- `target` reads back as `"original"` or `""`; other values written by the app are not preserved.
- Previous versions are capped at the two after the latest, matching the spec.
- Write replaces a section from its H1 up to the next H1, matched by exact title; an unmatched title is appended.
- The logo is fetched by Docs from a link-viewable Drive file (`launch-logo.png`, cached by ID per instance).
