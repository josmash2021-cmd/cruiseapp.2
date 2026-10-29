"""Session reads never share the brute-force bucket; the selfie upload is a
large-body path (2026-10-29, Android drivers logged out / selfie every GO).
"""
import main


def test_only_credential_paths_are_in_the_auth_tier():
    for p in ("/auth/login", "/auth/phone-login", "/auth/send-otp",
              "/auth/verify-otp", "/auth/register", "/auth/password-reset/send-code"):
        assert p.startswith(main._AUTH_CREDENTIAL_PATHS), p
    for p in ("/auth/me", "/auth/refresh", "/auth/consent", "/auth/offline",
              "/auth/account-status", "/auth/verification-status"):
        assert not p.startswith(main._AUTH_CREDENTIAL_PATHS), p


def test_face_check_upload_gets_the_large_body_cap():
    assert "/drivers/face-check" in main._LARGE_BODY_PATHS
    assert main._body_size_limit("/drivers/face-check", "POST") > main._MAX_BODY_SIZE
