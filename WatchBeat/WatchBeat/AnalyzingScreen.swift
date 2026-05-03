import SwiftUI

struct AnalyzingScreen: View {
    var body: some View {
        VStack {
            Text("WatchBeat")
                .font(.largeTitle.bold())
                .padding(.top, 12)
            Spacer()
            ProgressView("Analyzing...")
                .font(.title3)
            Spacer()
        }
    }
}
