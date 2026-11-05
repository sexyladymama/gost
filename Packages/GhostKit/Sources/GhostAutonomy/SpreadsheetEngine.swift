import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

/// Sous-ensemble explicite : documents CSV/TSV de ventes, nombres décimaux exacts à deux décimales.
public enum SalesParser {
    public static func parse(_ text: String, source: String) throws -> [SalesRecord] {
        guard text.utf8.count <= SecureFiles.maxBytes else { throw ExecutionError.invalid("Source trop volumineuse.") }
        let separator: Character = source.lowercased().hasSuffix(".tsv") ? "\t" : (text.split(separator: "\n").first?.contains(";") == true ? ";" : ",")
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, closingQuote = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]; let next = text.index(after: index)
            if quoted {
                if char == "\"" {
                    if next < text.endIndex, text[next] == "\"" { field.append("\""); index = text.index(after: next); continue }
                    quoted = false; closingQuote = true
                } else { field.append(char) }
            } else if char == "\"", field.isEmpty, !closingQuote { quoted = true }
            else if char == separator { row.append(field); field = ""; closingQuote = false }
            else if char == "\n" {
                row.append(field); if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                row = []; field = ""; closingQuote = false
            } else if char != "\r" {
                guard !closingQuote else { throw ExecutionError.invalid("CSV invalide : texte après fermeture de guillemets.") }
                field.append(char)
            }
            index = next
        }
        guard !quoted else { throw ExecutionError.invalid("CSV invalide : guillemets non fermés.") }
        row.append(field); if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
        guard let header = rows.first, header.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "\u{feff}", with: "") }) == ["produit", "quantite", "prix_unitaire"] else {
            throw ExecutionError.approval("En-tête attendu : produit,quantite,prix_unitaire. Aucune colonne n'a été inventée.")
        }
        guard rows.count > 1, rows.count <= 5_001 else { throw ExecutionError.invalid("La source doit contenir de 1 à 5 000 lignes de données.") }
        return try rows.dropFirst().enumerated().map { index, row in
            guard row.count == 3 else { throw ExecutionError.invalid("\(source), ligne \(index + 2) : trois colonnes attendues.") }
            let product = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !product.isEmpty, product.count <= 500,
                  !product.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }),
                  let quantity = Int64(row[1].trimmingCharacters(in: .whitespaces)), (1...100_000).contains(quantity),
                  let price = cents(row[2]), (0...100_000_000).contains(price) else {
                throw ExecutionError.invalid("\(source), ligne \(index + 2) : produit, quantité entière positive ou prix invalide.")
            }
            return SalesRecord(product: product, quantity: quantity, unitCents: price, source: source, sourceRow: index + 2)
        }
    }
    static func cents(_ value: String) -> Int64? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber),
              parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= 2 && parts[1].allSatisfy(\.isNumber)),
              let whole = Int64(parts[0]), whole <= 1_000_000_000_000 else { return nil }
        let fractional = parts.count == 1 ? "00" : String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0)
        guard let decimals = Int64(fractional) else { return nil }
        return whole * 100 + decimals
    }
    static func decimal(_ cents: Int64) -> String { "\(cents / 100).\(String(format: "%02lld", cents % 100))" }
}

