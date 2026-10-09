"""Builds the code part of the testbed: small projects with known functions, for evals/code.json.

    python3 -I scripts/testbed/make_code.py <testbed>/code [--eval evals/code.json]

Four git repos (Python, Swift, TypeScript, Python with notebooks) and a folder of loose scripts. Each repo also holds
what code search must leave out: a vendored copy of someone's library, a build folder git ignores, a minified bundle,
generated code, a private key, data files, and node_modules. With --eval it writes the eval file, its answers pinned
to the lines where each function starts and ends.
"""
import json
import os
import subprocess
import sys
import textwrap

FILES = {}
QUERIES = []  # (query, [(path, start marker or None, end marker or None)], tag)


def put(path, text):
    FILES[path] = textwrap.dedent(text).lstrip("\n")


def ask(query, path, start=None, end=None, tag="code", also=()):
    """`also`: other answers as good as this one, as (path, start, end)."""
    QUERIES.append((query, [(path, start, end), *also], tag))


# ---------------------------------------------------------------- billing-service (Python)

put("billing-service/README.md", """
    # billing-service

    Charges customers, sends invoices and listens for payment webhooks.

    ## Setup

    ```sh
    uv sync
    cp .env.example .env   # fill in STRIPE_API_KEY and DATABASE_URL
    ```

    ## Running the tests

    ```sh
    make test              # runs pytest with coverage
    make test-watch        # re-runs the tests when a file changes
    ```

    The webhook tests need the Stripe CLI (`brew install stripe/stripe-cli/stripe`).

    ## Configuration

    Settings live in `config/settings.yaml`; anything secret comes from the environment:

    - `DATABASE_URL`: Postgres connection string
    - `STRIPE_API_KEY`: the secret key (sk_live_… in production)
    - `WEBHOOK_SECRET`: the signing secret of the webhook endpoint

    ## Deploying

    `make deploy` builds the image and ships it to Fly.io (see `deploy/fly.toml`).
    """)

put("billing-service/Makefile", """
    test:
    \tuv run pytest --cov=billing tests

    test-watch:
    \tuv run ptw tests

    deploy:
    \tfly deploy --config deploy/fly.toml
    """)

put("billing-service/billing/__init__.py", """
    from .gateway import PaymentDeclined, StripeGateway
    from .retry import CircuitBreaker, retry_with_backoff

    __all__ = ["PaymentDeclined", "StripeGateway", "CircuitBreaker", "retry_with_backoff"]
    """)

put("billing-service/billing/retry.py", '''
    """Retrying calls to flaky services, and giving up on them for a while when they keep failing."""

    import functools
    import random
    import time


    def retry_with_backoff(attempts=5, base_delay=0.5, max_delay=30.0, retry_on=(ConnectionError, TimeoutError)):
        """Calls the function again when it raises one of `retry_on`, waiting longer each time.

        The wait doubles after every failure (0.5 s, 1 s, 2 s, ...) up to `max_delay`, with full jitter so that
        many clients failing together don't all come back at the same moment.
        """

        def decorate(fn):
            @functools.wraps(fn)
            def wrapper(*args, **kwargs):
                for attempt in range(1, attempts + 1):
                    try:
                        return fn(*args, **kwargs)
                    except retry_on:
                        if attempt == attempts:
                            raise
                        delay = min(max_delay, base_delay * 2 ** (attempt - 1))
                        time.sleep(random.uniform(0, delay))

            return wrapper

        return decorate


    class CircuitOpen(Exception):
        pass


    class CircuitBreaker:
        """Stops calling a service that keeps failing, and tries it again after a cool-down.

        After `threshold` failures in a row the circuit opens: calls fail at once with CircuitOpen. Once
        `cooldown` seconds have passed, one call goes through (half-open); if it works the circuit closes again.
        """

        def __init__(self, threshold=5, cooldown=60.0, clock=time.monotonic):
            self.threshold = threshold
            self.cooldown = cooldown
            self.clock = clock
            self.failures = 0
            self.opened_at = None

        def call(self, fn, *args, **kwargs):
            if self.opened_at is not None:
                if self.clock() - self.opened_at < self.cooldown:
                    raise CircuitOpen("service is failing, not calling it for now")
                self.opened_at = None  # half-open: let this one through
            try:
                result = fn(*args, **kwargs)
            except Exception:
                self.failures += 1
                if self.failures >= self.threshold:
                    self.opened_at = self.clock()
                raise
            self.failures = 0
            return result
    ''')
ask("retry a failed call with exponential backoff and random jitter", "billing-service/billing/retry.py",
    "def retry_with_backoff", "return decorate")
ask("stop calling a service that keeps failing and try again after a cool-down", "billing-service/billing/retry.py",
    "class CircuitBreaker", "return result")
ask("retry_with_backoff", "billing-service/billing/retry.py", "def retry_with_backoff", "return decorate",
    tag="code-name")

