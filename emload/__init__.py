"""EmLoad - sideload iOS apps with a free Apple ID.

A Python CLI and PySide6 desktop app (AltServer-style) that:

1. talks to your iPhone over USB/Wi-Fi (pymobiledevice3),
2. signs you in to your Apple ID locally (GrandSlam + in-process anisette),
3. provisions a 7-day development certificate + profile from Apple,
4. re-signs an ``.ipa`` (zsign) and installs it on the device,
5. tracks expiries and can refresh apps before their profiles run out.
"""

__version__ = "0.1.0b1"