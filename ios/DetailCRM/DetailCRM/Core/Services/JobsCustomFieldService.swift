//
//  JobsCustomFieldService.swift
//  DetailCRM
//
//  Custom field definitions (P-9). Every member may read them; values are
//  saved on the record itself (`jobs.custom_data` by JobService,
//  `customers.custom_data` by the customer screens) and validated by the
//  server, which answers 22023 with the field's label ("Gate code must be
//  …").
//

import Foundation
import Supabase

enum JobsCustomFieldService {

    /// Live (not archived) fields of one entity, in the shop's order.
    static func activeFields(shopID: UUID, entity: JobsCustomField.Entity) async throws -> [JobsCustomField] {
        try await Supa.client
            .from("custom_fields")
            .select(JobsCustomField.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("entity", value: entity.rawValue)
            .is("archived_at", value: nil)
            .order("sort", ascending: true)
            .order("label", ascending: true)
            .execute()
            .value
    }

    /// Every field of an entity, archived ones included (to label values a
    /// record still holds for a field that was archived later).
    static func allFields(shopID: UUID, entity: JobsCustomField.Entity) async throws -> [JobsCustomField] {
        try await Supa.client
            .from("custom_fields")
            .select(JobsCustomField.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("entity", value: entity.rawValue)
            .order("sort", ascending: true)
            .order("label", ascending: true)
            .execute()
            .value
    }

    /// Builds the `custom_data` object to save: the edited answers of live
    /// fields (empty ones dropped), plus every stored key the editor did not
    /// show (archived fields keep their value; the server refuses new values
    /// for them).
    static func mergedData(
        original: [String: AnyJSON]?,
        edited: [String: JobsCustomValue],
        editableKeys: Set<String>
    ) -> [String: AnyJSON] {
        var result: [String: AnyJSON] = [:]
        for (key, value) in original ?? [:] where !editableKeys.contains(key) {
            result[key] = value
        }
        for (key, value) in edited where editableKeys.contains(key) && !value.isEmpty {
            result[key] = value.json
        }
        return result
    }
}
