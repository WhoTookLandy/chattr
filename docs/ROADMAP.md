# Roadmap / future work

Ideas that are agreed-on direction but not yet scheduled. Each entry notes
why it isn't built yet, so future-us doesn't rediscover the blocker.

## Live notifications (push when a followed channel goes live)

The most-requested feature class for any Twitch companion app. Not a
settings toggle away — it's an architecture decision:

- **Real push** requires EventSub **webhook** subscriptions (the app uses
  websocket EventSub, which only works while the app runs) delivered to a
  server we'd have to run, which then fans out APNs pushes. Costs: server
  hosting, APNs key management, per-user subscription bookkeeping against
  Twitch's webhook quota.
- **Poor-man's version**: BGAppRefresh polling `/streams/followed` and
  firing local notifications. Unreliable timing (iOS decides when), but
  zero server. Could ship first as "best effort" with clear expectations.
- UI landing spot exists: a **Notifications** section on the You tab
  (sibling of Highlights' sound toggle; per-channel opt-in like Twitch's
  bell icon would live on a channel page once one exists).

## Deleted-message display preference

EventSub deletion handling is already implemented (`message_delete`,
`chat.clear`, `clear_user_messages` → `withDeletedPlaceholder()` in
`TabChatModel`). A "Deleted Messages: placeholder / hide entirely" option
under Chat → Filters needs a second buffer mutation path that *removes*
rows instead of replacing them — touch `ChatBuffer` visibility projection,
not just the placeholder swap.

## ChatSettingsSheet cleanup

The in-chat gear sheet duplicates personal prefs (timestamps, animated
emotes, edge-to-edge) that also live in You → Chat → Appearance — two
write paths to the same `@AppStorage` keys. The sheet should hold only
*channel* state (chat modes: emote-only, slow, followers-only) plus a
link to the Appearance page.

## Custom bot list for Filters

`ChatFilterSettings.knownBotLogins` is a curated constant. Power users
will want to add their own (channel-specific bots). Needs a keyword-list
editor identical to Highlights' — extract that editor into a reusable
component when this happens.

## Home tab extras

- Stream thumbnails on Live cards (`TwitchStream.thumbnailUrl` is already
  fetched) — decide text-only vs thumbnail density first.
- "All follows" could absorb the Following sheet entirely (the switcher's
  "Browse Follows" still opens it as a sheet today).

## About-page extras

- GitHub / feedback link rows.
- Licenses (third-party: Nuke, TwitchKit).
