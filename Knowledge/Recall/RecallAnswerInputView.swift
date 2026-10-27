import SwiftUI

struct RecallAnswerInputView: View {
    let input: RecallInput
    let response: RecallResponse?
    let seed: String
    let update: (RecallResponse) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var numberText = ""

    private func ordered(_ options: [RecallOption]) -> [RecallOption] {
        func rank(_ id: String) -> UInt64 {
            (seed + id).utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        return options.sorted { rank($0.id) < rank($1.id) }
    }
    private var order: [String] { response?.order ?? ordered(input.options).map(\.id) }
    private func move(from offsets: IndexSet, to destination: Int) {
        var result = order
        result.move(fromOffsets: offsets, toOffset: destination)
        update(.init(order: result))
    }
    var body: some View {
        answerControls
            .onChange(of: response?.order, initial: true) { _, value in
                // The displayed order is an answer even before the learner moves an item.
                if input.kind == .ordering, value == nil, isEnabled {
                    update(.init(order: order))
                }
            }
    }

    @ViewBuilder private var answerControls: some View {
        switch input.kind {
        case .text: EmptyView()
        case .choice:
            ForEach(ordered(input.options)) { option in
                let isSelected = response?.optionID == option.id
                Button { update(.init(optionID: option.id)) } label: {
                    Label {
                        Text(option.text).frame(maxWidth: .infinity, alignment: .leading)
                    } icon: {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                    }.padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        case .number:
            HStack {
                TextField("Enter a number", text: $numberText)
                    .keyboardType(.numbersAndPunctuation)
                    .accessibilityLabel("Answer in \(input.unit ?? "units")")
                    .onChange(of: numberText) { _, text in
                        let separator = Locale.current.decimalSeparator ?? "."
                        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: separator, with: ".")
                        update(.init(number: Double(normalized)))
                    }
                    .onAppear { if let value = response?.number { numberText = String(value) } }
                Text(input.unit ?? "").foregroundStyle(.secondary)
            }
        case .slider:
            if let minimum = input.minimum, let maximum = input.maximum, let step = input.step {
                VStack(alignment: .leading, spacing: 12) {
                    Text(response?.number.map { "\($0.formatted()) \(input.unit ?? "")" } ?? "Choose an estimate")
                    Slider(value: Binding(get: { response?.number ?? minimum },
                        set: { update(.init(number: $0)) }), in: minimum...maximum, step: step)
                        .accessibilityLabel("Estimate in \(input.unit ?? "units")")
                        .accessibilityValue(response?.number.map { $0.formatted() } ?? "Not answered")
                    HStack { Text(minimum.formatted()); Spacer(); Text(maximum.formatted()) }.font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
        case .ordering:
            ForEach(Array(order.enumerated()), id: \.element) { index, id in
                HStack {
                    Text("\(index + 1).").foregroundStyle(.secondary)
                    Text(input.options.first { $0.id == id }?.text ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .moveDisabled(!isEnabled)
            }
            .onMove(perform: move)
        case .matching:
            let leftIDs = Set(input.matches.map(\.leftID)), rightIDs = Set(input.matches.map(\.rightID))
            ForEach(ordered(input.options.filter { leftIDs.contains($0.id) })) { left in
                VStack(alignment: .leading) {
                    Text(left.text)
                    Picker("Match", selection: Binding(get: { response?.pairs?.first { $0.leftID == left.id }?.rightID ?? "" }, set: { selected in
                        var pairs = response?.pairs ?? []
                        pairs.removeAll { $0.leftID == left.id }
                        if !selected.isEmpty { pairs.append(.init(leftID: left.id, rightID: selected)) }
                        update(.init(pairs: pairs))
                    })) {
                        Text("Choose…").tag("")
                        ForEach(ordered(input.options.filter { rightIDs.contains($0.id) })) { Text($0.text).tag($0.id) }
                    }.accessibilityLabel("Match for \(left.text)")
                }.padding(.vertical, 4)
            }
            Text("Use each answer once.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