/// XLSX Open XML natif, empaqueté avec ZIPFoundation (MIT, version épinglée).
/// Aucun interpréteur, macro, formule fournie par une source, ni appel réseau.
public enum SpreadsheetEngine {
    private static let paths: Set<String> = ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/worksheets/sheet1.xml"]
    public static func create(records: [SalesRecord]) throws -> Data {
        try validate(records)
        let last = records.count + 4
        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:F\(last)"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="4" topLeftCell="A5" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols><col min="1" max="1" width="30" customWidth="1"/><col min="2" max="4" width="18" customWidth="1"/><col min="5" max="5" width="35" customWidth="1"/><col min="6" max="6" width="12" customWidth="1"/></cols><sheetData>
        <row r="1">\(string("A1", "Récapitulatif commercial", style: 1))</row>
        <row r="2">\(string("A2", "Total"))\(number("B2", String(records.reduce(0) { $0 + $1.quantity }), formula: "SUM(B5:B\(last))"))\(number("D2", SalesParser.decimal(records.reduce(0) { $0 + $1.totalCents }), formula: "SUM(D5:D\(last))", style: 2))</row>
        <row r="3">\(string("A3", "Montants = quantité × prix unitaire ; unité monétaire non déduite."))</row>
        <row r="4">\(zip(["A", "B", "C", "D", "E", "F"], ["Produit", "Quantité", "Prix unitaire", "Montant", "Source", "Ligne source"]).map { string($0.0 + "4", $0.1, style: 1) }.joined())</row>
        """
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            let r = index + 5
            sheet += "<row r=\"\(r)\">" + string("A\(r)", record.product) + number("B\(r)", String(record.quantity))
                + number("C\(r)", SalesParser.decimal(record.unitCents), style: 2)
                + number("D\(r)", SalesParser.decimal(record.totalCents), formula: "B\(r)*C\(r)", style: 2)
                + string("E\(r)", record.source) + number("F\(r)", String(record.sourceRow)) + "</row>"
        }
        sheet += "</sheetData><autoFilter ref=\"A4:F\(last)\"/></worksheet>"
        let parts: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """,
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Ventes" sheetId="1" r:id="rId1"/></sheets><calcPr calcMode="auto" fullCalcOnLoad="1"/></workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """,
            "xl/styles.xml": """
            <?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF233B55"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFill="1" applyFont="1"/><xf numFmtId="2" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
            """,
            "xl/worksheets/sheet1.xml": sheet
        ]
        let archive = try Archive(accessMode: .create)
        for path in parts.keys.sorted() {
            let data = Data(parts[path]!.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        guard let data = archive.data else { throw ExecutionError.invalid("Échec de création XLSX.") }
        return data
    }
    public static func verify(_ data: Data, expected: [SalesRecord], expectedHash: String? = nil) -> VerificationReport {
        var checks: [String] = [], problems: [String] = []
        do {
            try validate(expected)
            guard data.count <= SecureFiles.maxBytes else { throw ExecutionError.invalid("Classeur trop volumineux.") }
            let archive = try Archive(data: data, accessMode: .read)
            let entries = Array(archive)
            guard entries.count == paths.count, Set(entries.map(\.path)) == paths else { throw ExecutionError.invalid("Structure XLSX inattendue ou contenu supplémentaire.") }
            var worksheet = Data()
            for entry in entries {
                guard entry.uncompressedSize <= SecureFiles.maxBytes else { throw ExecutionError.invalid("Entrée ZIP trop volumineuse.") }
                var extracted = Data()
                let crc = try archive.extract(entry) { chunk in
                    guard extracted.count + chunk.count <= SecureFiles.maxBytes else { throw ExecutionError.invalid("Décompression trop volumineuse.") }
                    extracted.append(chunk)
                }
                guard crc == entry.checksum else { throw ExecutionError.invalid("Somme de contrôle ZIP incorrecte.") }
                let text = String(decoding: extracted, as: UTF8.self).uppercased()
                guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw ExecutionError.invalid("Entités XML interdites.") }
                let parser = XMLParser(data: extracted); parser.shouldResolveExternalEntities = false
                guard parser.parse() else { throw ExecutionError.invalid("XML invalide : \(entry.path).") }
                if entry.path == "xl/worksheets/sheet1.xml" { worksheet = extracted }
            }
            checks.append("Paquet ZIP, CRC et six composants XML valides, sans macro ni lien externe.")
            let reader = CellReader()
            let parser = XMLParser(data: worksheet); parser.shouldResolveExternalEntities = false; parser.delegate = reader
            guard parser.parse(), !reader.duplicate, reader.cells.count == expected.count * 6 + 11 else { throw ExecutionError.invalid("Nombre ou unicité des cellules incorrects.") }
            let last = expected.count + 4
            guard reader.cells["B2"]?.formula == "SUM(B5:B\(last))", reader.cells["D2"]?.formula == "SUM(D5:D\(last))",
                  reader.cells["B2"]?.value == String(expected.reduce(0) { $0 + $1.quantity }),
                  SalesParser.cents(reader.cells["D2"]?.value ?? "") == expected.reduce(0, { $0 + $1.totalCents }) else {
                throw ExecutionError.invalid("Formules ou totaux généraux incohérents.")
            }
            for (index, record) in expected.enumerated() {
                let r = index + 5
                guard reader.cells["A\(r)"]?.value == record.product, reader.cells["B\(r)"]?.value == String(record.quantity),
                      SalesParser.cents(reader.cells["C\(r)"]?.value ?? "") == record.unitCents,
                      SalesParser.cents(reader.cells["D\(r)"]?.value ?? "") == record.totalCents,
                      reader.cells["D\(r)"]?.formula == "B\(r)*C\(r)", reader.cells["E\(r)"]?.value == record.source,
                      reader.cells["F\(r)"]?.value == String(record.sourceRow) else { throw ExecutionError.invalid("Données, calcul ou provenance incorrects à la ligne \(r).") }
            }
            checks.append("Toutes les lignes, provenances, produits, quantités et prix concordent avec les sources.")
            checks.append("Produits quantité × prix et sommes recalculés indépendamment en centimes entiers.")
            let hash = ExecutionIdentity.hash(data)
            if let expectedHash, expectedHash != hash { throw ExecutionError.invalid("Le fichier sauvegardé diffère de l'artefact produit.") }
            return VerificationReport(status: .passed, checks: checks, problems: [], artifactHash: hash, verifiedAt: Date())
        } catch { problems.append(error.localizedDescription) }
        return VerificationReport(status: .failed, checks: checks, problems: problems, artifactHash: nil, verifiedAt: Date())
    }
    private static func validate(_ records: [SalesRecord]) throws {
        guard !records.isEmpty, records.count <= 5_000, records.allSatisfy({ !$0.product.isEmpty && $0.product.count <= 500 && (1...100_000).contains($0.quantity) && (0...100_000_000).contains($0.unitCents) }) else {
            throw ExecutionError.invalid("De 1 à 5 000 lignes commerciales valides sont nécessaires.")
        }
    }
    private static func xml(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;") }
    private static func string(_ ref: String, _ text: String, style: Int = 0) -> String { "<c r=\"\(ref)\" s=\"\(style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(text))</t></is></c>" }
    private static func number(_ ref: String, _ value: String, formula: String? = nil, style: Int = 0) -> String { "<c r=\"\(ref)\" s=\"\(style)\">" + (formula.map { "<f>\(xml($0))</f>" } ?? "") + "<v>\(value)</v></c>" }
}

private final class CellReader: NSObject, XMLParserDelegate {
    struct Cell { var value = ""; var formula: String? }
    var cells: [String: Cell] = [:]
    var duplicate = false
    private var reference = "", element = ""
    private var current = Cell()
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        element = elementName
        if elementName == "c" { reference = attributes["r"] ?? ""; current = Cell() }
        if elementName == "f" { current.formula = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if element == "v" || element == "t" { current.value += string }
        else if element == "f" { current.formula = (current.formula ?? "") + string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "c" { if cells[reference] != nil { duplicate = true }; cells[reference] = current }
        element = ""
    }
}
