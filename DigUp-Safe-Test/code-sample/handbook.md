# Atlas Demo Handbook

Atlas Demo is a fictional service used for local DigUp testing.

## Retry policy

When a request fails, Atlas Demo retries it up to three times. The delay
starts at two seconds and doubles after each retry, with a maximum delay of
30 seconds.

## Ownership

The fictional Cedar team owns Atlas Demo and verifies fixes before release.