put("billing-service/billing/gateway.py", '''
    """Charging cards and refunding them through Stripe."""

    import logging

    import stripe

    log = logging.getLogger(__name__)

    # What a customer sees when their card is turned down, by Stripe's decline code.
    DECLINE_MESSAGES = {
        "card_declined": "Your card was declined. Please try another card.",
        "insufficient_funds": "Your card doesn't have enough funds for this payment.",
        "expired_card": "Your card has expired. Please update your card details.",
        "incorrect_cvc": "The card's security code is wrong.",
    }


    class PaymentDeclined(Exception):
        def __init__(self, code, message):
            super().__init__(message)
            self.code = code
            self.message = message


    class StripeGateway:
        def __init__(self, api_key, statement_descriptor="ACME BILLING"):
            stripe.api_key = api_key
            self.statement_descriptor = statement_descriptor

        def charge(self, customer_id, amount_cents, currency="usd", idempotency_key=None):
            """Charges the customer's default card. Raises PaymentDeclined when the bank says no."""
            try:
                intent = stripe.PaymentIntent.create(
                    customer=customer_id,
                    amount=amount_cents,
                    currency=currency,
                    confirm=True,
                    off_session=True,
                    statement_descriptor=self.statement_descriptor,
                    idempotency_key=idempotency_key,
                )
            except stripe.error.CardError as error:
                raise self._declined(error) from error
            log.info("charged %s %s to %s", amount_cents, currency, customer_id)
            return intent.id

        def refund(self, payment_id, amount_cents=None, reason="requested_by_customer"):
            """Refunds a payment, all of it unless `amount_cents` says how much."""
            refund = stripe.Refund.create(payment_intent=payment_id, amount=amount_cents, reason=reason)
            log.info("refunded %s (%s)", payment_id, refund.status)
            return refund.status == "succeeded"

        def _declined(self, error):
            code = error.code or "card_declined"
            message = DECLINE_MESSAGES.get(code, DECLINE_MESSAGES["card_declined"])
            log.warning("payment declined: %s", code)
            return PaymentDeclined(code, message)
    ''')
ask("charge a customer's card and handle the bank declining it", "billing-service/billing/gateway.py",
    "def charge", "return intent.id")
ask("give a customer their money back", "billing-service/billing/gateway.py", "def refund", "return refund.status")
ask("PaymentDeclined", "billing-service/billing/gateway.py", tag="code-name")

put("billing-service/billing/webhooks.py", '''
    import hashlib
    import hmac
    import json
    import time


    class InvalidSignature(Exception):
        pass


    def verify_signature(payload, header, secret, tolerance=300, now=None):
        parts = dict(item.split("=", 1) for item in header.split(","))
        timestamp = int(parts["t"])
        if abs((now or time.time()) - timestamp) > tolerance:
            raise InvalidSignature("timestamp outside the tolerance zone")
        signed = f"{timestamp}.{payload.decode()}".encode()
        expected = hmac.new(secret.encode(), signed, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, parts.get("v1", "")):
            raise InvalidSignature("no signature matches the payload")
        return True


    def parse_event(payload, header, secret):
        verify_signature(payload, header, secret)
        event = json.loads(payload)
        return event["type"], event["data"]["object"]
    ''')
ask("check that a webhook really came from the payment provider", "billing-service/billing/webhooks.py",
    "def verify_signature", "return True")

put("billing-service/billing/money.py", '''
    SYMBOLS = {"usd": "$", "eur": "€", "gbp": "£", "jpy": "¥", "bdt": "৳"}
    ZERO_DECIMAL = {"jpy", "krw"}


    def format_cents(amount, currency="usd"):
        currency = currency.lower()
        symbol = SYMBOLS.get(currency, currency.upper() + " ")
        if currency in ZERO_DECIMAL:
            return f"{symbol}{amount:,}"
        sign = "-" if amount < 0 else ""
        whole, cents = divmod(abs(amount), 100)
        return f"{sign}{symbol}{whole:,}.{cents:02d}"


    def split_evenly(total, parts):
        base, extra = divmod(total, parts)
        return [base + 1 if i < extra else base for i in range(parts)]
    ''')
ask("turn an amount in cents into a price with the currency symbol", "billing-service/billing/money.py",
    "def format_cents", "return f\"{sign}")
ask("divide a total between people so the leftover cents go somewhere", "billing-service/billing/money.py",
    "def split_evenly", "return [base")

put("billing-service/billing/invoices.py", '''
    """Invoice numbers, taxes and due dates."""

    from datetime import date, timedelta

    # VAT and sales tax by billing region, as a fraction of the subtotal.
    TAX_RATES = {"GB": 0.20, "DE": 0.19, "FR": 0.20, "BD": 0.15, "US-CA": 0.0725, "US-NY": 0.04}


    def next_invoice_number(last_number, today=None):
        """INV-2026-000124 after INV-2026-000123; the count starts over each year."""
        year = (today or date.today()).year
        prefix, last_year, count = last_number.split("-")
        count = int(count) + 1 if int(last_year) == year else 1
        return f"{prefix}-{year}-{count:06d}"


    def tax_for(subtotal_cents, region):
        return round(subtotal_cents * TAX_RATES.get(region, 0.0))


    def due_date(issued, terms_days=30):
        """Net 30 by default; a due date on a weekend moves to the Monday after."""
        due = issued + timedelta(days=terms_days)
        while due.weekday() >= 5:
            due += timedelta(days=1)
        return due
    ''')
