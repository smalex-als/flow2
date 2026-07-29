import AppKit
import Foundation
import SwiftUI

struct AboutView: View {
    private let buildInformation = BuildInformation.current

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("Flow2")
                    .font(.title.bold())

                Text(buildInformation.versionDescription)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                if let change = buildInformation.latestChange {
                    informationRow("Latest change", change)
                }
                informationRow("Commit", buildInformation.commitDescription)
                informationRow("Built", buildInformation.formattedBuildDate)
                informationRow("Configuration", buildInformation.configuration)
                informationRow("Built from", buildInformation.sourceRoot)
                informationRow("Running from", Bundle.main.bundleURL.path)
            }
            .font(.callout)
        }
        .padding(28)
        .frame(width: 560)
    }

    @ViewBuilder
    private func informationRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)

            Text(value)
                .fontDesign(.monospaced)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .help(value)
                .gridColumnAlignment(.leading)
        }
    }
}

private struct BuildInformation {
    let version: String
    let build: String
    let buildDate: Date?
    let configuration: String
    let sourceRoot: String
    let commit: String
    let branch: String
    let latestChange: String?
    let isDirty: Bool

    static let current: BuildInformation = {
        let bundle = Bundle.main
        let dictionary = loadBuildDictionary(from: bundle)
        let buildDate = (dictionary?["BuildDate"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }

        func string(_ key: String) -> String {
            (dictionary?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let buildNumber = string("BuildNumber")

        return BuildInformation(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            build: buildNumber.isEmpty
                ? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
                : buildNumber,
            buildDate: buildDate,
            configuration: dictionary?["Configuration"] as? String ?? "Unknown",
            sourceRoot: dictionary?["SourceRoot"] as? String ?? "Not recorded",
            commit: string("Commit"),
            branch: string("Branch"),
            latestChange: string("CommitSubject").isEmpty ? nil : string("CommitSubject"),
            isDirty: string("Dirty") == "yes"
        )
    }()

    private static func loadBuildDictionary(from bundle: Bundle) -> [String: Any]? {
        guard
            let url = bundle.url(forResource: "BuildInfo", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let dictionary = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        else {
            return nil
        }

        return dictionary
    }

    var versionDescription: String {
        "Version \(version) (build \(build))"
    }

    /// Names the exact source the build came from, so a version number alone never has to carry the
    /// question of which changes are actually in the app that is running.
    var commitDescription: String {
        guard !commit.isEmpty else { return "Not recorded" }

        var description = commit
        if !branch.isEmpty {
            description += " on \(branch)"
        }
        if isDirty {
            description += " + uncommitted changes"
        }
        return description
    }

    var formattedBuildDate: String {
        guard let buildDate else {
            return "Not recorded"
        }

        return buildDate.formatted(date: .abbreviated, time: .standard)
    }
}
