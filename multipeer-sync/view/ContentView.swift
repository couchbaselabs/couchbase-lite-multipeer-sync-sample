//
//  ContentView.swift
//  multipeer-sync
//
//  Created by Pasin Suriyentrakorn on 8/3/24.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ContentViewModel
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        VStack {
            VStack {
                Spacer()
                Button("") { setNextColor() }
                    .buttonStyle(CircularButton(color: color(), size: 250))
                Spacer()
            }
            Text("Peers: \(model.peerIDs.count)")
                .foregroundColor(Color.gray)
                .padding(.horizontal, 20)
        }
        .task {
            try! await model.initialize()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            Task {
                switch newPhase {
                case .active:
                    await model.startSync()
                case .background:
                    await model.stopSync()
                default:
                    break
                }
            }
        }
    }
    
    private func color() -> Color {
        return model.color?.displayColor ?? Color.gray
    }
    
    private func setNextColor() {
        Task {
            let color = model.color?.nextColor() ?? AppColor.allCases.first!
            try await model.setColor(color)
        }
    }
}

struct CircularButton: ButtonStyle {
    let color: Color?
    let size: CGFloat
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
        Circle()
            .fill(color ?? Color.gray)
            .frame(width: size, height: size)
            .brightness(0)
    }
}

#Preview {
    let model = ContentViewModel(DatabaseService())
    return ContentView().environmentObject(model)
}
