"""The DigUp server: a localhost-first HTTP wrapper over the original Swift engine.

Layout: `digup_server/engine/` speaks DigUp's published JSON-lines protocol (the adapter);
the API (Stage 4) sits on top of it. The engine itself lives in `Sources/**` upstream and is
never modified here — see docs/implementation/README.md for the binding rules.
"""

__version__ = "0.1.0"
