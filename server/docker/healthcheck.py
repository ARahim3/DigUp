#!/usr/bin/env python3
"""The container's healthcheck (Dockerfile HEALTHCHECK → this file).

A healthy container is one whose API answers. 200 is healthy. 503 is *alive*: /health
answers 503 while the searcher is respawning — the engine's own refusal, the server
honestly saying "not right now" — and Docker must not restart a live server over it.
urlopen raises HTTPError for 503, so it is caught here, not propagated. Anything
else — a 5xx, a refused connection, a timeout — is not serving, exit 1.
"""
import sys
import urllib.error
import urllib.request

try:
    status = urllib.request.urlopen("http://127.0.0.1:8787/api/v1/health", timeout=5).status
    sys.exit(0 if status in (200, 503) else 1)
except urllib.error.HTTPError as exc:
    sys.exit(0 if exc.code == 503 else 1)
except Exception:
    sys.exit(1)
