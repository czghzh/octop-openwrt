"""Minimal stub package for `playwright`.

This is NOT the real Playwright. It exists only so that third-party code
that lazily imports playwright does not raise ImportError on platforms
where the real musl wheel is unavailable (e.g. OpenWrt / musllinux-aarch64).

Importing this module succeeds. Any *actual* attempt to drive a browser
raises ImportError with a clear explanation.

See ../README.md for why this exists and how it is built.
"""

__version__ = "1.99.0"
__is_octop_stub__ = True

_BROWSERS_DIR = ".cache/ms-playwright"

_DISABLED = (
    "playwright is not available on this platform (musl/aarch64 stub). "
    "Browser automation features are disabled. "
    "This stub only satisfies import-time dependency checks."
)


class _StubEntryPoint:
    """Stand-in for sync_playwright()/async_playwright(); fails only when called."""

    def __init__(self, name):
        self._name = name

    def __call__(self, *args, **kwargs):
        raise ImportError(_DISABLED)

    def __repr__(self):
        return f"<playwright stub {self._name}>"
