import Foundation

@MainActor enum CloudImportProgress {
    static func make(_ job: CloudJSON) -> ExtractionProgress {
        let value = job.value("progress"), stage = value.text("stage"), status = job.text("status")
        let extracting = stage.isEmpty || stage == "extracting"
        let batches = value.value("batches").array
        let total = value.value("extractionTotal").int > 0 ? value.value("extractionTotal").int : extracting ? value.value("total").int : batches.count
        let completed = value.value("extractionCompleted") != .null ? value.value("extractionCompleted").int : extracting ? value.value("completed").int : batches.filter { $0.text("state") == "checked" }.count
        let activity: ImportActivity
        switch value.text("activity") {
        case "receiving": activity = .receiving
        case "validating": activity = .validating
        case "saved": activity = .saved
        default: activity = status == "queued" ? .waiting : .processing
        }
        var result = ExtractionProgress(stage: extracting ? .extracting : .connecting, completed: completed, total: total, activity: activity)
        result.startedAt = CloudDates.date(job.text("createdAt")) ?? CloudDates.date(job.text("updatedAt")) ?? .now
        result.receivedCharacters = value.value("receivedCharacters").int
        result.batchIndex = value.value("batchIndex") == .null ? nil : value.value("batchIndex").int
        result.isRepairing = extracting && (value.value("attempt").int > 1 || batches.contains { $0.text("state") == "active" && $0.value("attempt").int > 1 })
        result.batches = batches.map { batch in
            let checked = batch.text("state") == "checked", active = batch.text("state") == "active" && extracting
            let batchActivity: ImportActivity = switch batch.text("activity") {
            case "receiving": .receiving
            case "validating": .validating
            case "processing": .processing
            default: activity
            }
            let state: ImportBatchActivity.State
            let label: String
            if checked { state = .checked; label = "Checked and saved" }
            else if batch.text("state") == "failed" { state = .failed; label = "Needs attention" }
            else if active, ["failed", "blocked"].contains(status) { state = .failed; label = "Needs attention" }
            else if status == "paused" { state = .paused; label = "Paused" }
            else if active, status == "running" { state = .active; label = batchActivity.label }
            else { state = .queued; label = "Queued" }
            let counts = batch.value("counts")
            return ImportBatchActivity(index: batch.value("index").int, state: state, label: label, location: batch.value("location").string,
                error: state == .failed ? batch.value("error").string ?? job.value("error").string : nil,
                counts: .init(concepts: counts.value("concepts").int, facts: counts.value("facts").int, connections: counts.value("connections").int), isChecking: batchActivity == .validating)
        }
        result.sourceSections = value.value("sourceSections").array.map { section in
            .init(id: section.text("id"), title: section.text("title"), segmentIDs: Set(section.value("segmentIDs").array.compactMap(\.string)), batchIndices: Set(section.value("batchIndices").array.map(\.int)))
        }
        for batch in batches {
            let index = batch.value("index").int
            var concepts = batch.value("concepts").array
            if batch.value("concepts") == .null, index == result.batchIndex, extracting, batch.text("state") != "checked" { concepts = value.value("previewConcepts").array }
            let scope = ImportPreviewScope(batchIndex: index, attempt: LibraryCoding.stableID(job.text("id") + "/batch/\(index)"), pass: .extraction)
            for (ordinal, concept) in concepts.enumerated() {
                let reason = concept.value("reviewReason").string
                result.feed.append(.init(id: .init(scope: scope, kind: .concept, ordinal: ordinal), name: concept.text("name"),
                    validation: concept.value("checked").flag ? reason == nil ? .checked : .needsReview : .awaiting,
                    reviewReason: reason, sourceSegmentIDs: concept.value("segmentIDs").array.compactMap(\.string)))
            }
        }
        if stage == "reconciling" { result.reconciliationCompleted = value.value("completed").int; result.reconciliationTotal = value.value("total").int }
        if stage == "organizing" { result.organizationLabel = "Organizing concepts into topics"; result.organizationCompleted = value.value("completed").int; result.organizationTotal = value.value("total").int }
        result.isReviewingSource = stage == "reviewing"; result.sourceReviewCompleted = value.value("completed").int; result.sourceReviewTotal = value.value("total").int
        result.isResolving = stage == "naming"; result.resolutionCompleted = value.value("completed").int; result.resolutionTotal = value.value("total").int
        return result
    }
}
