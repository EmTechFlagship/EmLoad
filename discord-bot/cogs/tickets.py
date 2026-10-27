"""ModMail-style tickets. Reloaded by `!jsk refresh`."""

from __future__ import annotations

import asyncio
import io
import json
import logging
import re

import discord
from discord import app_commands
from discord.ext import commands

from config import CATEGORY_ID, EMBED_COLOR, GUILD_ID, LOG_CHANNEL_ID, STAFF_ROLE_IDS, STORE_PATH

log = logging.getLogger("emload.tickets")

SAFE_MENTIONS = discord.AllowedMentions.none()
FILE_LIMIT = 8 * 1024 * 1024
GUILD = discord.Object(id=GUILD_ID)

WELCOME = (
    "Your **Em Community** ticket is open. Staff reply in a private channel, "
    "and those replies show up here.\n\n"
    "Include your EmLoad version, operating system, device, iOS version, and the "
    "**exact** error. Never send an Apple ID, password, or 2FA code.\n\n"
    "Send `!close` when you're done, or `!help` to see this again."
)


def is_jishaku_call(content: str) -> bool:
    lowered = content.strip().lower()
    return lowered in {"!jsk", "!jishaku"} or lowered.startswith(("!jsk ", "!jishaku "))


def is_staff(member: discord.Member) -> bool:
    if member.guild_permissions.administrator or member.guild_permissions.manage_channels:
        return True
    return any(role.id in STAFF_ROLE_IDS for role in member.roles)


def channel_name(user: discord.abc.User) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", user.name.lower()).strip("-") or "user"
    return f"ticket-{slug}"[:90]


def chunks(text: str, size: int = 1900) -> list[str]:
    return [text[i : i + size] for i in range(0, len(text), size)] or []


def staff_only():
    async def predicate(interaction: discord.Interaction) -> bool:
        if not isinstance(interaction.user, discord.Member) or not is_staff(interaction.user):
            raise app_commands.CheckFailure("Only staff can use this.")
        return True

    return app_commands.check(predicate)


class TicketStore:
    def __init__(self, path=STORE_PATH) -> None:
        self.path = path
        self._lock = asyncio.Lock()
        self.tickets: dict[str, dict] = {}
        if path.exists():
            self.tickets = json.loads(path.read_text())

    def get(self, user_id: int) -> dict | None:
        return self.tickets.get(str(user_id))

    def user_id_for_channel(self, channel_id: int) -> int | None:
        for user_id, record in self.tickets.items():
            if record.get("channel_id") == channel_id:
                return int(user_id)
        return None

    async def put(self, user_id: int, **record) -> None:
        self.tickets[str(user_id)] = record
        await self.save()

    async def drop(self, user_id: int) -> None:
        self.tickets.pop(str(user_id), None)
        await self.save()

    async def save(self) -> None:
        async with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(json.dumps(self.tickets, indent=2))
            temporary.replace(self.path)


class CloseModal(discord.ui.Modal, title="Close ticket"):
    reason = discord.ui.TextInput(
        label="Reason",
        required=False,
        max_length=500,
        style=discord.TextStyle.paragraph,
        placeholder="Optional note for the member",
    )

    async def on_submit(self, interaction: discord.Interaction) -> None:
        cog = interaction.client.get_cog("Tickets")
        if not isinstance(cog, Tickets):
            await interaction.response.send_message("Tickets are unavailable.", ephemeral=True)
            return
        await cog.close_from_channel(interaction, str(self.reason.value or "").strip())


