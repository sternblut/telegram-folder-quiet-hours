# Quiet Hours for chat folders

A weekly schedule for a chat folder: **Work** stays silent in the evenings and on weekends, while every other chat
notifies as usual. Notifications come back on their own when quiet hours end.

A patch for Telegram-iOS, with tests. ▶︎ [`demo.mp4`](demo.mp4): the real app in the iOS simulator.

<p>
<img src="screenshots/2-folder-menu.png" width="200" alt="Folder tab menu: Quiet Hours, until 08:00">
<img src="screenshots/3-quiet-hours.png" width="200" alt="Quiet Hours: every day from 19:00 to 08:00">
<img src="screenshots/4-two-sets.png" width="200" alt="A second set: Saturday and Sunday, all day">
<img src="screenshots/1-chat-list.png" width="200" alt="Work badges gray during quiet hours, Personal blue">
</p>

## Why

**Mute All** in the folder tab's menu silences a folder until it is unmuted by hand. A folder mute that ends by
itself or follows a schedule is a long-standing request
([bugs.telegram.org/c/2411](https://bugs.telegram.org/c/2411)): nobody wants to remember to mute Work every evening
and unmute it every morning.

## What it does

- **Quiet Hours** sits in the folder tab's menu, right after **Mute All**, and in **Edit Folder**. Its second line
  says where things stand: *Until 08:00* or *From 19:00*.
- A folder can have several sets of hours. Each has its days and either **From** and **To** or **All Day**, and may
  run past midnight. *Every Day, 19:00 – 08:00* plus *Sat, Sun, All Day* covers evenings and weekends.
- While a set is on, the folder's chats make no sound, vibration or banner, in the app and in pushes. Their unread
  badges and the folder tab's badge turn gray, as for a muted folder.
- The chats' own notification settings are never changed: mutes, exceptions and other devices stay as they are.
- A chat that is in several folders is quiet while any of them is, the way **Mute All** already works.

## Code

| Path | What |
|---|---|
| `submodules/FolderNotificationSchedule` | The schedule: days, overnight windows, all day, the next change, clock changes. Foundation only, with host tests. |
| `submodules/TelegramUIPreferences/.../ChatListFolderNotificationScheduleSettings.swift` | Each folder's quiet hours, stored on the device. |
| `submodules/TelegramCore/.../ChatListFiltering.swift` | Whether a folder's rules include a chat, shared by the app and the notification extension. |
| `submodules/ChatListUI/Sources/FolderNotificationScheduleManager.swift` | Whether a chat is quiet now; which folders are. |
| `submodules/TelegramUI/Components/Settings/FolderNotificationScheduleScreen` | The Quiet Hours screen, built like Business Hours. |
| `ChatListController`, `ChatListFilterPresetController`, `ChatListNode`, `ChatListItem` | The menu item, the Edit Folder row, the gray badges. |
| `ApplicationContext`, `NotificationService`, `AppDelegate` | No in-app banner; pushes delivered `.passive`. |

`docs/folder-quiet-hours.md`, added by the patch, describes the design and every limitation.

## Apply

The patch is against [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) at `fb0e62ba` (22 October 2026).

```sh
git clone --recursive https://github.com/TelegramMessenger/Telegram-iOS && cd Telegram-iOS
git checkout fb0e62ba8a147f0821da6aa63c09da7d79a10111
git apply /path/to/folder-quiet-hours.patch
```

Then build as usual.

## Limitations

- The schedule lives on the device, so the account's other devices still notify. With server support it would be a
  field of `dialogFilter`, like `businessWorkHours`, and the server would not send the pushes.
- The app icon badge still counts unread messages in quiet chats.
- A single chat cannot yet be exempted from its folder's quiet hours.

## Tests

- `//submodules/FolderNotificationSchedule:FolderNotificationScheduleTests`: the schedule, minute by minute and
  across clock changes.
- `ChatListFiltersInclusionTests` in `//submodules/TelegramCore:TelegramCoreTests`: which chats a folder's quiet
  hours cover.
- [`verification/`](verification/): an in-app check of every folder rule against Telegram's own folder lists.
