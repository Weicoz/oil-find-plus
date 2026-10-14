import Foundation
import PDFKit

public struct DocumentExtractionResult {
    public let text: String
    public let pageCount: Int

    public init(text: String, pageCount: Int = 1) {
        self.text = text
        self.pageCount = pageCount
    }
}

public final class DocumentExtractor {
    public static let supportedExtensions: Set<String> = [
        "pdf", "docx", "pptx", "xlsx", "pages", "numbers", "key",
        "txt", "md", "markdown", "rtf", "csv", "tsv", "json", "yaml", "yml", "toml", "log", "tex"
    ]

    public init() {}

    public func extract(path: String, cancelled: @escaping () -> Bool = { false }) -> DocumentExtractionResult? {
        guard !cancelled() else { return nil }

        // Skip files > 50MB to prevent memory exhaustion
        if let attr = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attr[.size] as? UInt64, size > 50_000_000 {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        return autoreleasepool {
            switch ext {
            case "pdf":
                return extractPDF(url: url, cancelled: cancelled)
            case "pages", "numbers", "key":
                return extractIWork(url: url, cancelled: cancelled)
            case "docx":
                return extractOffice(path: path, entryPattern: "word/document.xml")
            case "pptx":
                return extractOffice(path: path, entryPattern: "ppt/slides/slide*.xml")
            case "xlsx":
                return extractOffice(path: path, entryPattern: "xl/sharedStrings.xml")
            case "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "toml", "log", "tex":
                return extractPlainText(url: url)
            case "rtf":
                return extractRTF(url: url)
            default:
                return nil
            }
        }
    }

    private func extractPDF(url: URL, cancelled: () -> Bool) -> DocumentExtractionResult? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var fullText = ""
        let count = doc.pageCount
        let limit = min(count, 150)
        for i in 0..<limit {
            if cancelled() { return nil }
            if let page = doc.page(at: i), let str = page.string {
                fullText.append(str)
                fullText.append("\n")
            }
        }
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : DocumentExtractionResult(text: trimmed, pageCount: count)
    }

    private func extractIWork(url: URL, cancelled: () -> Bool) -> DocumentExtractionResult? {
        // If iWork bundle has QuickLook/Preview.pdf
        let previewURL = url.appendingPathComponent("QuickLook/Preview.pdf")
        if FileManager.default.fileExists(atPath: previewURL.path) {
            return extractPDF(url: previewURL, cancelled: cancelled)
        }
        // If zipped iWork package
        return extractOfficePDF(path: url.path, entryPattern: "QuickLook/Preview.pdf", cancelled: cancelled)
    }

    private func extractPlainText(url: URL) -> DocumentExtractionResult? {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attr[.size] as? UInt64, size < 10_000_000 else {
            return nil
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return nil
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : DocumentExtractionResult(text: trimmed, pageCount: 1)
    }

    private func extractRTF(url: URL) -> DocumentExtractionResult? {
        guard let data = try? Data(contentsOf: url),
              let attrStr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
            return nil
        }
        let str = attrStr.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return str.isEmpty ? nil : DocumentExtractionResult(text: str, pageCount: 1)
    }

    private func extractOffice(path: String, entryPattern: String) -> DocumentExtractionResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", path, entryPattern]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty,
                  let xml = String(data: data, encoding: .utf8) else {
                return nil
            }
            let text = stripXMLTags(xml)
            return text.isEmpty ? nil : DocumentExtractionResult(text: text, pageCount: 1)
        } catch {
            return nil
        }
    }

    private func extractOfficePDF(path: String, entryPattern: String, cancelled: () -> Bool) -> DocumentExtractionResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", path, entryPattern]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty,
                  let doc = PDFDocument(data: data) else {
                return nil
            }
            var fullText = ""
            let limit = min(doc.pageCount, 150)
            for i in 0..<limit {
                if cancelled() { return nil }
                if let page = doc.page(at: i), let str = page.string {
                    fullText.append(str)
                    fullText.append("\n")
                }
            }
            let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : DocumentExtractionResult(text: trimmed, pageCount: doc.pageCount)
        } catch {
            return nil
        }
    }

    private func stripXMLTags(_ xml: String) -> String {
        // Fast strip of XML tags
        var result = ""
        result.reserveCapacity(xml.count / 2)
        var inTag = false
        for ch in xml {
            if ch == "<" {
                inTag = true
            } else if ch == ">" {
                inTag = false
                result.append(" ")
            } else if !inTag {
                result.append(ch)
            }
        }
        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
