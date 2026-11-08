"""Small async helpers shared across the engine.

pymobiledevice3 10.x/11.x is asyncio-based, but several call sites have shifted
between sync and async across releases. ``maybe_await`` lets the rest of the
engine treat both shapes uniformly, and ``run`` gives synchronous callers (the
CLI and the GUI worker threads) a simple entry point.
"""

from __future__ import annotations

import asyncio
import inspect
from typing import Any


async def maybe_await(value: Any) -> Any:
    """Return ``value``, awaiting it first if it is awaitable."""
    if inspect.isawaitable(value):
        return await value
    return value


def run(coro: Any) -> Any:
    """Run an async coroutine to completion from synchronous code."""
    return asyncio.run(coro)