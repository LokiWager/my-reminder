# StandUpReminder (macOS)

StandUpReminder is a macOS menu bar app for:

- recurring stand-up reminders during configurable work periods
- fixed-time reminder items such as standup, study, or dinner
- optional calendar event reminders
- lightweight todo, shopping, and mouse-mover utilities

## Notification model

Recurring stand-up reminders and fixed-time reminder items are scheduled as persistent macOS local notifications with `UNCalendarNotificationTrigger`.

That means reminders such as a daily `14:30` stand-up slot are stored by the system once permission is granted, instead of depending on an in-process timer staying alive.

Calendar event reminders are refreshed from the app and scheduled as one-time local notifications.

Each Mac keeps its own local notification queue. If you run the app on multiple computers, each computer can schedule and deliver reminders independently. Use `Schedule Notifications On This Mac` on secondary machines to keep them in view-only mode.

## Development

Build the Swift package:

```bash
swift build
```

Run tests:

```bash
swift test
```

Build a release binary:

```bash
swift build -c release
```

## Build the `.app`

```bash
./build-app.sh
```

This script:

- regenerates `StandUpReminder.xcodeproj` from `project.yml`
- builds the macOS app in Release mode
- generates `AppIcon.icns` from `Assets/AppIconSource.png`
- copies the finished bundle into `dist/`
- signs the app ad hoc

Open the built app with:

```bash
open ./dist/StandUpReminder.app
```

## Run on Login

1. Build the app bundle with `./build-app.sh`.
2. Copy `com.haotingyi.standupreminder.plist` to `~/Library/LaunchAgents/`.
3. Replace `/ABSOLUTE/PATH/TO/...` in the plist with the real app executable path.
4. Load the agent:

```bash
launchctl unload ~/Library/LaunchAgents/com.haotingyi.standupreminder.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.haotingyi.standupreminder.plist
```

To stop it:

```bash
launchctl unload ~/Library/LaunchAgents/com.haotingyi.standupreminder.plist
```
