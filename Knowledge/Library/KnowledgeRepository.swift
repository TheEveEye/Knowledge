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
        let subject = KnowledgeSubject(name: name.trimmed)
        context.insert(subject)
        do { try context.save(); return subject }
        catch { context.delete(subject); throw error }
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
        let previousName = subject.name
        subject.name = name
        do { try context.save() }
        catch { subject.name = previousName; throw error }
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

    func snapshot(subjectID: UUID, context: ModelContext? = nil) throws -> SubjectSnapshot {
        let context = context ?? container.mainContext
        guard let subject = try context.fetch(FetchDescriptor<KnowledgeSubject>(predicate: #Predicate { $0.id == subjectID })).first else {
            throw ImportError.invalidSelection("This subject is unavailable.")
        }
        let concepts = try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == subjectID }))
        let facts = try context.fetch(FetchDescriptor<KnowledgeFact>(predicate: #Predicate { $0.subjectID == subjectID }))
        return try SubjectSnapshot(subjectID: subjectID, name: subject.name,
            concepts: concepts.map { .init(id: $0.id, name: $0.name, aliases: $0.aliases, explanation: $0.explanation) },
            facts: facts.map {
                guard let kind = FactKind(rawValue: $0.kindRaw) else { throw ImportError.damagedCheckpoint }
                return .init(id: $0.id, conceptID: $0.conceptID, statement: $0.statement, kind: kind,
                             qualifications: $0.qualifications, evidence: try $0.evidence())
            })
    }

    func createJob(subjectID: UUID, source: PreparedSource, accountID: String?, model: String) throws -> UUID {
        _ = try snapshot(subjectID: subjectID)
        let job = try KnowledgeImportJob(subjectID: subjectID, source: source, accountID: accountID, model: model)
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
        guard draft.isComplete else { throw ImportError.incompleteDraft }
        job.draftData = try JSONEncoder().encode(draft)
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

    /// Repository mutations are synchronous on the main actor; autosaving cannot split this commit.
    @discardableResult func commit(_ draft: ImportDraft, jobID: UUID) throws -> UUID {
        let context = container.mainContext
        let autosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = autosave }
        let job = try job(jobID, context: context)
        if job.status == .saved { return job.sourceID }
        guard job.status == .review, draft.sourceID == job.sourceID else { throw ImportError.incompleteDraft }
        let source = try job.prepared()
        let subjectID = job.subjectID
        let snapshot = try snapshot(subjectID: job.subjectID, context: context)
        try ImportValidator.validateDraft(draft, source: source, context: snapshot)

        let selectedConcepts = draft.concepts.filter(\.selected)
        let selectedFacts = draft.facts.filter(\.selected)
        let selectedConnections = draft.connections.filter(\.selected)
        let existingConcepts = try context.fetch(FetchDescriptor<KnowledgeConcept>(predicate: #Predicate { $0.subjectID == subjectID }))
        var conceptMap = Dictionary(uniqueKeysWithValues: snapshot.concepts.map { ($0.id, $0.id) })
        for concept in selectedConcepts {
            conceptMap[concept.id] = concept.acceptMerge ? (concept.mergeTargetID ?? concept.id) : concept.id
        }
        let factIDs = Set(selectedFacts.map(\.id) + snapshot.facts.map(\.id))
        for fact in selectedFacts where conceptMap[fact.conceptID] == nil {
            throw ImportError.invalidSelection("Include the concept for every selected fact, or exclude its facts.")
        }
        for connection in selectedConnections {
            guard let from = conceptMap[connection.fromConceptID], let to = conceptMap[connection.toConceptID], from != to,
                  connection.supportingFactIDs.allSatisfy({ factIDs.contains($0) }) else {
                throw ImportError.invalidSelection("Include both concepts and all supporting facts for each selected connection, or exclude the connection.")
            }
        }
        // Verify references to prior uploads against those original, immutable passages as well.
        var sources = [source.id: source]
        for saved in try context.fetch(FetchDescriptor<KnowledgeSource>(predicate: #Predicate { $0.subjectID == subjectID })) {
            sources[saved.id] = try saved.prepared()
        }
        for evidence in selectedConcepts.flatMap(\.evidence) + selectedFacts.flatMap(\.evidence) + selectedConnections.flatMap(\.evidence) {
            guard let text = sources[evidence.sourceID]?.segments.first(where: { $0.id == evidence.segmentID })?.text else {
                throw ImportValidator.invalid("A supporting source is unavailable.")
            }
            try ImportValidator.checkQuote(evidence.quote, in: text)
        }
        do {
            context.insert(try KnowledgeSource(subjectID: job.subjectID, source: source,
                reviewNotes: draft.existingFactReviews.map { review in
                    let statement = snapshot.facts.first { $0.id == review.factID }?.statement ?? "Existing fact"
                    return statement + "\n" + review.reason
                } + (draft.excludedConnections ?? []).map { "Excluded connection: \($0.title). \($0.originalExplanation) \($0.reason)" }
                + (draft.processingNotes ?? [])))
            for concept in selectedConcepts {
                if concept.acceptMerge, let targetID = concept.mergeTargetID {
                    guard let target = existingConcepts.first(where: { $0.id == targetID }) else { throw ImportError.damagedCheckpoint }
                    target.aliases = Reconciliation.uniqueStrings(target.aliases + [concept.name] + concept.aliases)
                        .filter { $0.normalizedName != target.name.normalizedName }
                    target.sourceIDs = Array(Set(target.sourceIDs + [source.id]))
                    target.evidenceData = try JSONEncoder().encode(Reconciliation.uniqueEvidence(try target.evidence() + concept.evidence))
                    let wording = SourceConceptWording(sourceID: source.id, original: concept.original,
                        edited: concept.isUserEdited ? .init(name: concept.name, aliases: concept.aliases, explanation: concept.explanation) : nil)
                    target.sourceWordingsData = try JSONEncoder().encode(try target.sourceWordings() + [wording]
                        + concept.otherSourceWordings.map { .init(sourceID: source.id, original: $0, edited: nil) })
                    target.isUserEdited = target.isUserEdited || concept.isUserEdited
                    let reviewNotes = Reconciliation.uniqueStrings([target.reviewNote, concept.reviewReason].compactMap { $0 })
                    target.reviewNote = reviewNotes.isEmpty ? nil : reviewNotes.joined(separator: "\n")
                } else { context.insert(try KnowledgeConcept(subjectID: job.subjectID, sourceID: source.id, draft: concept)) }
            }
            for fact in selectedFacts {
                context.insert(try KnowledgeFact(subjectID: job.subjectID, sourceID: source.id, conceptID: conceptMap[fact.conceptID]!, draft: fact))
            }
            for connection in selectedConnections {
                context.insert(try KnowledgeConnection(subjectID: job.subjectID, sourceID: source.id,
                    from: conceptMap[connection.fromConceptID]!, to: conceptMap[connection.toConceptID]!, draft: connection))
            }
            job.draftData = try JSONEncoder().encode(draft)
            job.status = .saved; job.savedAt = Date(); job.updatedAt = Date(); job.lastError = nil
            try context.save()
        } catch { context.rollback(); throw error }
        return source.id
    }
}

nonisolated enum ReviewSelection {
    static func concept(_ id: UUID, selected: Bool, draft: inout ImportDraft) {
        guard let index = draft.concepts.firstIndex(where: { $0.id == id }) else { return }
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
