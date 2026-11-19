# Calendar merge

All your calendars in one Google calendar: work Google, iCloud personal, iCloud work and so on.
Studio Calendar (and your phone) then only needs to show that one calendar.

It runs as a Google Apps Script in the account that owns the target calendar, every 5 minutes. It is a small
add-on to [GAS-ICS-Sync](https://github.com/derekantrican/GAS-ICS-Sync) by Derek Antrican, which does the
copying. The add-on adds what you need when the same meeting sits in several calendars:

- **No duplicates.** A source event is skipped when it is already directly in the target calendar (same UID),
  when the same UID comes from two sources, or when an event with almost the same title starts at the same time
  (punctuation ignored, 80 % of the words match). Recurring events are left to GAS-ICS-Sync.
- **No wipe on a bad feed.** If one source fails to load (iCloud sometimes does), that run deletes nothing.
  Without this, every copy from that feed would be deleted and recreated five minutes later.
- **Clean-up.** `cleanUp()` removes copies an older run created twice. It only touches the script's own copies.

The script never changes your source calendars. It only creates, updates and removes its own copies
(marked `fromGAS=true`) in the target calendar.

## Set up

1. Open GAS-ICS-Sync and make a copy of the Apps Script project into the Google account that owns the
   target calendar (see its README).
2. Add two files to the project, both **below** the GAS-ICS-Sync files so they load last:
   - `Merge.gs` from this folder.
   - `Settings.gs`: a copy of `Settings.example.gs` with your ICS links and target calendar.
3. Run `check()` to see the settings, then `setup()` once. Google asks for permission the first time.
4. If you had run it before and see doubles, run `cleanUp()` once.

Where the links come from:

- Google Calendar: Settings > your calendar > "Secret address in iCal format".
- iCloud: Calendar app or icloud.com > share the calendar > Public calendar > copy the `webcal://` link
  (change it to `https://`).

**Keep the links private.** Anyone with a secret ICS link can read that calendar. They only belong in your own
Apps Script project, never in a repository, a screenshot or a chat.

On your Mac and phone, hide the source calendars and show only the target calendar, or every meeting appears twice.

## License

GPL-3.0-or-later, like GAS-ICS-Sync. See `LICENSE` in this folder. The rest of the repository is MIT.
