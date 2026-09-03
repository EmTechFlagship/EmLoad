"""Modal dialogs: Apple ID sign-in (with 2FA) and simple message boxes."""

from __future__ import annotations

from typing import Any

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (
    QDialog,
    QFormLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QVBoxLayout,
    QWidget,
)


class LoginDialog(QDialog):
    """Email/password entry, then a 2FA code step when Apple asks for one.

    The password is held in memory for the (short) life of the two-step flow so
    ``complete_2fa`` can re-authenticate with it; it is never written to disk.
    """

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self.setWindowTitle("Sign in to iCloud")
        self.setMinimumWidth(380)
        self._password: str = ""
        self._pending_2fa = False

        layout = QVBoxLayout(self)
        hint = QLabel(
            "EmLoad only sends your credentials to Apple, over a pinned TLS "
            "connection. The password is never stored."
        )
        hint.setWordWrap(True)
        layout.addWidget(hint)

        form = QFormLayout()
        self.email_edit = QLineEdit()
        self.email_edit.setPlaceholderText("you@icloud.com")
        self.password_edit = QLineEdit()
        self.password_edit.setEchoMode(QLineEdit.Password)
        self.password_edit.setPlaceholderText("Apple ID password")
        self.code_edit = QLineEdit()
        self.code_edit.setPlaceholderText("6-digit code")
        self.code_edit.setVisible(False)
        form.addRow("Email", self.email_edit)
        form.addRow("Password", self.password_edit)
        form.addRow("Code", self.code_edit)
        layout.addLayout(form)

        self.status_label = QLabel("")
        self.status_label.setWordWrap(True)
        layout.addWidget(self.status_label)

        buttons = QVBoxLayout()
        self.sign_in_button = QPushButton("Sign In")
        self.sign_in_button.setDefault(True)
        self.cancel_button = QPushButton("Cancel")
        buttons.addWidget(self.sign_in_button)
        buttons.addWidget(self.cancel_button)
        layout.addLayout(buttons)

        self.sign_in_button.clicked.connect(self._on_sign_in)
        self.cancel_button.clicked.connect(self.reject)
        self.password_edit.returnPressed.connect(self._on_sign_in)
        self.code_edit.returnPressed.connect(self._on_sign_in)

    # ------------------------------------------------------------------ #
    def _on_sign_in(self) -> None:
        if self._pending_2fa:
            code = self.code_edit.text().strip()
            if code:
                self.sign_in_button.setEnabled(False)
                self.status_label.setText("Verifying code\u2026")
                self._emit_submit("code", code)
            return
        email = self.email_edit.text().strip()
        password = self.password_edit.text()
        if not email or not password:
            self.status_label.setText("Enter your Apple ID email and password.")
            return
        self._password = password
        self.sign_in_button.setEnabled(False)
        self.status_label.setText("Signing in\u2026")
        self._emit_submit("credentials", (email, password))

    def show_2fa(self, method: str) -> None:
        """Switch the dialog to the code-entry step."""
        self._pending_2fa = True
        wording = "trusted device" if method == "trusteddevice" else "SMS"
        self.status_label.setText(
            f"Apple sent a verification code to your {wording}. Enter it below."
        )
        self.code_edit.setVisible(True)
        self.code_edit.setFocus()
        self.sign_in_button.setEnabled(True)
        self.sign_in_button.setText("Verify Code")

    def reset(self) -> None:
        """Re-enable the form after a failed attempt."""
        self._pending_2fa = False
        self.sign_in_button.setEnabled(True)
        self.sign_in_button.setText("Sign In")
        self.code_edit.setVisible(False)

    def password(self) -> str:
        return self._password

    # Subclasses connect these to actually drive the auth flow.
    submit_credentials = Signal(object)  # (email, password)
    submit_code = Signal(str)

    def _emit_submit(self, kind: str, payload: Any) -> None:
        if kind == "code":
            self.submit_code.emit(payload)
        else:
            self.submit_credentials.emit(payload)