"""Environment for the Em Community bot."""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).with_name(".env"))

TOKEN = os.environ.get("DISCORD_TOKEN", "").strip()
GUILD_ID = int(os.environ["GUILD_ID"]) if os.environ.get("GUILD_ID", "").strip() else 0
CATEGORY_ID = int(os.environ["TICKET_CATEGORY_ID"]) if os.environ.get("TICKET_CATEGORY_ID", "").strip() else 0
LOG_CHANNEL_ID = int(os.environ["LOG_CHANNEL_ID"]) if os.environ.get("LOG_CHANNEL_ID", "").strip() else 0
OWNER_ID = int(os.environ["OWNER_ID"]) if os.environ.get("OWNER_ID", "").strip() else None
STAFF_ROLE_IDS = {
    int(part)
    for part in os.environ.get("STAFF_ROLE_IDS", "").split(",")
    if part.strip()
}

STORE_PATH = Path(__file__).with_name("data") / "tickets.json"
EMBED_COLOR = 0xFF9F9F
