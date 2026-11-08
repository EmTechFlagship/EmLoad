"""EmLoad's expected, user-actionable failures.

Every exception here carries a message meant to be read verbatim by a person: the
GUI renders it in an error banner and the CLI prints it instead of a traceback.

Anything *not* descended from :class:`EmLoadError` is a bug rather than a
situation, so it keeps its traceback - a stack is what you need to diagnose a bug,
and a clean one-liner is what you need when you simply forgot to plug the phone in.
"""

from __future__ import annotations


class EmLoadError(Exception):
    """A failure the user can understand and do something about."""