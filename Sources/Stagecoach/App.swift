// Stagecoach — keeps a Darkest Dungeon save moving between Steam on this Mac
// and the iPad, by way of the Dropbox folder the iPad's Import/Export uses.
// Lives in the menu bar.

import AppKit
import SwiftUI

@main
struct StagecoachApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            Image(nsImage: MenuBarIcon.image(needsAttention: !model.status.conflicts.isEmpty))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Stagecoach").font(.headline)
                Text("Darkest Dungeon save sync").foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
            }

            // Both folders are found without being told. When one is missing it is
            // almost never the wrong path — it is that the thing which creates it
            // has not run yet, so say that rather than sending anyone to Settings.
            if model.steamRemote == nil {
                Label("Darkest Dungeon has no saves on this Mac yet", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Steam keeps them once the game has been played and signed in. If the game is installed elsewhere and you know the folder, it can be set in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.dropboxFolder == nil {
                Label("Dropbox has no Apps/DarkestDungeon folder yet", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("The iPad makes it the first time you use Dropbox there: tap the Dropbox icon on the main menu, choose Import, sign in, then close the dialogue. The folder will appear and this will find it on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(model.status.profiles.filter { !$0.missingAddOns.isEmpty }) { p in
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(p.estate ?? p.profile) uses add-ons the iPad has not got", systemImage: "iphone")
                        .foregroundStyle(.secondary).font(.callout.bold())
                    Text("It uses \(p.missingAddOns.map(Compatibility.readable).joined(separator: " and ")). The copy still goes over, and the iPad will offer to take that content out of its own copy before opening the campaign. It cannot put it back, and your Mac save is not affected either way.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            }

            ForEach(model.status.conflicts) { c in
                ConflictView(conflict: c)
            }

            if !model.status.profiles.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Campaign").foregroundStyle(.secondary)
                        Text("Week").foregroundStyle(.secondary)
                        Text("Mac saved").foregroundStyle(.secondary)
                        Text("Ready to import").foregroundStyle(.secondary)
                        Text("Steam Cloud").foregroundStyle(.secondary)
                    }.font(.caption)
                    ForEach(model.status.profiles) { p in
                        GridRow {
                            Text(p.estate.map { "\($0) · \(slotName(p.profile))" } ?? slotName(p.profile))
                            Text(p.weeks.map(String.init) ?? "–")
                            Text(p.macNewest.map(Self.date.string) ?? "–")
                            HStack(spacing: 4) {
                                Image(systemName: p.inStep && p.uploaded ? "checkmark.circle.fill" : "clock")
                                    .foregroundStyle(p.inStep && p.uploaded ? .green : .orange)
                                Text(!p.inStep ? "copying…" : (p.uploaded ? "yes" : "Dropbox uploading…"))
                            }
                            Text(cloudText(p))
                        }.font(.callout)
                    }
                }
            }

            if !model.status.waitingForDownload.isEmpty {
                Label("Waiting for Dropbox to finish downloading \(model.status.waitingForDownload.joined(separator: ", "))", systemImage: "icloud.and.arrow.down")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.status.waitingForGameToQuit {
                Label("An iPad save is waiting; it goes in when Darkest Dungeon quits.", systemImage: "gamecontroller")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let err = model.status.lastError {
                Label(err, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }

            // The one thing this Mac cannot know is what is on the iPad. It only
            // ever hears from it when an export arrives, so say when that was and
            // leave the judgement to the reader.
            Text(model.status.iPadLastExported.map { "The iPad last sent a save on \(Self.date.string(from: $0)). Nothing here can see the iPad otherwise." }
                 ?? "The iPad has not sent a save yet. Nothing here can see the iPad until it does.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Circle().fill(model.steamRunning ? .green : .gray).frame(width: 8, height: 8)
                Text(model.steamRunning ? "Steam running" : "Steam not running").font(.caption).foregroundStyle(.secondary)
                Circle().fill(model.gameRunning ? .orange : .gray).frame(width: 8, height: 8)
                Text(model.gameRunning ? "Game running" : "Game closed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let t = model.status.lastTick {
                    Text("checked \(Self.time.string(from: t))").font(.caption).foregroundStyle(.tertiary)
                }
            }

            Divider()

            DisclosureGroup("Recent activity") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.suffix(40).reversed().enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 140)
            }.font(.caption)

            HStack {
                Button("Sync now") { model.syncNow() }
                Button("Backups…") { NSWorkspace.shared.open(model.backupsFolder) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 440)
    }

    func slotName(_ profile: String) -> String {
        if let n = Int(profile.dropFirst("profile_".count)) { return "slot \(n + 1)" }
        return profile
    }

    func cloudText(_ p: ProfileStatus) -> String {
        switch p.record?.cloudState {
        case "uploaded": return "up to date"
        case "pendingGameLaunch": return "at next launch"
        case "pendingUpload": return "uploading…"
        default: return "–"
        }
    }

    static let date: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()
    static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
}

struct ConflictView: View {
    @EnvironmentObject var model: Model
    let conflict: Conflict

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(conflict.firstMeeting
                  ? "\(conflict.estate ?? conflict.profile) is on both machines, and they have never been synced"
                  : "Both sides have new progress in \(conflict.estate ?? conflict.profile)",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout.bold())
            Text(conflict.firstMeeting
                 ? "The iPad's copy was saved \(conflict.ipadNewest.map(PanelView.date.string) ?? "?") and the Mac's \(conflict.macNewest.map(PanelView.date.string) ?? "?"). Which is further on is not something a date can settle — opening a campaign and leaving again makes it the newer one — so it is yours to say. The one you don't keep is backed up."
                 : "The iPad export \(conflict.exportFolder) (saved \(conflict.ipadNewest.map(PanelView.date.string) ?? "?")) and the Mac save (saved \(conflict.macNewest.map(PanelView.date.string) ?? "?")) have both changed since they were last in step. The one you don't keep is backed up.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Keep the iPad save") { model.resolve(conflict, keep: "ipad") }
                Button("Keep the Mac save") { model.resolve(conflict, keep: "mac") }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Form {
            Section("Folders") {
                Text("All three are found on their own. Set one only if yours is somewhere unusual.")
                    .font(.caption).foregroundStyle(.secondary)
                FolderRow(title: "Steam save folder", url: model.steamRemote, key: "steamRemote", hint: "Steam/userdata/<id>/262060/remote")
                FolderRow(title: "Dropbox folder", url: model.dropboxFolder, key: "dropboxFolder", hint: "Dropbox/Apps/DarkestDungeon")
                FolderRow(title: "Steamworks library", url: model.steamworksLibrary, key: "steamworksLibrary", hint: "libsteam_api.dylib, borrowed from an installed Steam game", pickFile: true)
            }
            Section("Behaviour") {
                Toggle("Push imported saves to Steam Cloud through the Steam client", isOn: $model.cloudPush)
                Text("Needs Steam running. Otherwise the files are copied in place and Steam Cloud picks them up when the game next launches.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Every campaign is published with two small edits that let the iPad open it: one record the newer build writes into the campaign log, and the Butcher's Circus in the list of add-ons you have been shown. Nothing else is changed, and your Steam saves are never touched.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Move consumed iPad exports out of Apps/DarkestDungeon", isOn: $model.archiveExports)
                Text("The iPad's Import hangs if an export folder is left there. Moved exports go to Dropbox/Darkest Dungeon Save Sync/Imported exports.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.bottom, 8)
    }
}

struct FolderRow: View {
    @EnvironmentObject var model: Model
    let title: String
    let url: URL?
    let key: String
    let hint: String
    var pickFile = false

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack {
                    Text(url?.path.replacingOccurrences(of: Paths.home.path, with: "~") ?? "not found")
                        .font(.caption).foregroundStyle(url == nil ? .red : .primary).lineLimit(2).truncationMode(.middle)
                    Button("Choose…") { choose() }
                    if model.override(key) != nil { Button("Auto") { model.setOverride(key, nil) } }
                }
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = !pickFile
        p.canChooseFiles = pickFile
        p.allowsMultipleSelection = false
        if let url { p.directoryURL = pickFile ? url.deletingLastPathComponent() : url }
        if p.runModal() == .OK, let u = p.url { model.setOverride(key, u) }
    }
}