ask("invoice numbers that start counting again every year", "billing-service/billing/invoices.py",
    "def next_invoice_number", "return f\"{prefix}")
ask("when is the invoice due, skipping weekends", "billing-service/billing/invoices.py", "def due_date", "return due")

put("billing-service/tests/test_retry.py", '''
    import pytest

    from billing.retry import CircuitBreaker, CircuitOpen


    def test_circuit_opens_after_threshold():
        breaker = CircuitBreaker(threshold=2, cooldown=10, clock=lambda: 0)

        def boom():
            raise ConnectionError()

        for _ in range(2):
            with pytest.raises(ConnectionError):
                breaker.call(boom)
        with pytest.raises(CircuitOpen):
            breaker.call(boom)
    ''')

put("billing-service/config/settings.yaml", """
    database:
      url: ${DATABASE_URL}
      pool_size: 10
    redis:
      url: redis://localhost:6379/2
    queues:
      invoices: billing-invoices
      webhooks: billing-webhooks
    features:
      send_dunning_emails: true
      allow_partial_refunds: false
    """)
ask("which database and redis does the billing service connect to", "billing-service/config/settings.yaml",
    tag="code-doc")
ask("how do I run the tests", "billing-service/README.md", "## Running the tests", "The webhook tests",
    tag="code-doc", also=[("billing-service/Makefile", "test:", "uv run pytest")])

put("billing-service/deploy/fly.toml", """
    app = "acme-billing"
    primary_region = "fra"

    [http_service]
      internal_port = 8080
      force_https = true
    """)

put("billing-service/.gitignore", """
    build/
    data/
    *.log
    .env
    __pycache__/
    """)
# Left out: a gitignored build copy, someone else's library in vendor/, a key, data.
put("billing-service/build/lib/billing/retry.py", """
    def retry_with_backoff(attempts=5, base_delay=0.5):
        # build output: retry with exponential backoff and jitter (a copy that must never be indexed)
        pass
    """)
put("billing-service/vendor/backoff_lite/core.py", '''
    """backoff_lite: retry a function with exponential backoff and jitter (vendored, must never be indexed)."""

    import random
    import time


    def on_exception(wait_gen, exception, max_tries=8):
        def decorate(target):
            def retry(*args, **kwargs):
                for tries, wait in enumerate(wait_gen(), start=1):
                    try:
                        return target(*args, **kwargs)
                    except exception:
                        if tries >= max_tries:
                            raise
                        time.sleep(random.uniform(0, wait))
            return retry
        return decorate
    ''')
put("billing-service/secrets/prod.pem", """
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7 (testbed key: must never be indexed)
    -----END PRIVATE KEY-----
    """)
# A test fixture that holds a private key: read, then left out.
put("billing-service/tests/fixtures.py", '''
    SIGNING_KEY = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu (testbed key: must never be indexed)
    -----END RSA PRIVATE KEY-----
    """


    def sign_webhook_for_tests(payload):
        return "t=0,v1=" + payload
    ''')
put("billing-service/data/customers.csv", "id,name,email\n1,Ada,ada@example.com\n")
put("billing-service/credentials.json", '{"stripe_key": "sk_test_must_never_be_indexed"}\n')

# ---------------------------------------------------------------- photo-organizer (Swift)

put("photo-organizer/Package.swift", """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "PhotoOrganizer",
        platforms: [.macOS(.v14)],
        targets: [
            .executableTarget(name: "PhotoOrganizer"),
            .testTarget(name: "PhotoOrganizerTests", dependencies: ["PhotoOrganizer"]),
        ]
    )
    """)

put("photo-organizer/README.md", """
    # PhotoOrganizer

    Sorts a camera dump into folders by date, renames photos by when they were taken, and finds duplicates.

    ```sh
    swift run PhotoOrganizer ~/Pictures/Import --into ~/Pictures/Sorted
    ```

    Duplicates are only reported, never deleted.
    """)

put("photo-organizer/Sources/PhotoOrganizer/ExifDate.swift", """
    import Foundation
    import ImageIO

    enum ExifDate {
        /// When the photo was taken, from its EXIF data ("2024:05:01 10:15:32"), in the camera's local time.
        /// Falls back to the file's creation date for pictures without EXIF (screenshots, scans).
        static func taken(_ url: URL) -> Date? {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
               let date = formatter.date(from: text) {
                return date
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return attributes?[.creationDate] as? Date
        }

        private static let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            return formatter
        }()
    }
    """)
ask("read the date a photo was taken", "photo-organizer/Sources/PhotoOrganizer/ExifDate.swift",
    "static func taken", "return attributes?")

put("photo-organizer/Sources/PhotoOrganizer/DuplicateFinder.swift", """
    import CoreGraphics
    import Foundation
    import ImageIO

    struct DuplicateFinder {
        var threshold = 5

        func averageHash(of url: URL) -> UInt64? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 64,
                  ] as CFDictionary) else { return nil }
            var pixels = [UInt8](repeating: 0, count: 64)
            guard let context = CGContext(data: &pixels, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
            var hash: UInt64 = 0
            for (index, value) in pixels.enumerated() where Int(value) > mean {
                hash |= 1 << UInt64(index)
            }
            return hash
        }

        func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
            (a ^ b).nonzeroBitCount
        }

        func groups(_ urls: [URL]) -> [[URL]] {
            let hashes = urls.compactMap { url in averageHash(of: url).map { (url, $0) } }
            var groups: [[URL]] = []
            var used = Set<URL>()
            for (index, (url, hash)) in hashes.enumerated() where !used.contains(url) {
                var group = [url]
                for (other, otherHash) in hashes[(index + 1)...] where !used.contains(other) {
                    if hammingDistance(hash, otherHash) <= threshold {
                        group.append(other)
                        used.insert(other)
                    }
                }
                if group.count > 1 { groups.append(group) }
            }
            return groups
        }
    }
    """)
