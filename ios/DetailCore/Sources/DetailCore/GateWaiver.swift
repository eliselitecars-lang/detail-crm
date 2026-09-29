//
//  GateWaiver.swift
//  DetailCore
//
//  What a manager skipped when they moved a job past its completion gates
//  (P-11, `set_job_status` with force; the server keeps each move in
//  `job_gate_overrides` with the reason and a snapshot of what was still
//  missing). The job screen lists these so anyone working the job can see
//  that a completed job skipped its required photos or checklist items,
//  who did it, when and why. The sentences match the web job page and the
//  gate dialog.
//

import Foundation

public struct GateWaiver: Equatable, Sendable {

    public struct PhotoCount: Equatable, Sendable {
        public var required: Int
        public var have: Int

        public init(required: Int, have: Int) {
            self.required = required
            self.have = have
        }
    }

    /// Required checklist items that were still open (labels).
    public var openRequiredItems: [String]
    /// "After" photos the job's services ask for, when they were short.
    public var afterPhotos: PhotoCount?
    /// "Before" photos, when they were short.
    public var beforePhotos: PhotoCount?

    public init(openRequiredItems: [String] = [], afterPhotos: PhotoCount? = nil, beforePhotos: PhotoCount? = nil) {
        self.openRequiredItems = openRequiredItems
        self.afterPhotos = afterPhotos
        self.beforePhotos = beforePhotos
    }

    /// One sentence per requirement that was not met, checklist first,
    /// then the "after" and "before" photos. Parts that weren't short (or
    /// are malformed) are left out.
    public var sentences: [String] {
        var out: [String] = []
        let labels = openRequiredItems
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !labels.isEmpty {
            let noun = labels.count == 1 ? "item" : "items"
            out.append("Required checklist \(noun) not done: " + labels.joined(separator: ", "))
        }
        if let after = afterPhotos, after.have < after.required {
            out.append(Self.photoSentence(after, kind: "after"))
        }
        if let before = beforePhotos, before.have < before.required {
            out.append(Self.photoSentence(before, kind: "before"))
        }
        return out
    }

    private static func photoSentence(_ count: PhotoCount, kind: String) -> String {
        let noun = count.required == 1 ? "photo" : "photos"
        return "\(count.required) \u{201C}\(kind)\u{201D} \(noun) needed (\(max(0, count.have)) so far)"
    }

    /// "Moved to Completed without meeting its requirements".
    public static func headline(to status: JobStatus) -> String {
        "Moved to \(status.displayName) without meeting its requirements"
    }

    /// The reason as given, or a plain "No reason given."
    public static func reasonText(_ reason: String?) -> String {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "No reason given." : trimmed
    }
}
