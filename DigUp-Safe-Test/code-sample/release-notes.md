# Atlas Demo — Version 1.4

- Fixed incident DEMO-4821.
- Added a capped retry delay for temporary request failures.
- Cedar verified the fix.

The retry policy starts at two seconds, doubles after each retry, and stops
increasing at 30 seconds. Atlas Demo makes no more than three retries.