ask("find photos that look the same", "photo-organizer/Sources/PhotoOrganizer/DuplicateFinder.swift")
ask("hamming distance", "photo-organizer/Sources/PhotoOrganizer/DuplicateFinder.swift", "func hammingDistance",
    "(a ^ b)", tag="code-name")
ask("DuplicateFinder", "photo-organizer/Sources/PhotoOrganizer/DuplicateFinder.swift", tag="code-name")

put("photo-organizer/Sources/PhotoOrganizer/Thumbnailer.swift", """
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers

    /// Small previews for the review screen, written next to the originals' folder in `.thumbnails`.
    struct Thumbnailer {
        var maxPixelSize = 400

        /// Decodes straight to the small size (a 48 MP photo is never decoded whole) and writes a JPEG.
        func makeThumbnail(of url: URL, to destination: URL) throws {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ThumbnailError.unreadable }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString,
                                                               1, nil) else { throw ThumbnailError.unreadable }
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw ThumbnailError.cantWrite }
        }
    }

    enum ThumbnailError: Error {
        case unreadable, cantWrite
    }
    """)
ask("make a small preview of a big photo", "photo-organizer/Sources/PhotoOrganizer/Thumbnailer.swift",
    "func makeThumbnail", "guard CGImageDestinationFinalize")

put("photo-organizer/Sources/PhotoOrganizer/FolderWatcher.swift", """
    import CoreServices
    import Foundation

    /// Calls back when files appear in the import folder, once things have been quiet for a moment (a camera copies
    /// hundreds of files in one go).
    final class FolderWatcher {
        private var stream: FSEventStreamRef?
        private let onChange: ([String]) -> Void

        init(folder: String, latency: TimeInterval = 1.0, onChange: @escaping ([String]) -> Void) {
            self.onChange = onChange
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info!).takeUnretainedValue()
                let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
                watcher.onChange(Array(list.prefix(count)))
            }
            stream = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray,
                                         FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                         FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                                                  | kFSEventStreamCreateFlagUseCFTypes))
            FSEventStreamSetDispatchQueue(stream!, .main)
            FSEventStreamStart(stream!)
        }

        deinit {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
    """)
ask("notice when new files show up in a folder", "photo-organizer/Sources/PhotoOrganizer/FolderWatcher.swift")

put("photo-organizer/Sources/PhotoOrganizer/Renamer.swift", """
    import Foundation

    struct Renamer {
        private let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            return formatter
        }()

        /// "2024-05-01 at 10.15.32.jpg", or "2024-05-01 at 10.15.32 2.jpg" when a burst took two in the same second:
        /// a photo is never written over another.
        func newName(for url: URL, taken: Date, existing: Set<String>) -> String {
            let base = formatter.string(from: taken)
            let ext = url.pathExtension.lowercased()
            var name = "\\(base).\\(ext)"
            var copy = 2
            while existing.contains(name) {
                name = "\\(base) \\(copy).\\(ext)"
                copy += 1
            }
            return name
        }
    }
    """)
ask("rename pictures by when they were taken without overwriting any", "photo-organizer/Sources/PhotoOrganizer/Renamer.swift",
    "func newName", "return name")

put("photo-organizer/Sources/PhotoOrganizer/PlaceNames.swift", """
    import CoreLocation
    import Foundation

    actor PlaceNames {
        private var cache: [String: String] = [:]
        private let geocoder = CLGeocoder()

        func name(latitude: Double, longitude: Double) async -> String? {
            let key = String(format: "%.2f,%.2f", latitude, longitude)
            if let known = cache[key] { return known }
            let location = CLLocation(latitude: latitude, longitude: longitude)
            guard let mark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
            let name = mark.locality ?? mark.administrativeArea ?? mark.country
            cache[key] = name
            return name
        }
    }
    """)
ask("which city is this GPS position in", "photo-organizer/Sources/PhotoOrganizer/PlaceNames.swift")

put("photo-organizer/Tests/PhotoOrganizerTests/RenamerTests.swift", """
    import Foundation
    import Testing
    @testable import PhotoOrganizer

    @Test func burstGetsANumber() {
        let date = Date(timeIntervalSince1970: 0)
        let first = Renamer().newName(for: URL(fileURLWithPath: "/a/IMG_1.JPG"), taken: date, existing: [])
        let second = Renamer().newName(for: URL(fileURLWithPath: "/a/IMG_2.JPG"), taken: date, existing: [first])
        #expect(second.hasSuffix(" 2.jpg"))
    }
    """)

put("photo-organizer/.gitignore", ".build/\n.swiftpm/\n")

