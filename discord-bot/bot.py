"""Em Community bot.

Tickets live in cogs/tickets.py. The bot owner reloads that code without
restarting by sending `!jsk reload cogs.tickets` (jishaku). `!jsk reload ~`
reloads every loaded extension. There is no leveling system.
"""

from __future__ import annotations

import asyncio
import logging

import discord
from discord.ext import commands

from cogs.tickets import TicketStore, is_jishaku_call
from config import GUILD_ID, OWNER_ID, STAFF_ROLE_IDS, STORE_PATH, TOKEN

log = logging.getLogger("emload.bot")


class EmBot(commands.Bot):
    def __init__(self) -> None:
        intents = discord.Intents.default()
        intents.message_content = True
        super().__init__(
            command_prefix="!",
            intents=intents,
            help_command=None,
            owner_id=OWNER_ID,
        )
        self.store = TicketStore(STORE_PATH)
        self.locks: dict[int, asyncio.Lock] = {}

    async def setup_hook(self) -> None:
        self.tree.error(self.on_tree_error)
        await self.load_extension("cogs.tickets")
        await self.load_extension("jishaku")

    async def on_tree_error(self, interaction: discord.Interaction, error: discord.app_commands.AppCommandError) -> None:
        original = getattr(error, "original", error)
        if isinstance(original, discord.app_commands.CheckFailure):
            text = str(original)
        else:
            log.exception("Slash command failed", exc_info=original)
            text = "That command failed. Check the bot logs."
        if interaction.response.is_done():
            await interaction.followup.send(text, ephemeral=True)
        else:
            await interaction.response.send_message(text, ephemeral=True)

    async def on_ready(self) -> None:
        log.info("Logged in as %s (%s)", self.user, self.user.id if self.user else "?")
        if not STAFF_ROLE_IDS:
            log.warning("STAFF_ROLE_IDS is empty. Only administrators can see ticket channels.")

    async def on_message(self, message: discord.Message) -> None:
        if message.author.bot:
            return
        if is_jishaku_call(message.content):
            await self.process_commands(message)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    if not TOKEN or not GUILD_ID:
        raise SystemExit("Set DISCORD_TOKEN and GUILD_ID in discord-bot/.env. See .env.example.")
    EmBot().run(TOKEN)


if __name__ == "__main__":
    main()
