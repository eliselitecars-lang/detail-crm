//
//  MoneyPDFService.swift
//  DetailCRM
//
//  Quote and invoice PDFs (P-34). The `pdf` edge function renders them from
//  the same data the customer's /q and /i pages show (amounts exactly as
//  the server has them; drafts are marked DRAFT). Staff: owners, admins and
//  managers; technicians only for invoices they may collect on. The file is
//  written to a private temporary folder for the share sheet.
//

import Foundation
import Supabase

enum MoneyPDFService {

    /// Which document to render.
    enum Kind: String, Hashable, Sendable {
        case quote
        case invoice

        /// "quote-1042.pdf"
        func fileName(number: Int) -> String {
            "\(rawValue)-\(number).pdf"
        }
    }

    /// Renders the document and returns a local file URL (a fresh file per
    /// call, inside a temporary folder the system cleans up).
    static func download(shopID: UUID, kind: Kind, documentID: UUID, number: Int) async throws -> URL {
        struct Body: Encodable {
            let action = "staff_document"
            let shop_id: String
            let kind: String
            let id: String
        }
        let body = Body(shop_id: MoneyEdge.wire(shopID), kind: kind.rawValue, id: MoneyEdge.wire(documentID))
        let data: Data
        do {
            data = try await Supa.client.functions.invoke(
                "pdf",
                options: FunctionInvokeOptions(body: body)
            ) { data, response in
                let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                guard type.hasPrefix("application/pdf") || data.starts(with: Array("%PDF".utf8)) else {
                    throw AppError.message("The server didn't return a PDF. Try again.")
                }
                return data
            }
        } catch let error as FunctionsError {
            throw await EdgeFunctions.failure(from: error)
        }
        return try write(data, fileName: kind.fileName(number: number))
    }

    /// Writes the PDF into its own folder under the temporary directory (so
    /// the file keeps its readable name and never overwrites another share).
    private static func write(_ data: Data, fileName: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
