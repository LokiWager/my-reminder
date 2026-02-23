# StandUpReminder (macOS)

A lightweight macOS reminder app that sends notifications on weekdays:

- Every **45 minutes**
- Reminding you to stand up for **15 minutes**
- During **13:00-17:00** and **19:00-21:00**

The app now includes:

- A **Control** page with a single **Turn On / Turn Off** button
- A **Settings** page to set runnable reminder periods and timing values
- A generated custom app icon embedded into the `.app` bundle

## Build CLI Binary

```bash
swift build -c release
```

Binary path:

```bash
./.build/release/StandUpReminder
```

## Build Clickable `.app` (with Widget)

```bash
./build-app.sh
```

App bundle path:

```bash
./dist/StandUpReminder.app
```

`build-app.sh` now:

- Generates Xcode project files from `project.yml`
- Builds the macOS app and `StandUpReminderWidgetExtension`
- Generates `AppIcon.icns` from `/Users/haotingyi/Documents/workspaces/loki/my-reminder/scripts/generate-icon.swift`
- Signs the final app bundle ad-hoc

Launch from Finder by double-clicking `StandUpReminder.app`, or:

```bash
open ./dist/StandUpReminder.app
```

When opened:

1. Go to **Settings** tab and set your periods.
2. Click **Save Settings**.
3. Go to **Control** tab and click **Turn On**.

## Add the Widget

1. Launch `StandUpReminder.app` at least once.
2. Open Notification Center, then click **Edit Widgets**.
3. Search for **StandUpReminder**.
4. Add the widget (small or medium).

If it does not appear immediately, quit/reopen the app and reopen Widget Gallery.

## Run (CLI)

```bash
./.build/release/StandUpReminder
```

Leave it running in the background. It schedules the next 7 days of reminders and refreshes automatically.

## Run on login (LaunchAgent)

1. Build the app bundle (`./build-app.sh`).
2. Copy `com.haotingyi.standupreminder.plist` to `~/Library/LaunchAgents/`.
3. Edit the plist and set your absolute app executable path in `ProgramArguments` if different.
4. Load it:

```bash
launchctl unload ~/Library/LaunchAgents/com.haotingyi.standupreminder.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.haotingyi.standupreminder.plist
```

To stop it:

```bash
launchctl unload ~/Library/LaunchAgents/com.haotingyi.standupreminder.plist
```