# ---------------------------------------------------------------- todo-web (TypeScript)

put("todo-web/package.json", '{"name": "todo-web", "private": true, "scripts": {"dev": "vite", "build": "vite build"}}\n')

put("todo-web/README.md", """
    # todo-web

    A to-do list with drag and drop, offline sync and sign-in.

    - `npm run dev` starts the dev server on http://localhost:5173
    - `npm run build` writes the production bundle to `dist/`
    """)

put("todo-web/src/hooks/useDebounce.ts", """
    import { useEffect, useState } from "react";

    // The value, but only once it has stopped changing for `delay` ms: search-as-you-type without a request per key.
    export function useDebounce<T>(value: T, delay = 300): T {
      const [settled, setSettled] = useState(value);
      useEffect(() => {
        const timer = setTimeout(() => setSettled(value), delay);
        return () => clearTimeout(timer);
      }, [value, delay]);
      return settled;
    }
    """)
ask("wait until the user stops typing before using what they typed", "todo-web/src/hooks/useDebounce.ts")
ask("useDebounce", "todo-web/src/hooks/useDebounce.ts", tag="code-name")

put("todo-web/src/hooks/useFetch.ts", """
    import { useEffect, useState } from "react";

    type State<T> = { data?: T; error?: Error; loading: boolean };

    export function useFetch<T>(url: string): State<T> {
      const [state, setState] = useState<State<T>>({ loading: true });
      useEffect(() => {
        // Abort the request if the component unmounts (or the URL changes) before it answers.
        const controller = new AbortController();
        setState({ loading: true });
        fetch(url, { signal: controller.signal })
          .then((response) => {
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            return response.json() as Promise<T>;
          })
          .then((data) => setState({ data, loading: false }))
          .catch((error) => {
            if (error.name !== "AbortError") setState({ error, loading: false });
          });
        return () => controller.abort();
      }, [url]);
      return state;
    }
    """)
ask("cancel the network request when the component goes away", "todo-web/src/hooks/useFetch.ts")

put("todo-web/src/api/auth.ts", """
    const TOKEN_KEY = "todo.accessToken";
    const REFRESH_KEY = "todo.refreshToken";

    function expiresAt(token: string): number {
      const payload = JSON.parse(atob(token.split(".")[1]));
      return payload.exp * 1000;
    }

    export async function login(email: string, password: string): Promise<void> {
      const response = await fetch("/api/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, password }),
      });
      if (!response.ok) throw new Error("Wrong email or password");
      const { accessToken, refreshToken } = await response.json();
      localStorage.setItem(TOKEN_KEY, accessToken);
      localStorage.setItem(REFRESH_KEY, refreshToken);
    }

    export async function refreshAccessToken(): Promise<string> {
      const refreshToken = localStorage.getItem(REFRESH_KEY);
      const response = await fetch("/api/token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refreshToken }),
      });
      if (!response.ok) {
        localStorage.removeItem(TOKEN_KEY);
        throw new Error("Session expired");
      }
      const { accessToken } = await response.json();
      localStorage.setItem(TOKEN_KEY, accessToken);
      return accessToken;
    }

    export async function authorizedFetch(input: RequestInfo, init: RequestInit = {}): Promise<Response> {
      let token = localStorage.getItem(TOKEN_KEY) ?? "";
      if (!token || expiresAt(token) - Date.now() < 30_000) token = await refreshAccessToken();
      const headers = new Headers(init.headers);
      headers.set("Authorization", `Bearer ${token}`);
      let response = await fetch(input, { ...init, headers });
      if (response.status === 401) {
        headers.set("Authorization", `Bearer ${await refreshAccessToken()}`);
        response = await fetch(input, { ...init, headers });
      }
      return response;
    }
    """)
ask("get a new access token when the old one expires", "todo-web/src/api/auth.ts",
    "export async function refreshAccessToken", "return accessToken;",
    also=[("todo-web/src/api/auth.ts", "export async function authorizedFetch", "return response;")])
ask("refreshAccessToken", "todo-web/src/api/auth.ts", "export async function refreshAccessToken",
    "return accessToken;", tag="code-name")

put("todo-web/src/components/TodoList.tsx", """
    import { useState } from "react";

    type Todo = { id: string; title: string; done: boolean };

    function move<T>(items: T[], from: number, to: number): T[] {
      const copy = items.slice();
      const [item] = copy.splice(from, 1);
      copy.splice(to, 0, item);
      return copy;
    }

    export function TodoList({ initial }: { initial: Todo[] }) {
      const [todos, setTodos] = useState(initial);
      const [dragging, setDragging] = useState<number | null>(null);

      return (
        <ul className="todos">
          {todos.map((todo, index) => (
            <li
              key={todo.id}
              draggable
              onDragStart={() => setDragging(index)}
              onDragOver={(event) => event.preventDefault()}
              onDrop={() => {
                if (dragging !== null) setTodos(move(todos, dragging, index));
                setDragging(null);
              }}
              className={todo.done ? "done" : undefined}
            >
              {todo.title}
            </li>
          ))}
        </ul>
      );
    }
    """)
ask("reorder the list by dragging items", "todo-web/src/components/TodoList.tsx")

