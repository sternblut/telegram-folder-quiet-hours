# Verification of the folder rules

The tests in the patch cover the schedule math. Which chats a folder holds is a different question: Telegram
decides it from the folder's chat types, included, excluded and pinned chats, archived chats and contacts. Quiet hours
must silence exactly the chats the folder's tab shows, and grey exactly those badges, so this harness checks both
against Postbox's own chat list for the folder, on a real account.

What it checks, inside the app:

- 2,048 folder rules: all 32 sets of chat types (contacts, non-contacts, groups, channels, bots), with and without
  *exclude muted*, *exclude read* and *exclude archived*, and 8 ways of placing every chat of the account in the
  folder (not listed, included, excluded, pinned and their combinations);
- 400 pairs of such folders, quiet at the same time;
- every set of the account's real folders being quiet, through `_internal_chatListFiltersIncludePeer`, the function
  the app and the notification service extension call.

For each rule and each chat it compares the folder tab's own list (`tailChatListView` with the folder's predicate)
with the notification path and with the chat list row's grey badge. [`report.txt`](report.txt) is the run of
25 October 2026 on the demo account: 30 chats of 13 kinds, 73,440 checks and 450 checks, no mismatches. The one known
limit of the prototype shows up as expected: an archived chat inside a folder tab takes its badge colour by the rules
for unarchived chats, as Telegram's folder tags do (its notifications are right).

## Running it

1. Apply the patch, then put `QuietHoursSelfCheck.swift` into
   `submodules/TelegramCore/Sources/TelegramEngine/Peers/`.
2. In `submodules/TelegramUI/Sources/ApplicationContext.swift`, after `self.context = context` in
   `AuthorizedApplicationContext.init`:

   ```swift
   #if DEBUG
   if CommandLine.arguments.contains("-quietHoursSelfCheck") {
       let _ = (quietHoursSelfCheck(account: context.account) |> deliverOnMainQueue).startStandalone(next: { report in
           let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/quiet-hours-self-check.txt")
           let _ = try? report.write(to: url, atomically: true, encoding: .utf8)
       })
   }
   #endif
   ```
3. Build for the simulator, sign in, and launch with the argument:
   `xcrun simctl launch <device> ph.telegra.Telegraph -quietHoursSelfCheck`. The report appears in the app's
   `Documents` folder within a minute.