class TicketControls(discord.ui.View):
    def __init__(self) -> None:
        super().__init__(timeout=None)

    @discord.ui.button(
        label="Close ticket",
        style=discord.ButtonStyle.danger,
        custom_id="emload:close_ticket",
    )
    async def close(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        if not isinstance(interaction.user, discord.Member) or not is_staff(interaction.user):
            await interaction.response.send_message("Only staff can close a ticket.", ephemeral=True)
            return
        await interaction.response.send_modal(CloseModal())


class TicketPanel(discord.ui.View):
    def __init__(self) -> None:
        super().__init__(timeout=None)

    @discord.ui.button(
        label="Open a ticket",
        style=discord.ButtonStyle.primary,
        custom_id="emload:open_ticket",
        emoji="🎫",
    )
    async def open_ticket(self, interaction: discord.Interaction, button: discord.ui.Button) -> None:
        cog = interaction.client.get_cog("Tickets")
        if not isinstance(cog, Tickets):
            await interaction.response.send_message("Tickets are unavailable.", ephemeral=True)
            return
        await cog.open_from_panel(interaction)


class Tickets(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot
        self.store: TicketStore = bot.store  # type: ignore[attr-defined]

    async def cog_load(self) -> None:
        self.bot.add_view(TicketPanel())
        self.bot.add_view(TicketControls())
        await self.bot.tree.sync(guild=GUILD)

    def lock_for(self, user_id: int) -> asyncio.Lock:
        locks: dict[int, asyncio.Lock] = self.bot.locks  # type: ignore[attr-defined]
        return locks.setdefault(user_id, asyncio.Lock())

    @commands.Cog.listener()
    async def on_message(self, message: discord.Message) -> None:
        if message.author.bot or is_jishaku_call(message.content):
            return
        if message.guild is None:
            await self.handle_dm(message)
            return
        if message.guild.id != GUILD_ID:
            return
        if self.store.user_id_for_channel(message.channel.id) is not None:
            await self.handle_staff_message(message)

    async def handle_dm(self, message: discord.Message) -> None:
        content = message.content.strip()
        lowered = content.lower()
        if lowered in {"!help", "help"}:
            await message.channel.send(WELCOME)
            return

        member = await self.member_of(message.author.id)
        if member is None:
            await message.channel.send("This bot only opens tickets for members of **Em Community**.")
            return

        if lowered == "!close" or lowered.startswith("!close "):
            reason = content[6:].strip()
            record = self.store.get(member.id)
            channel = await self.text_channel(record["channel_id"]) if record else None
            if channel is None:
                if record:
                    await self.store.drop(member.id)
                await message.channel.send("You don't have an open ticket.")
                return
            await self.finish_close(channel, member, member, reason or "Closed by the member.")
            return

        async with self.lock_for(member.id):
            channel = await self.ensure_channel(member)
            if channel is None:
                return
            await self.relay_user_message(channel, message)

    async def open_from_panel(self, interaction: discord.Interaction) -> None:
        await interaction.response.defer(ephemeral=True)
        if not isinstance(interaction.user, discord.Member):
            await interaction.followup.send("Open this from the server.", ephemeral=True)
            return
        try:
            await interaction.user.create_dm()
        except discord.Forbidden:
            await interaction.followup.send(
                "I can't DM you. Allow DMs from server members, then press the button again.",
                ephemeral=True,
            )
            return

        async with self.lock_for(interaction.user.id):
            record = self.store.get(interaction.user.id)
            if record and await self.text_channel(record["channel_id"]):
                try:
                    await interaction.user.send("You already have an open ticket. Reply here and staff will see it.")
                except discord.Forbidden:
                    pass
                await interaction.followup.send("You already have a ticket. Check your DMs.", ephemeral=True)
                return
            try:
                await interaction.user.send(WELCOME)
            except discord.Forbidden:
                await interaction.followup.send(
                    "I can't DM you. Allow DMs from server members, then press the button again.",
                    ephemeral=True,
                )
                return
            channel = await self.ensure_channel(interaction.user, announce=False)
        if channel is None:
            await interaction.followup.send("I couldn't create the ticket channel. Check my permissions.", ephemeral=True)
            return
        await interaction.followup.send("Ticket opened. Check your DMs and describe the problem there.", ephemeral=True)

    async def handle_staff_message(self, message: discord.Message) -> None:
        if not isinstance(message.author, discord.Member) or not is_staff(message.author):
            return
        if not isinstance(message.channel, discord.TextChannel):
            return
        content = message.content.strip()
        if content.startswith("//"):
            try:
                await message.add_reaction("📝")
            except discord.HTTPException:
                pass
            return
        if content.lower() == "!close" or content.lower().startswith("!close "):
            await self.finish_close(
                message.channel,
                message.author,
                await self.user_for_channel(message.channel.id),
                content[6:].strip() or "Closed by staff.",
            )
            return
        if content.lower() == "!help":
            await message.channel.send(
                "Reply in this channel to DM the member. Start a message with `//` for an internal note. "
                "`!close reason` closes the ticket. The bot owner reloads code with `!jsk reload cogs.tickets`."
            )
            return
        if content.startswith("!"):
            await message.channel.send("Unknown command. Use `!close` or start a note with `//`.")
            return

        user_id = self.store.user_id_for_channel(message.channel.id)
        if user_id is None:
            return
        user = self.bot.get_user(user_id) or await self.bot.fetch_user(user_id)
        try:
            await self.relay_to_user(user, message)
        except discord.Forbidden:
            await message.channel.send("I couldn't DM that member. They may have closed their DMs.")
            return
        try:
            await message.add_reaction("✅")
        except discord.HTTPException:
            pass

    async def close_from_channel(self, interaction: discord.Interaction, reason: str) -> None:
        await interaction.response.defer(ephemeral=True)
        channel = interaction.channel
        if not isinstance(channel, discord.TextChannel):
            await interaction.followup.send("This isn't a ticket channel.", ephemeral=True)
            return
        user = await self.user_for_channel(channel.id)
        if user is None:
            await interaction.followup.send("This channel isn't an open ticket.", ephemeral=True)
            return
        await interaction.followup.send("Closing the ticket.", ephemeral=True)
        await self.finish_close(channel, interaction.user, user, reason or "Closed by staff.")

    async def finish_close(
        self,
        channel: discord.abc.Messageable,
        closer: discord.abc.User,
        user: discord.abc.User | None,
        reason: str,
    ) -> None:
        if not isinstance(channel, discord.TextChannel) or user is None:
            return
        transcript = await self.build_transcript(channel)
        filename = f"{channel.name}.txt"
        notice = f"Your ticket was closed by **{closer.display_name}**."
        if reason:
            notice += f"\nReason: {reason}"
        try:
            dm = await user.create_dm()
            await dm.send(notice, file=discord.File(io.BytesIO(transcript.encode()), filename=filename))
        except discord.HTTPException:
            log.warning("Could not DM close notice to %s", user.id)

        log_channel = await self.text_channel(LOG_CHANNEL_ID) if LOG_CHANNEL_ID else None
        if log_channel is not None:
            embed = discord.Embed(
                title=f"Closed {channel.name}",
                description=f"User: {user} (`{user.id}`)\nClosed by: {closer}\nReason: {reason or 'None'}",
                color=EMBED_COLOR,
            )
            try:
                await log_channel.send(
                    embed=embed,
                    file=discord.File(io.BytesIO(transcript.encode()), filename=filename),
                )
            except discord.HTTPException:
                log.warning("Could not post the transcript for %s", channel.id)

        try:
            await channel.delete(reason=f"Ticket closed by {closer}")
        except discord.NotFound:
            pass
        record_user_id = self.store.user_id_for_channel(channel.id)
        if record_user_id is not None:
            await self.store.drop(record_user_id)

    async def ensure_channel(self, member: discord.Member, announce: bool = True) -> discord.TextChannel | None:
        record = self.store.get(member.id)
        if record:
            existing = await self.text_channel(record["channel_id"])
            if existing is not None:
                return existing
            await self.store.drop(member.id)

        guild = self.bot.get_guild(GUILD_ID)
        if guild is None:
            log.error("Guild %s is not available to the bot.", GUILD_ID)
            return None
        try:
            category = await self.ensure_category(guild)
            name = channel_name(member)
            if discord.utils.get(category.channels, name=name):
                name = f"{name}-{str(member.id)[-4:]}"[:100]
            channel = await guild.create_text_channel(
                name,
                category=category,
                overwrites=self.overwrites(guild),
                topic=f"Ticket for {member} ({member.id}). The member talks in DMs with the bot.",
                reason=f"Ticket opened by {member}",
            )
        except discord.Forbidden:
            log.exception("Missing permission to create a ticket channel")
            try:
                await member.send("I couldn't open a ticket channel. Ask a server admin to check the bot's permissions.")
            except discord.HTTPException:
                pass
            return None

        await self.store.put(member.id, channel_id=channel.id, user_name=str(member))
        embed = discord.Embed(
            title="New ticket",
            description=(
                f"Member: {member.mention} (`{member.id}`)\n"
                "Reply in this channel to DM them. Start a message with `//` for an internal note.\n"
                "Close it with the button or `!close reason`."
            ),
            color=EMBED_COLOR,
        )
        embed.set_thumbnail(url=member.display_avatar.url)
        controls = await channel.send(embed=embed, view=TicketControls())
        try:
            await controls.pin()
        except discord.HTTPException:
            pass
        if announce:
            try:
                await member.send(WELCOME)
            except discord.Forbidden:
                await channel.send("The member's DMs are closed, so they will not see replies.")
        return channel

    async def ensure_category(self, guild: discord.Guild) -> discord.CategoryChannel:
        if CATEGORY_ID:
            channel = guild.get_channel(CATEGORY_ID) or await guild.fetch_channel(CATEGORY_ID)
            if isinstance(channel, discord.CategoryChannel):
                return channel
            raise RuntimeError("TICKET_CATEGORY_ID is not a category channel.")
        existing = discord.utils.get(guild.categories, name="Tickets")
        if existing:
            return existing
        return await guild.create_category("Tickets", overwrites=self.overwrites(guild), reason="Em Community tickets")

    def overwrites(self, guild: discord.Guild) -> dict[discord.abc.Snowflake, discord.PermissionOverwrite]:
        overwrites: dict[discord.abc.Snowflake, discord.PermissionOverwrite] = {
            guild.default_role: discord.PermissionOverwrite(view_channel=False),
            guild.me: discord.PermissionOverwrite(
                view_channel=True,
                send_messages=True,
                read_message_history=True,
                manage_channels=True,
                manage_messages=True,
                attach_files=True,
                embed_links=True,
            ),
        }
        for role_id in STAFF_ROLE_IDS:
            role = guild.get_role(role_id)
            if role is not None:
                overwrites[role] = discord.PermissionOverwrite(
                    view_channel=True,
                    send_messages=True,
                    read_message_history=True,
                    attach_files=True,
                    embed_links=True,
                )
        return overwrites

    async def relay_user_message(self, channel: discord.TextChannel, message: discord.Message) -> None:
        files = await files_from(message)
        parts = chunks(message.content.strip())
        if not parts and not files:
            return
        embed = discord.Embed(
            description=parts[0] if parts else "*Attachment*",
            color=0x5865F2,
            timestamp=message.created_at,
        )
        embed.set_author(name=str(message.author), icon_url=message.author.display_avatar.url)
        embed.set_footer(text=f"User ID {message.author.id}")
        await channel.send(embed=embed, files=files, allowed_mentions=SAFE_MENTIONS)
        for extra in parts[1:]:
            await channel.send(extra, allowed_mentions=SAFE_MENTIONS)
        try:
            await message.add_reaction("✅")
        except discord.HTTPException:
            pass

    async def relay_to_user(self, user: discord.abc.User, message: discord.Message) -> None:
        files = await files_from(message)
        parts = chunks(message.content.strip())
        if not parts and not files:
            return
        embed = discord.Embed(
            description=parts[0] if parts else "*Attachment*",
            color=0x2ECC71,
            timestamp=message.created_at,
        )
        embed.set_author(
            name=f"{message.author.display_name} (Em Community Staff)",
            icon_url=message.author.display_avatar.url,
        )
        embed.set_footer(text="Reply here to continue this ticket")
        dm = await user.create_dm()
        await dm.send(embed=embed, files=files, allowed_mentions=SAFE_MENTIONS)
        for extra in parts[1:]:
            await dm.send(extra, allowed_mentions=SAFE_MENTIONS)

    async def build_transcript(self, channel: discord.TextChannel) -> str:
        lines: list[str] = []
        async for msg in channel.history(limit=500, oldest_first=True):
            stamp = msg.created_at.strftime("%Y-%m-%d %H:%M")
            content = msg.content
            if not content and msg.embeds:
                content = msg.embeds[0].description or ""
            if msg.attachments:
                names = ", ".join(attachment.filename for attachment in msg.attachments)
                content = f"{content} [files: {names}]".strip()
            lines.append(f"[{stamp}] {msg.author}: {content}")
        return "\n".join(lines) or "No messages."

    async def text_channel(self, channel_id: int) -> discord.TextChannel | None:
        channel = self.bot.get_channel(channel_id)
        if isinstance(channel, discord.TextChannel):
            return channel
        try:
            fetched = await self.bot.fetch_channel(channel_id)
        except discord.HTTPException:
            return None
        return fetched if isinstance(fetched, discord.TextChannel) else None

    async def member_of(self, user_id: int) -> discord.Member | None:
        guild = self.bot.get_guild(GUILD_ID)
        if guild is None:
            return None
        member = guild.get_member(user_id)
        if member is not None:
            return member
        try:
            return await guild.fetch_member(user_id)
        except discord.NotFound:
            return None

    async def user_for_channel(self, channel_id: int) -> discord.abc.User | None:
        user_id = self.store.user_id_for_channel(channel_id)
        if user_id is None:
            return None
        return self.bot.get_user(user_id) or await self.bot.fetch_user(user_id)

    @app_commands.command(name="panel", description="Post the Open a ticket button in this channel")
    @app_commands.guilds(GUILD)
    @staff_only()
    async def panel(self, interaction: discord.Interaction) -> None:
        embed = discord.Embed(
            title="Need help?",
            description=(
                "Press **Open a ticket**. The bot will DM you and open a private channel for staff.\n\n"
                "Include your EmLoad version, operating system, device, iOS version, and the exact error. "
                "Do not send an Apple ID, password, or 2FA code."
            ),
            color=EMBED_COLOR,
        )
        await interaction.response.send_message("Ticket panel posted.", ephemeral=True)
        channel = interaction.channel
        if isinstance(channel, discord.TextChannel):
            await channel.send(embed=embed, view=TicketPanel())

    @app_commands.command(name="close", description="Close the ticket in this channel")
    @app_commands.describe(reason="Shown to the member")
    @app_commands.guilds(GUILD)
    @staff_only()
    async def close_command(self, interaction: discord.Interaction, reason: str = "") -> None:
        await self.close_from_channel(interaction, reason.strip())


async def files_from(message: discord.Message) -> list[discord.File]:
    files: list[discord.File] = []
    skipped: list[str] = []
    for attachment in message.attachments[:10]:
        if attachment.size > FILE_LIMIT:
            skipped.append(attachment.filename)
            continue
        files.append(await attachment.to_file())
    if skipped:
        await message.channel.send(
            "Skipped files over 8 MB: " + ", ".join(skipped),
            allowed_mentions=SAFE_MENTIONS,
        )
    return files


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Tickets(bot))