put("todo-web/src/utils/relativeTime.ts", """
    const UNITS: [Intl.RelativeTimeFormatUnit, number][] = [
      ["year", 365 * 24 * 3600],
      ["month", 30 * 24 * 3600],
      ["week", 7 * 24 * 3600],
      ["day", 24 * 3600],
      ["hour", 3600],
      ["minute", 60],
      ["second", 1],
    ];

    export function timeAgo(date: Date, now = new Date(), locale = "en"): string {
      const seconds = Math.round((date.getTime() - now.getTime()) / 1000);
      const format = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
      for (const [unit, size] of UNITS) {
        if (Math.abs(seconds) >= size || unit === "second") {
          return format.format(Math.round(seconds / size), unit);
        }
      }
      return format.format(0, "second");
    }
    """)
ask("show how long ago something happened", "todo-web/src/utils/relativeTime.ts")

put("todo-web/src/server/rateLimit.ts", """
    import type { NextFunction, Request, Response } from "express";

    // At most `limit` requests per client IP in any `windowMs`: a sliding window of timestamps per IP.
    export function rateLimit(limit = 100, windowMs = 60_000) {
      const hits = new Map<string, number[]>();
      return (request: Request, response: Response, next: NextFunction) => {
        const now = Date.now();
        const ip = request.ip ?? "unknown";
        const recent = (hits.get(ip) ?? []).filter((time) => now - time < windowMs);
        if (recent.length >= limit) {
          response.set("Retry-After", String(Math.ceil((recent[0] + windowMs - now) / 1000)));
          return response.status(429).json({ error: "Too many requests" });
        }
        recent.push(now);
        hits.set(ip, recent);
        next();
      };
    }
    """)
ask("limit how many requests one IP address can make", "todo-web/src/server/rateLimit.ts")

put("todo-web/src/server/upload.ts", """
    import type { Request, Response } from "express";

    const ALLOWED = new Set(["image/png", "image/jpeg", "image/webp"]);
    const MAX_BYTES = 5 * 1024 * 1024;

    export async function uploadAvatar(request: Request, response: Response) {
      const file = (request as any).file as { mimetype: string; size: number; buffer: Buffer } | undefined;
      if (!file) return response.status(400).json({ error: "No file" });
      if (!ALLOWED.has(file.mimetype)) return response.status(415).json({ error: "PNG, JPEG or WebP only" });
      if (file.size > MAX_BYTES) return response.status(413).json({ error: "At most 5 MB" });
      const key = `avatars/${request.params.userId}-${Date.now()}`;
      await storage.put(key, file.buffer, file.mimetype);
      return response.json({ url: `https://cdn.example.com/${key}` });
    }

    declare const storage: { put(key: string, body: Buffer, type: string): Promise<void> };
    """)
ask("accept a profile picture upload and check its type and size", "todo-web/src/server/upload.ts")

put("todo-web/.gitignore", "node_modules/\ndist/\n")
put("todo-web/dist/bundle.min.js",
    "!function(){var e=" + ";".join(f"function r{i}(t){{return t.slice({i})}}" for i in range(400))
    + ";function useDebounce(v,d){return setTimeout(v,d)}}();\n")
# Minified without saying so in its name: read, then left out.
put("todo-web/src/legacy/analytics.js",
    "(function(w,d){" + "".join(f"w.t{i}=function(e){{return d.track('{i}',e)}};" for i in range(300))
    + "w.debounceInput=function(f,t){var h;return function(){clearTimeout(h);h=setTimeout(f,t)}}})(window,document);\n")
put("todo-web/node_modules/left-pad/index.js", """
    // left-pad: pad a string on the left (a dependency: never indexed)
    module.exports = function leftPad(str, len, ch) { return String(ch || " ").repeat(len) + str; };
    """)

# ---------------------------------------------------------------- ml-experiments (Python, notebooks)

put("ml-experiments/README.md", """
    # ml-experiments

    Sentiment classifiers for product reviews: a small transformer trained from scratch, and LoRA fine-tunes of a
    base model. `train.py` trains, `eval/metrics.py` scores, the notebooks explore the data.
    """)

