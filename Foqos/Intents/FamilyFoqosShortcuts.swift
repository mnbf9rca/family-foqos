import AppIntents

struct FamilyFoqosShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartProfileIntent(),
      phrases: ["Start \(\.$profile) in \(.applicationName)"],
      shortTitle: "Start Profile", systemImageName: "play.fill")
    AppShortcut(
      intent: StopProfileIntent(),
      phrases: ["Stop \(\.$profile) in \(.applicationName)"],
      shortTitle: "Stop Profile", systemImageName: "stop.fill")
    AppShortcut(
      intent: CheckSessionActiveIntent(),
      phrases: ["Am I blocking right now in \(.applicationName)"],
      shortTitle: "Blocking Status", systemImageName: "checkmark.shield")
  }
}
