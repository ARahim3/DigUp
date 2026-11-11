"""Harmless fictional example for DigUp code-search testing."""

INCIDENT_ID = "DEMO-4821"
SERVICE_NAME = "Atlas Demo"
INITIAL_DELAY_SECONDS = 2
MAX_DELAY_SECONDS = 30
MAX_RETRIES = 3
OWNER = "Cedar"


def retry_delay_seconds(retry_number: int) -> int:
    """Return a capped exponential delay for a retry numbered from 1."""
    if retry_number < 1:
        raise ValueError("retry_number must be at least 1")

    delay = INITIAL_DELAY_SECONDS * (2 ** (retry_number - 1))
    return min(delay, MAX_DELAY_SECONDS)