put("ml-experiments/train.py", '''
    import argparse
    import math
    from pathlib import Path

    import torch
    from torch.nn.utils import clip_grad_norm_


    def cosine_with_warmup(step, warmup, total):
        if step < warmup:
            return step / max(1, warmup)
        progress = (step - warmup) / max(1, total - warmup)
        return 0.5 * (1 + math.cos(math.pi * progress))


    def save_checkpoint(path, model, optimizer, scheduler, step, best_loss):
        path.parent.mkdir(parents=True, exist_ok=True)
        torch.save({"model": model.state_dict(), "optimizer": optimizer.state_dict(),
                    "scheduler": scheduler.state_dict(), "step": step, "best_loss": best_loss}, path)


    def load_checkpoint(path, model, optimizer, scheduler):
        state = torch.load(path, map_location="cpu")
        model.load_state_dict(state["model"])
        optimizer.load_state_dict(state["optimizer"])
        scheduler.load_state_dict(state["scheduler"])
        return state["step"], state["best_loss"]


    def train(model, loader, valid, epochs, lr, warmup, out, patience=3, max_norm=1.0):
        optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=0.01)
        total = epochs * len(loader)
        scheduler = torch.optim.lr_scheduler.LambdaLR(optimizer, lambda s: cosine_with_warmup(s, warmup, total))
        scaler = torch.amp.GradScaler()
        best, bad_epochs, step = float("inf"), 0, 0
        for epoch in range(epochs):
            model.train()
            for batch in loader:
                with torch.autocast("cuda", dtype=torch.bfloat16):
                    loss = model(**batch).loss
                scaler.scale(loss).backward()
                scaler.unscale_(optimizer)
                clip_grad_norm_(model.parameters(), max_norm)
                scaler.step(optimizer)
                scaler.update()
                optimizer.zero_grad(set_to_none=True)
                scheduler.step()
                step += 1
            valid_loss = evaluate(model, valid)
            if valid_loss < best:
                best, bad_epochs = valid_loss, 0
                save_checkpoint(out / "best.pt", model, optimizer, scheduler, step, best)
            else:
                bad_epochs += 1
                if bad_epochs >= patience:
                    print(f"no improvement for {patience} epochs, stopping at epoch {epoch}")
                    break
        return best


    @torch.no_grad()
    def evaluate(model, loader):
        model.eval()
        losses = [model(**batch).loss.item() for batch in loader]
        return sum(losses) / len(losses)


    if __name__ == "__main__":
        parser = argparse.ArgumentParser()
        parser.add_argument("--epochs", type=int, default=10)
        parser.add_argument("--lr", type=float, default=3e-4)
        parser.add_argument("--warmup", type=int, default=500)
        parser.add_argument("--out", type=Path, default=Path("checkpoints"))
        args = parser.parse_args()
    ''')
ask("training loop with mixed precision and gradient clipping", "ml-experiments/train.py", "def train", "return best")
ask("stop training early when the validation loss stops improving", "ml-experiments/train.py", "def train",
    "return best")
ask("learning rate that warms up and then follows a cosine", "ml-experiments/train.py", "def cosine_with_warmup",
    "return 0.5")
ask("resume training from a saved checkpoint", "ml-experiments/train.py", "def load_checkpoint",
    "return state[\"step\"]")

put("ml-experiments/data/clean.py", '''
    import unicodedata

    import pandas as pd
    from sklearn.model_selection import train_test_split


    def normalize_text(text):
        text = unicodedata.normalize("NFKC", str(text))
        return " ".join(text.split())


    def clean(frame):
        frame = frame.dropna(subset=["label"])
        frame = frame.assign(text=frame["text"].map(normalize_text))
        frame = frame[frame["text"].str.len() > 0]
        return frame.drop_duplicates(subset=["text"]).reset_index(drop=True)


    def split(frame, valid_size=0.1, seed=13):
        return train_test_split(frame, test_size=valid_size, stratify=frame["label"], random_state=seed)
    ''')
ask("drop duplicate rows and rows that have no label", "ml-experiments/data/clean.py", "def clean",
    "return frame.drop_duplicates")
ask("split the data keeping the same class proportions", "ml-experiments/data/clean.py", "def split",
    "return train_test_split")

put("ml-experiments/eval/metrics.py", '''
    """Scores for a classifier's predictions."""

    import numpy as np


    def confusion_matrix(labels, predictions, classes):
        matrix = np.zeros((classes, classes), dtype=int)
        for truth, guess in zip(labels, predictions):
            matrix[truth, guess] += 1
        return matrix


    def per_class_scores(labels, predictions, classes):
        """Precision, recall and F1 for each class, and their macro average."""
        matrix = confusion_matrix(labels, predictions, classes)
        true_positive = np.diag(matrix)
        precision = true_positive / np.maximum(matrix.sum(axis=0), 1)
        recall = true_positive / np.maximum(matrix.sum(axis=1), 1)
        f1 = 2 * precision * recall / np.maximum(precision + recall, 1e-9)
        return {"precision": precision, "recall": recall, "f1": f1, "macro_f1": float(f1.mean())}
    ''')
ask("precision and recall for each class", "ml-experiments/eval/metrics.py", "def per_class_scores",
    "return {\"precision\"")


def notebook(cells):
    out = []
    for kind, source, *outputs in cells:
        cell = {"cell_type": kind, "metadata": {}, "source": textwrap.dedent(source).strip("\n").splitlines(True)}
        if kind == "code":
            cell["execution_count"] = None
            cell["outputs"] = outputs[0] if outputs else []
        out.append(cell)
    return json.dumps({"cells": out, "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3"}},
                       "nbformat": 4, "nbformat_minor": 5}, indent=1) + "\n"


picture = {"output_type": "display_data", "metadata": {},
           "data": {"image/png": "iVBORw0KGgo" + "A" * 200_000, "text/plain": ["<Figure size 640x480>"]}}
