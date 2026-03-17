import SwiftUI
import Foundation
import AppKit

struct ContentView: View {
    @State private var ipaURLString: String = ""
    @State private var statusMessage: String = ""
    @State private var manifestPath: String = ""

    var body: some View {
        VStack(spacing: 12) {
            TextField("Enter IPA URL", text: $ipaURLString)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()

            Text("Or")

            Button(action: pickLocalIPA) {
                Text("Select IPA from Device")
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }

            Button(action: installAction) {
                Text("Process IPA / Create Manifest")
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .disabled(ipaURLString.isEmpty && manifestPath.isEmpty && statusMessage.isEmpty)

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }

            if !manifestPath.isEmpty {
                Text("Manifest created:")
                    .bold()
                Text(manifestPath)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .onTapGesture {
                        NSWorkspace.shared.open(URL(fileURLWithPath: manifestPath))
                    }
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func installAction() {
        statusMessage = "Starting..."
        if let url = URL(string: ipaURLString), url.scheme?.hasPrefix("http") == true {
            downloadIPA(from: url)
        } else if !ipaURLString.isEmpty, FileManager.default.fileExists(atPath: ipaURLString) {
            // user pasted a local path
            processIPA(at: URL(fileURLWithPath: ipaURLString))
        } else if !manifestPath.isEmpty {
            statusMessage = "Manifest already exists at \(manifestPath)"
        } else {
            statusMessage = "Provide an HTTP URL or pick a local IPA file."
        }
    }

    private func pickLocalIPA() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Select IPA file"

        if panel.runModal() == .OK, let url = panel.url {
            // copy to app Documents directory
            let dest = documentsDirectory().appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                statusMessage = "Copied IPA to \(dest.path)"
                // Trigger processing
                processIPA(at: dest)
            } catch {
                statusMessage = "Failed to copy IPA: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Download

    private func downloadIPA(from url: URL) {
        statusMessage = "Downloading IPA..."
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            if let error = error {
                DispatchQueue.main.async { statusMessage = "Download failed: \(error.localizedDescription)" }
                return
            }
            guard let localURL = localURL else {
                DispatchQueue.main.async { statusMessage = "Download failed: no file" }
                return
            }

            let dest = documentsDirectory().appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: localURL, to: dest)
                DispatchQueue.main.async {
                    statusMessage = "Downloaded to \(dest.path)"
                    processIPA(at: dest)
                }
            } catch {
                DispatchQueue.main.async { statusMessage = "Failed to move downloaded IPA: \(error.localizedDescription)" }
            }
        }
        task.resume()
    }

    // MARK: - Processing

    private func processIPA(at ipaURL: URL) {
        statusMessage = "Extracting Info.plist..."
        DispatchQueue.global(qos: .userInitiated).async {
            guard let infoPlistData = extractInfoPlist(fromIPA: ipaURL) else {
                DispatchQueue.main.async { statusMessage = "Failed to extract Info.plist" }
                return
            }

            do {
                let plist = try PropertyListSerialization.propertyList(from: infoPlistData, options: [], format: nil)
                guard let info = plist as? [String:Any] else {
                    DispatchQueue.main.async { statusMessage = "Invalid Info.plist format" }
                    return
                }

                let bundleId = info["CFBundleIdentifier"] as? String ?? ""
                let version = info["CFBundleVersion"] as? String ?? (info["CFBundleShortVersionString"] as? String ?? "1.0")
                let title = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ipaURL.deletingPathExtension().lastPathComponent

                // Create manifest pointing to the IPA file location. Note: for OTA install the manifest must be reachable via HTTPS.
                let ipaFileURL = ipaURL.absoluteString
                let manifestDict: [String:Any] = [
                    "items": [[
                        "assets": [["kind": "software-package", "url": ipaFileURL]],
                        "metadata": [
                            "bundle-identifier": bundleId,
                            "bundle-version": version,
                            "kind": "software",
                            "title": title
                        ]
                    ]]
                ]

                let manifestData = try PropertyListSerialization.data(fromPropertyList: manifestDict, format: .xml, options: 0)
                let manifestURL = documentsDirectory().appendingPathComponent("\(title)-manifest.plist")
                try manifestData.write(to: manifestURL)

                DispatchQueue.main.async {
                    manifestPath = manifestURL.path
                    statusMessage = "Manifest created at \(manifestURL.path)\nNote: To install over the air, host both the .ipa and this manifest plist over HTTPS and use an itms-services:// link."
                }
            } catch {
                DispatchQueue.main.async { statusMessage = "Processing failed: \(error.localizedDescription)" }
            }
        }
    }

    // Extract Info.plist bytes from the IPA by using /usr/bin/unzip -p
    private func extractInfoPlist(fromIPA ipaURL: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // Use pattern to match Payload/*.app/Info.plist
        process.arguments = ["-p", ipaURL.path, "Payload/*.app/Info.plist"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    private func documentsDirectory() -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let dir = docs.appendingPathComponent("IPA-Installer")
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

#Preview {
    ContentView()
}
