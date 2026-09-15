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
            Image(systemName: model.status.conflicts.isEmpty ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
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

            if model.steamRemote == nil || model.dropboxFolder == nil {
                Label(model.steamRemote == nil ? "Steam's Darkest Dungeon save folder wasn't found." : "The Dropbox Apps/DarkestDungeon folder wasn't found.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Choose the folders in Settings.").font(.caption).foregroundStyle(.secondary)
            }

            ForEach(model.status.conflicts) { c in
                ConflictView(conflict: c)
            }

            if !model.status.profiles.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Slot").foregroundStyle(.secondary)
                        Text("Mac saved").foregroundStyle(.secondary)
                        Text("Ready for iPad").foregroundStyle(.secondary)
                        Text("Steam Cloud").foregroundStyle(.secondary)
                    }.font(.caption)
                    ForEach(model.status.profiles) { p in
                        GridRow {
                            Text(slotName(p.profile))
                            Text(p.macNewest.map(Self.date.string) ?? "–")
                            HStack(spacing: 4) {
                                Image(systemName: p.inStep ? "checkmark.circle.fill" : "clock")
                                    .foregroundStyle(p.inStep ? .green : .orange)
                                Text(p.inStep ? "in step" : "copying…")
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
            if !model.status.exportsStuck.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(model.status.exportsStuck.joined(separator: ", ")) is still inside Apps/DarkestDungeon", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout.bold())
                    Text("Its save is already imported, but the iPad's Import hangs while an export folder is there. Dropbox asks to confirm moving it out; click Move when it asks.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Move it out now") { model.retryArchive() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            if model.status.waitingForGameToQuit {
                Label("An iPad save is waiting; it goes in when Darkest Dungeon quits.", systemImage: "gamecontroller")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let err = model.status.lastError {
                Label(err, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }

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
        if let n = Int(profile.dropFirst("profile_".count)) { return "Campaign slot \(n + 1)" }
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
            Label("Both sides have new progress in \(conflict.profile)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout.bold())
            Text("The iPad export \(conflict.exportFolder) (saved \(conflict.ipadNewest.map(PanelView.date.string) ?? "?")) and the Mac save (saved \(conflict.macNewest.map(PanelView.date.string) ?? "?")) have both changed since they were last in step. The one you don't keep is backed up.")
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
                FolderRow(title: "Steam save folder", url: model.steamRemote, key: "steamRemote", hint: "Steam/userdata/<id>/262060/remote")
                FolderRow(title: "Dropbox folder", url: model.dropboxFolder, key: "dropboxFolder", hint: "Dropbox/Apps/DarkestDungeon")
                FolderRow(title: "Steamworks library", url: model.steamworksLibrary, key: "steamworksLibrary", hint: "libsteam_api.dylib, borrowed from an installed Steam game", pickFile: true)
            }
            Section("Behaviour") {
                Toggle("Push imported saves to Steam Cloud through the Steam client", isOn: $model.cloudPush)
                Text("Needs Steam running. Otherwise the files are copied in place and Steam Cloud picks them up when the game next launches.")
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
