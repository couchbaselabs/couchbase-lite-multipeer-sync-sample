//
//  ContentViewModel.swift
//  multipeer-sync
//
//  Created by Pasin Suriyentrakorn on 8/3/24.
//

import SwiftUI
import Combine
import MultipeerConnectivity

@MainActor
class ContentViewModel : ObservableObject {
    @Published var color: AppColor? = nil
    @Published var peerIDs: [MCPeerID] = []
    
    let service : DatabaseService
    private var cancellables: Set<AnyCancellable> = []
    
    init(_ service: DatabaseService) {
        self.service = service
    }
    
    func initialize() async throws {
        // Get initial color
        color = try await service.getColor()
        
        // Set up color change observer
        await service.setColorChangeObserver { color in
            self.color = color
        }
        
        // Subscribe to connected peerIDs publisher
        await service.peerIDsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peerIDs in
                self?.peerIDs = peerIDs
            }
            .store(in: &cancellables)
    }
    
    func setColor(_ color: AppColor) async throws {
        try await service.setColor(color)
    }
    
    func startSync() async {
        await service.startSync()
    }
    
    func stopSync() async {
        await service.stopSync()
    }
}
