import Foundation
import SwiftData

@MainActor final class KnowledgeRepository {
    let container: ModelContainer
    init(container: ModelContainer) { self.container = container }

    func createSubject(name: String) throws -> KnowledgeSubject {
        guard !name.trimmed.isEmpty else { throw ImportError.invalidSelection("Give this subject a name.") }
        let context = container.mainContext
        let existing = try context.fetch(FetchDescriptor<KnowledgeSubject>())
        if let match = existing.first(where: { $0.name.normalizedName == name.normalizedName }) { return match }
        let subject = KnowledgeSubject(name: name.trimmed, currentRevisionID: UUID())
        let autosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }
        context.insert(subject)
        do {
            // Reserve the initial head before inserting the subject; both are saved atomically.
            _ = try appendRevision(snapshot: versionSnapshot(subjectID: subject.id), id: subject.currentRevisionID, parentID: nil, origin: "baseline",
                title: "Created subject", operationID: UUID(), changes: [], explanations: [])
            try context.save()
            return subject
        } catch { context.rollback(); throw error }
    }

    func renameSubject(_ id: UUID, name: String) throws {
        let name = name.trimmed
        guard !name.isEmpty else { throw ImportError.invalidSelection("Give this subject a name.") }
        let context = container.mainContext
        let subjects = try context.fetch(FetchDescriptor<KnowledgeSubject>())
        guard let subject = subjects.first(where: { $0.id == id }) else {
            throw ImportError.invalidSelection("This subject is unavailable.")
        }
        guard !subjects.contains(where: { $0.id != id && $0.name.normalizedName == name.normalizedName }) else {
            throw ImportError.invalidSelection("A subject with this name already exists.")
        }
        try libraryMutation(subjectID: id, title: "Renamed subject") { subject.name = name }
    }

    @discardableResult func deleteSubject(_ id: UUID, sourceDirectory: URL? = nil) throws -> String? {
        let context = container.mainContext
        guard let subject = try context.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == id })).first else {
            throw ImportError.invalidSelection("This subject is unavailable.")
        }
        let allSources = try context.fetch(FetchDescriptor<KnowledgeSource>())
        let allJobs = try context.fetch(FetchDescriptor<KnowledgeImportJob>())
        let sources = allSources.filter { $0.subjectID == id }, jobs = allJobs.filter { $0.subjectID == id }
        let concepts = try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == id }))
        let facts = try context.fetch(FetchDescriptor<KnowledgeFact>(predicate: #Predicate { $0.subjectID == id }))
        let connections = try context.fetch(FetchDescriptor<KnowledgeConnection>(predicate: #Predicate { $0.subjectID == id }))
        let topics = try context.fetch(FetchDescriptor<KnowledgeTopic>(predicate: #Predicate { $0.subjectID == id }))
        let placements = try context.fetch(FetchDescriptor<KnowledgeConceptPlacement>(predicate: #Predicate { $0.subjectID == id }))
        let revisions = try context.fetch(FetchDescriptor<SubjectRevisionRecord>())
        let contributions = try context.fetch(FetchDescriptor<KnowledgeContribution>(predicate: #Predicate { $0.subjectID == id }))
        var retainedHashes: Set<String> = []
        for revision in revisions where revision.subjectID != id {
            retainedHashes.formUnion(try JSONDecoder().decode([String: String].self, from: revision.manifestData).values)
        }
        let versions = try context.fetch(FetchDescriptor<LibraryEntityVersion>())
        let otherSources = allSources.filter { $0.subjectID != id }, otherJobs = allJobs.filter { $0.subjectID != id }
        let retainedIDs = Set(otherSources.map(\.id) + otherJobs.map(\.sourceID))
        // Corrupt draft data must not prevent deletion, and another subject may still use a source copy.
        let prepared = sources.compactMap { try? $0.prepared() } + jobs.compactMap { try? $0.prepared() }
        let retainedFiles = Set(otherSources.compactMap { try? $0.prepared().storedFilename }
            + otherJobs.compactMap { try? $0.prepared().storedFilename })
        let filenames = Set(prepared.filter { !retainedIDs.contains($0.id) }.map(\.storedFilename)).subtracting(retainedFiles)
        let folder = filenames.isEmpty ? nil : try (sourceDirectory ?? SourcePreparation.directory())
        let autosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }
        for connection in connections { context.delete(connection) }
        for fact in facts { context.delete(fact) }
        for placement in placements { context.delete(placement) }
        for concept in concepts { context.delete(concept) }
        for topic in topics { context.delete(topic) }
        for job in jobs { context.delete(job) }
        for source in sources { context.delete(source) }
        for revision in revisions where revision.subjectID == id { context.delete(revision) }
        for contribution in contributions { context.delete(contribution) }
        for version in versions where !retainedHashes.contains(version.contentHash) { context.delete(version) }
        context.delete(subject)
        do {
            try context.save()
        } catch { context.rollback(); throw error }
        // Delete bytes only after the database commit, so a failed save retains all source material.
        var failedCopies = 0
        if let folder {
            for filename in filenames {
                do { try FileManager.default.removeItem(at: folder.appendingPathComponent(filename)) }
                catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
                catch { failedCopies += 1 }
            }
        }
        return failedCopies == 0 ? nil : "The subject was deleted, but some local source copies could not be removed."
    }

    func job(_ id: UUID, context: ModelContext? = nil) throws -> KnowledgeImportJob {
        let descriptor = FetchDescriptor<KnowledgeImportJob>(predicate: #Predicate { $0.id == id })
        guard let job = try (context ?? container.mainContext).fetch(descriptor).first else { throw ImportError.damagedCheckpoint }
        return job
    }

    func createJob(subjectID: UUID, source: PreparedSource, accountID: String?, model: String) throws -> UUID {
        let baseID = try currentRevisionID(subjectID: subjectID)
        let job = try KnowledgeImportJob(subjectID: subjectID, source: source, accountID: accountID, model: model,
            baseRevisionID: baseID)
        container.mainContext.insert(job)
        do { try container.mainContext.save(); return job.id }
        catch { container.mainContext.delete(job); throw error }
    }

    func checkpoint(_ value: ImportCheckpoint, jobID: UUID) throws {
        let job = try job(jobID)
        let data = try JSONEncoder().encode(value)
        job.checkpointData = data
        job.updatedAt = Date()
        try container.mainContext.save()
    }

    func update(jobID: UUID, status: ImportStatus, message: String? = nil) throws {
        let job = try job(jobID)
        guard job.status != .saved else { return }
        job.status = status; job.lastError = message; job.updatedAt = Date()
        try container.mainContext.save()
    }

    func keepDraft(_ draft: ImportDraft, jobID: UUID) throws {
        let job = try job(jobID)
        guard job.status != .saved else { return }
        guard draft.isComplete, draft.topicOrganization != nil else { throw ImportError.incompleteDraft }
        let data = try LibraryCoding.encode(draft)
        if job.draftData != data { job.draftEditVersion += 1 }
        job.draftData = data
        job.status = .review; job.lastError = nil; job.updatedAt = Date()
        try container.mainContext.save()
    }

    /// A source-copy cleanup failure is nonfatal once the draft deletion has been saved.
    @discardableResult func deleteDraft(jobID: UUID, sourceDirectory: URL? = nil) throws -> String? {
        let context = container.mainContext
        let job = try job(jobID)
        guard job.status != .saved else {
            throw ImportError.invalidSelection("This import has already been saved to your library.")
        }
        let sourceID = job.sourceID
        let savedSources = try context.fetchCount(FetchDescriptor<KnowledgeSource>(predicate: #Predicate { $0.id == sourceID }))
        let otherJobs = try context.fetchCount(FetchDescriptor<KnowledgeImportJob>(predicate: #Predicate { $0.sourceID == sourceID && $0.id != jobID }))
        var sourceURL: URL?
        // An unreadable draft can still be removed. Shared or saved source files are retained.
        if savedSources == 0, otherJobs == 0, let source = try? job.prepared() {
            let folder = try sourceDirectory ?? SourcePreparation.directory()
            sourceURL = folder.appendingPathComponent(source.storedFilename)
        }
        let autosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }
        context.delete(job)
        do {
            try context.save()
        } catch { context.rollback(); throw error }
        if let sourceURL {
            do { try FileManager.default.removeItem(at: sourceURL) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
            catch { return "The draft was deleted, but its local source copy could not be removed: \(error.localizedDescription)" }
        }
        return nil
    }


}

nonisolated enum ReviewSelection {
    static func concept(_ id: UUID, selected: Bool, draft: inout ImportDraft) {
        guard let index = draft.concepts.firstIndex(where: { $0.id == id }) else { return }
        draft.recordUserSelection(id, selected: selected)
        draft.concepts[index].selected = selected
        if !selected {
            let removedFacts = Set(draft.facts.filter { $0.conceptID == id }.map(\.id))
            for index in draft.facts.indices where removedFacts.contains(draft.facts[index].id) { draft.facts[index].selected = false }
            for index in draft.connections.indices where draft.connections[index].fromConceptID == id || draft.connections[index].toConceptID == id
                || !removedFacts.isDisjoint(with: draft.connections[index].supportingFactIDs) { draft.connections[index].selected = false }
        }
    }
    static func fact(_ id: UUID, selected: Bool, draft: inout ImportDraft) {
        guard let index = draft.facts.firstIndex(where: { $0.id == id }) else { return }
        draft.recordUserSelection(id, selected: selected)
        draft.facts[index].selected = selected
        if selected { concept(draft.facts[index].conceptID, selected: true, draft: &draft) }
        else {
            for index in draft.connections.indices where draft.connections[index].supportingFactIDs.contains(id) {
                draft.connections[index].selected = false
            }
        }
    }
    static func connection(_ id: UUID, selected: Bool, draft: inout ImportDraft) {
        guard let index = draft.connections.firstIndex(where: { $0.id == id }) else { return }
        draft.recordUserSelection(id, selected: selected)
        draft.connections[index].selected = selected
        if selected {
            let value = draft.connections[index]
            concept(value.fromConceptID, selected: true, draft: &draft)
            concept(value.toConceptID, selected: true, draft: &draft)
            for factID in value.supportingFactIDs { fact(factID, selected: true, draft: &draft) }
        }
    }
    static func includeSuggested(draft: inout ImportDraft) {
        let ids = draft.connections.filter { connection in
            connection.isInferred && connection.reviewReason == nil
            && !draft.existingFactReviews.contains { connection.supportingFactIDs.contains($0.factID) }
            && !draft.facts.contains { connection.supportingFactIDs.contains($0.id) && $0.reviewReason != nil }
            && !draft.concepts.contains { ($0.id == connection.fromConceptID || $0.id == connection.toConceptID) && $0.reviewReason != nil }
        }.map(\.id)
        for id in ids { connection(id, selected: true, draft: &draft) }
    }
}
