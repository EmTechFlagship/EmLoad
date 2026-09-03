"""Tests for signing-material helpers (key/CSR/P12)."""

from __future__ import annotations

from cryptography import x509
from cryptography.hazmat.primitives import serialization

from emload import signing


def test_generate_key_and_csr():
    key_pem, csr_pem = signing.generate_key_and_csr()
    assert b"BEGIN PRIVATE KEY" in key_pem or b"BEGIN RSA PRIVATE KEY" in key_pem
    assert "BEGIN CERTIFICATE REQUEST" in csr_pem
    csr = x509.load_pem_x509_csr(csr_pem.encode())
    assert csr.subject.get_attributes_for_oid(x509.oid.NameOID.COMMON_NAME)[0].value == "EmLoad"


def test_build_p12_roundtrip():
    key_pem, csr_pem = signing.generate_key_and_csr()
    key = serialization.load_pem_private_key(key_pem, password=None)
    # Self-sign a throwaway cert so the p12 has a real certificate.
    name = x509.Name([x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, "EmLoad Test")])
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(__import__("datetime").datetime(2026, 1, 1))
        .not_valid_after(__import__("datetime").datetime(2030, 1, 1))
        .sign(key, __import__("cryptography.hazmat.primitives.hashes", fromlist=["SHA256"]).SHA256())
    )
    p12 = signing.build_p12(cert.public_bytes(serialization.Encoding.DER), key_pem)
    assert p12[:4] == b"\x30\x82" or p12[0] == 0x30  # ASN.1 SEQUENCE
    loaded = serialization.pkcs12.load_key_and_certificates(
        p12, b"EmLoad"
    )
    assert loaded[1].subject == cert.subject


def test_p12_password_constant():
    assert signing.P12_PASSWORD == "EmLoad"