FILES["ml-experiments/notebooks/explore.ipynb"] = notebook([
    ("markdown", "# Exploring the reviews dataset\n\nWhat's in the data before training anything."),
    ("code", """
        import pandas as pd
        import matplotlib.pyplot as plt

        reviews = pd.read_csv("../data/reviews.csv")
        reviews.head()
        """),
    ("markdown", "## Class balance\n\nHow many reviews of each sentiment are there?"),
    ("code", """
        counts = reviews["label"].value_counts().sort_index()
        counts.plot(kind="bar", title="Reviews per class")
        plt.xlabel("label")
        plt.ylabel("reviews")
        plt.show()
        """, [picture]),
    ("markdown", "## Review length"),
    ("code", """
        reviews["words"] = reviews["text"].str.split().str.len()
        reviews["words"].hist(bins=50)
        """, [picture]),
])
ask("plot how many examples each class has", "ml-experiments/notebooks/explore.ipynb")

FILES["ml-experiments/notebooks/finetune_lora.ipynb"] = notebook([
    ("markdown", "# Fine-tuning with LoRA\n\nAdapters on the attention projections only; the base model stays frozen."),
    ("code", """
        from peft import LoraConfig, get_peft_model
        from transformers import AutoModelForSequenceClassification, AutoTokenizer

        base = "google/gemma-3-270m"
        tokenizer = AutoTokenizer.from_pretrained(base)
        model = AutoModelForSequenceClassification.from_pretrained(base, num_labels=3)
        config = LoraConfig(r=16, lora_alpha=32, lora_dropout=0.05, target_modules=["q_proj", "v_proj"])
        model = get_peft_model(model, config)
        model.print_trainable_parameters()
        """),
    ("code", """
        from datasets import load_dataset

        data = load_dataset("csv", data_files={"train": "../data/train.csv", "valid": "../data/valid.csv"})
        data = data.map(lambda batch: tokenizer(batch["text"], truncation=True, max_length=256), batched=True)
        """),
])
ask("fine-tune a model with LoRA adapters", "ml-experiments/notebooks/finetune_lora.ipynb")

put("ml-experiments/proto/model_pb2.py", '''
    # -*- coding: utf-8 -*-
    # Generated by the protocol buffer compiler.  DO NOT EDIT!
    # source: model.proto
    """Generated protocol buffer code: training loop with gradient clipping (must never be indexed)."""
    from google.protobuf import descriptor as _descriptor
    DESCRIPTOR = _descriptor.FileDescriptor(name="model.proto")
    ''')
put("ml-experiments/wandb/run-20260101_120000/files/code/train.py", """
    # wandb's copy of train.py from a run: training loop with mixed precision (must never be indexed)
    def train(): pass
    """)
put("ml-experiments/.gitignore", "checkpoints/\n*.pt\n")

# ---------------------------------------------------------------- scripts (not a repo)

put("scripts/backup_photos.sh", """
    #!/bin/zsh
    # Copies the photo library to the backup drive, skipping caches and thumbnails.
    set -euo pipefail
    DEST="/Volumes/Backup/Photos"
    if [[ ! -d /Volumes/Backup ]]; then
      echo "Plug in the backup drive first." >&2
      exit 1
    fi
    rsync -a --delete --exclude ".thumbnails" --exclude "*.tmp" "$HOME/Pictures/Sorted/" "$DEST/"
    echo "Backed up $(find "$DEST" -type f | wc -l) photos to $DEST"
    """)
ask("copy my photos to the external drive", "scripts/backup_photos.sh")

put("scripts/tidy_screenshots.py", '''
    """Moves screenshots off the Desktop into one folder per month."""

    from datetime import datetime
    from pathlib import Path

    desktop = Path.home() / "Desktop"
    for shot in desktop.glob("Screenshot *.png"):
        month = datetime.fromtimestamp(shot.stat().st_mtime).strftime("%Y-%m")
        folder = Path.home() / "Pictures" / "Screenshots" / month
        folder.mkdir(parents=True, exist_ok=True)
        shot.rename(folder / shot.name)
    ''')
ask("move screenshots from the desktop into folders by month", "scripts/tidy_screenshots.py")


# ---------------------------------------------------------------- writing it

REPOS = ["billing-service", "photo-organizer", "todo-web", "ml-experiments"]


def lines_between(text, start, end):
    lines = text.split("\n")
    first = next(i for i, line in enumerate(lines) if start in line)
    if end is None:
        return first + 1, first + 1
    last = next(i for i, line in enumerate(lines) if i >= first and end in line)
    return first + 1, last + 1


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    root = os.path.expanduser(args[0])
    eval_path = args[args.index("--eval") + 1] if "--eval" in args else None
    if os.path.exists(root):
        sys.exit(f"{root} already exists; delete it first")
    for path, text in FILES.items():
        full = os.path.join(root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as file:
            file.write(text)
    for repo in REPOS:
        subprocess.run(["git", "init", "-q", "-b", "main", os.path.join(root, repo)], check=True)
    if eval_path:
        queries = []
        for query, answers, tag in QUERIES:
            expect = []
            for path, start, end in answers:
                if start:
                    first, last = lines_between(FILES[path], start, end)
                    path += f"@{first}-{last}"
                expect.append(path)
            queries.append({"q": "code: " + query, "expect": expect, "tag": tag})
        with open(eval_path, "w") as file:
            json.dump({"base": "~/DigUpTestbed/code", "queries": queries}, file, indent=1, ensure_ascii=False)
            file.write("\n")
        print(f"{len(queries)} queries → {eval_path}")
    print(f"{len(FILES)} files in {root}")


main()
