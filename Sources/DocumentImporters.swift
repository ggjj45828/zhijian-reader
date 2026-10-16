import Foundation
import ZIPFoundation

struct ParsedDocument {
    var title: String?
    var author: String?
    var content: String
}

private enum DocumentImportError: Error {
    case corruptArchive, missingPackage, invalidXML, noReadableText, oversizedEntry
}

private enum ArchiveReader {
    static let maxEntrySize: UInt64 = 32 * 1024 * 1024

    static func data(_ archive: Archive, path: String) throws -> Data {
        guard let entry = archive[path] else { throw DocumentImportError.missingPackage }
        guard entry.uncompressedSize <= Int64(maxEntrySize) else { throw DocumentImportError.oversizedEntry }
        var result = Data()
        try archive.extract(entry, consumer: { chunk in
            guard UInt64(result.count) + UInt64(chunk.count) <= maxEntrySize else { throw DocumentImportError.oversizedEntry }
            result.append(chunk)
        })
        return result
    }

    static func normalizedPath(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if part != "." { parts.append(part) }
        }
        return parts.map(String.init).joined(separator: "/")
    }
}

struct EPUBDocument {
    let url: URL

    func read() throws -> ParsedDocument {
        let archive = try Archive(url: url, accessMode: .read)
        let container = try ArchiveReader.data(archive, path: "META-INF/container.xml")
        let containerParser = EPUBContainerParser()
        let xml = XMLParser(data: container); xml.delegate = containerParser
        guard xml.parse(), let packagePath = containerParser.packagePath else { throw DocumentImportError.invalidXML }
        let opf = try ArchiveReader.data(archive, path: packagePath)
        let packageParser = EPUBPackageParser()
        let opfParser = XMLParser(data: opf); opfParser.delegate = packageParser
        guard opfParser.parse(), !packageParser.spine.isEmpty else { throw DocumentImportError.invalidXML }
        let base = (packagePath as NSString).deletingLastPathComponent
        var chapters: [String] = []
        for itemID in packageParser.spine {
            guard let href = packageParser.manifest[itemID] else { continue }
            let decodedHref = href.removingPercentEncoding ?? href
            let itemPath = ArchiveReader.normalizedPath(base.isEmpty ? decodedHref : "\(base)/\(decodedHref)")
            guard let chapterData = try? ArchiveReader.data(archive, path: itemPath) else { continue }
            let html = String(decoding: chapterData, as: UTF8.self)
            let chapter = HTMLText.extract(html)
            if chapter.count > 10 { chapters.append(chapter) }
        }
        let content = chapters.joined(separator: "\n\n")
        guard !content.isEmpty else { throw DocumentImportError.noReadableText }
        return ParsedDocument(title: packageParser.title, author: packageParser.author, content: content)
    }
}

private final class EPUBContainerParser: NSObject, XMLParserDelegate {
    var packagePath: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
        if elementName == "rootfile" { packagePath = attributes["full-path"] }
    }
}

private final class EPUBPackageParser: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []
    var title: String?
    var author: String?
    private var currentMetadata: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
        let name = (elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased()
        if name == "item", let id = attributes["id"], let href = attributes["href"] { manifest[id] = href }
        if name == "itemref", let id = attributes["idref"] { spine.append(id) }
        if name == "title" || name == "creator" { currentMetadata = name; text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if currentMetadata != nil { text += string } }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = (elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased()
        if name == currentMetadata {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "title", title == nil, !value.isEmpty { title = value }
            if name == "creator", author == nil, !value.isEmpty { author = value }
            currentMetadata = nil; text = ""
        }
    }
}

struct DOCXDocument {
    let url: URL
    func read() throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        let xmlData = try ArchiveReader.data(archive, path: "word/document.xml")
        let delegate = DOCXParser()
        let parser = XMLParser(data: xmlData); parser.delegate = delegate
        guard parser.parse() else { throw DocumentImportError.invalidXML }
        let text = delegate.paragraphs.joined(separator: "\n\n")
        guard !text.isEmpty else { throw DocumentImportError.noReadableText }
        return text
    }
}

private final class DOCXParser: NSObject, XMLParserDelegate {
    var paragraphs: [String] = []
    private var inText = false
    private var paragraph = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
        if elementName == "w:p" { paragraph = "" }
        if elementName == "w:t" { inText = true }
        if elementName == "w:tab" { paragraph += "\t" }
        if elementName == "w:br" { paragraph += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { paragraph += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:t" { inText = false }
        if elementName == "w:p" {
            let value = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { paragraphs.append(value) }
        }
    }
}

struct FB2Document {
    let data: Data
    func read() throws -> ParsedDocument {
        let delegate = FB2Parser()
        let parser = XMLParser(data: data); parser.delegate = delegate
        guard parser.parse() else { throw DocumentImportError.invalidXML }
        let content = delegate.paragraphs.joined(separator: "\n\n")
        guard !content.isEmpty else { throw DocumentImportError.noReadableText }
        return ParsedDocument(title: delegate.title, author: delegate.author, content: content)
    }
}

private final class FB2Parser: NSObject, XMLParserDelegate {
    var title: String?
    var author: String?
    var paragraphs: [String] = []
    private var stack: [String] = []
    private var capture: String?
    private var captured = ""
    private var bodyDepth = 0
    private var paragraph = ""
    private var inParagraph = false
    private var inAuthor = false
    private var authorText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
        let name = local(elementName)
        stack.append(name)
        if name == "body" { bodyDepth += 1 }
        if name == "book-title", stack.contains("title-info") { capture = "title"; captured = "" }
        if name == "author", stack.contains("title-info") { inAuthor = true; authorText = "" }
        if name == "p" && bodyDepth > 0 { inParagraph = true; paragraph = "" }
        if name == "title" && bodyDepth > 0 { inParagraph = true; paragraph = "" }
        if name == "empty-line" && bodyDepth > 0 { paragraphs.append("") }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture != nil { captured += string }
        if inAuthor { authorText += string }
        if inParagraph { paragraph += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = local(elementName)
        if name == "p" || (name == "title" && bodyDepth > 0) {
            let value = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { paragraphs.append(value) }
            inParagraph = false; paragraph = ""
        }
        if name == "book-title", capture == "title" {
            let value = captured.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { title = value }; capture = nil
        }
        if name == "author", inAuthor {
            let value = authorText.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { author = value }; inAuthor = false
        }
        if name == "body" { bodyDepth = max(0, bodyDepth - 1) }
        if !stack.isEmpty { stack.removeLast() }
    }
    private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }
}
