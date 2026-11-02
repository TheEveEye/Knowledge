import SwiftUI

struct RecallAnswerDetails: View {
    let question: RecallQuestion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Expected answer").font(.subheadline.weight(.semibold))
            RecallText(source: question.expectedAnswer)
            if question.criteria.count > 1 {
                Text("What your answer should cover").font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(question.criteria) { criterion in
                    Label { RecallText(source: criterion.point) } icon: { Image(systemName: "circle").foregroundStyle(.secondary) }
                }
            }
        }
    }
}
