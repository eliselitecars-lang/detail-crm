//
//  LoadState.swift
//  DetailCRM
//
//  Per-screen loading state. Every data screen owns one `LoadState` and
//  renders loading / error / loaded (with its own empty state) through
//  `LoadStateView`, so no screen can forget a state.
//

import SwiftUI

enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    /// Moves to `.loading` unless content is already on screen (pull to
    /// refresh keeps showing the old content until the new one arrives).
    mutating func beginLoading() {
        if value == nil { self = .loading }
    }

    /// Runs `operation` and returns `.loaded` or `.failed` with readable
    /// text. Cancellation (a newer `.task(id:)` run replaced this one)
    /// returns `.idle`. Typical use:
    ///
    ///     state.beginLoading()
    ///     let result = await LoadState<[Customer]>.result { try await CustomerService.list(shopID) }
    ///     state.apply(result)
    static func result(of operation: () async throws -> Value) async -> LoadState<Value> {
        do {
            return .loaded(try await operation())
        } catch is CancellationError {
            return .idle
        } catch let error as URLError where error.code == .cancelled {
            return .idle
        } catch {
            return .failed(ErrorText.message(for: error))
        }
    }

    /// Applies a load result. New content always replaces old; an error or
    /// cancellation never wipes content already on screen (screens show a
    /// toast for refresh failures instead).
    mutating func apply(_ result: LoadState<Value>) {
        switch result {
        case .loaded:
            self = result
        case .failed:
            if value == nil { self = result }
        case .idle, .loading:
            if value == nil { self = .idle }
        }
    }
}

extension LoadState: Equatable where Value: Equatable {}

/// Renders a `LoadState`: spinner while loading, error with Retry, or the
/// loaded content. Empty collections are the content's job (use
/// `EmptyStateView` inside `content`).
struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    let loadingLabel: String
    let retry: () async -> Void
    let content: (Value) -> Content

    init(
        _ state: LoadState<Value>,
        loadingLabel: String = "Loading…",
        retry: @escaping () async -> Void,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.state = state
        self.loadingLabel = loadingLabel
        self.retry = retry
        self.content = content
    }

    var body: some View {
        switch state {
        case .idle, .loading:
            LoadingStateView(label: loadingLabel)
        case .failed(let message):
            ErrorStateView(message: message, retry: retry)
        case .loaded(let value):
            content(value)
        }
    }
}
