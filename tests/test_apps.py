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


JOURNAL_ERROR = (
    "APIInternalError: Failed to unarchive journal entry data from "
    "/var/installd/Library/MobileInstallation/Journal/"
    "ECD7699C-B63D-4F4B-9CA0-A9D693551648_com.spotify.client.33KN5TZAWN.plist"
)


def test_is_stale_install_journal_error():
    assert apps.is_stale_install_journal_error(Exception(JOURNAL_ERROR))
    assert apps.is_stale_install_journal_error(
        Exception("MobileInstallation/Journal: failed to unarchive journal entry data")
    )


def test_is_stale_install_journal_error_ignores_other_failures():
    assert not apps.is_stale_install_journal_error(Exception("DiskFull: No space left on device"))
    assert not apps.is_stale_install_journal_error(Exception("ApplicationVerificationFailed"))
    assert not apps.is_stale_install_journal_error(Exception(""))


def test_stale_journal_bundle_id_parses_install_record_name():
    assert (
        apps.stale_journal_bundle_id(Exception(JOURNAL_ERROR))
        == "com.spotify.client.33KN5TZAWN"
    )
    assert apps.stale_journal_bundle_id(Exception("DiskFull")) is None
