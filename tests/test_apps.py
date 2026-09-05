"""Tests for install-error classification (verification vs. everything else)."""

from __future__ import annotations

from emload import apps


def test_is_verification_failure_matches_installd_error_name():
    assert apps.is_verification_failure(
        Exception("ApplicationVerificationFailed: The application could not be verified.")
    )
    assert apps.is_verification_failure(
        Exception(
            "ApplicationVerificationFailed: The application's code signature "
            "verification failed. Make sure you have signed the application."
        )
    )


def test_is_verification_failure_matches_human_descriptions():
    assert apps.is_verification_failure(Exception("App installation failed. Couldn't be verified."))
    assert apps.is_verification_failure(Exception("Failed to verify the application"))
    assert apps.is_verification_failure(Exception("Your app's integrity could not be confirmed"))
    assert apps.is_verification_failure(Exception("integrity check failed on the device"))


def test_is_verification_failure_ignores_other_install_errors():
    assert not apps.is_verification_failure(Exception("DiskFull: No space left on device"))
    assert not apps.is_verification_failure(Exception("INSTALL_LIMIT: maximum number of installed apps using a free developer profile"))
    assert not apps.is_verification_failure(Exception("Connection broke while uploading"))
    assert not apps.is_verification_failure(Exception(""))