import SwiftUI
import Foundation
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @State private var ipaURLString: String = ""
    @State private var statusMessage: String = ""
    @State private var manifestPath: String = ""
    @State private var showPicker: Bool = false

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
                        #if os(macOS)
                        NSWorkspace.shared.open(URL(fileURLWithPath: manifestPath))
                        #else
                        if let url = URL(string: manifestPath) ?? URL(fileURLWithPath: manifestPath) as URL? {
                            UIApplication.shared.open(url, options: [:], completionHandler: nil)
                        }
                        #endif
                    }
            }
        }
        .padding()
        .sheet(isPresented: $showPicker) {
            #if os(iOS)
            DocumentPicker(allowedTypes: [UTType(filenameExtension: "ipa")!]) { url in
                showPicker = false
                guard let url = url else { return }
                // copy to documents and process
                let dest = documentsDirectory().appendingPathComponent(url.lastPathComponent)
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: url, to: dest)
                    statusMessage = "Copied IPA to \(dest.path)"
                    processIPA(at: dest)
                } catch {
                    statusMessage = "Failed to copy IPA: \(error.localizedDescription)"
                }
            }
            #endif
        }
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
        #if os(macOS)
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
        #elseif os(iOS)
        showPicker = true
        #endif
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

    // Extract Info.plist bytes from the IPA.
    private func extractInfoPlist(fromIPA ipaURL: URL) -> Data? {
#if os(macOS)
        // Use system unzip on macOS for simplicity
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
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
#else
        // Minimal ZIP parsing to find Payload/*.app/Info.plist inside the IPA (ZIP) file.
        // Supports stored (0) and deflate (8) compression.
        import Compression

        guard let fileData = try? Data(contentsOf: ipaURL) else { return nil }
        var offset = 0
        let dataCount = fileData.count

        func readUInt32(_ off: Int) -> UInt32 {
            let sub = fileData.subdata(in: off..<(off+4))
            return UInt32(littleEndian: sub.withUnsafeBytes { $0.load(as: UInt32.self) })
        }
        func readUInt16(_ off: Int) -> UInt16 {
            let sub = fileData.subdata(in: off..<(off+2))
            return UInt16(littleEndian: sub.withUnsafeBytes { $0.load(as: UInt16.self) })
        }

        while offset + 30 <= dataCount {
            let sig = readUInt32(offset)
            // Local file header signature
            if sig != 0x04034b50 { break }
            // fields
            // version needed (2) + flags (2) + compression (2)
            let compression = readUInt16(offset + 8)
            let compSize = UInt32(littleEndian: fileData.subdata(in: (offset+18)..<(offset+22)).withUnsafeBytes { $0.load(as: UInt32.self) })
            let uncompSize = UInt32(littleEndian: fileData.subdata(in: (offset+22)..<(offset+26)).withUnsafeBytes { $0.load(as: UInt32.self) })
            let nameLen = Int(readUInt16(offset + 26))
            let extraLen = Int(readUInt16(offset + 28))

            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            if nameEnd > dataCount { break }
            let nameData = fileData.subdata(in: nameStart..<nameEnd)
            let filename = String(data: nameData, encoding: .utf8) ?? ""

            let dataStart = nameEnd + extraLen
            let dataEnd = Int(dataStart) + Int(compSize)
            if dataEnd > dataCount { break }

            if filename.hasPrefix("Payload/") && filename.hasSuffix(".app/Info.plist") {
                let compData = fileData.subdata(in: dataStart..<dataEnd)
                if compression == 0 {
                    return compData
                } else if compression == 8 {
                    // DEFLATE - use Compression to decode
                    let dstSize = Int(uncompSize)
                    var dst = Data(count: dstSize)
                    let result = dst.withUnsafeMutableBytes { dstBuf -> Int in
                        return compData.withUnsafeBytes { srcBuf in
                            let srcPtr = srcBuf.bindMemory(to: UInt8.self).baseAddress!
                            let dstPtr = dstBuf.bindMemory(to: UInt8.self).baseAddress!
                            let decoded = compression_decode_buffer(dstPtr, dstSize, srcPtr, compData.count, nil, COMPRESSION_ZLIB)
                            return decoded
                        }
                    }
                    if result > 0 {
                        return dst
                    }
                }
                return nil
            }

            // move to next header
            offset = dataEnd
        }
        return nil
#endif

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

#if os(iOS)
import SwiftUI

struct DocumentPicker: UIViewControllerRepresentable {
    let allowedTypes: [UTType]
    let completion: (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes, asCopy: true)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker

        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.completion(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.completion(nil)
        }
    }
}
#endif

#Preview {
    ContentView()
}
