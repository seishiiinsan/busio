import Foundation

/// Lecteur CSV RFC 4180 minimal (guillemets, CRLF, BOM) pour les fichiers GTFS.
struct CSVTable {
    let header: [String]
    let rows: [[String]]
    private let columns: [String: Int]

    init(data: Data) {
        var rows = CSVTable.parse(data)
        header = rows.isEmpty ? [] : rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        self.rows = rows.filter { !($0.count == 1 && $0[0].isEmpty) }
        columns = Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func column(_ name: String) -> Int? { columns[name] }

    static func value(_ row: [String], _ index: Int?) -> String? {
        guard let index, row.indices.contains(index) else { return nil }
        let value = row[index].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func parse(_ data: Data) -> [[String]] {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }

        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var i = 0
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")

        func endField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }

        while i < bytes.count {
            let b = bytes[i]
            if inQuotes {
                if b == quote {
                    if i + 1 < bytes.count, bytes[i + 1] == quote {
                        field.append(quote)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(b)
                }
            } else if b == quote {
                inQuotes = true
            } else if b == comma {
                endField()
            } else if b == lf || b == cr {
                endField()
                rows.append(row)
                row.removeAll(keepingCapacity: true)
                if b == cr, i + 1 < bytes.count, bytes[i + 1] == lf { i += 1 }
            } else {
                field.append(b)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            endField()
            rows.append(row)
        }
        return rows
    }
}
