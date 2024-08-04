//
//  DatabaseService.swift
//  multipeer-sync
//
//  Created by Pasin Suriyentrakorn on 8/3/24.
//

import SwiftUI
import Combine
import MultipeerConnectivity
import CouchbaseLiteSwift

enum AppColor : Int, CaseIterable {
    case blue = 0
    case green = 1
    case pink = 2
    case purple = 3
    case yellow = 4
    
    var displayColor: Color {
        switch self {
        case .blue:
            return Color.blue
        case .green:
            return Color.green
        case .pink:
            return Color.pink
        case .purple:
            return Color.purple
        case .yellow:
            return Color.yellow
        }
    }
    
    func nextColor() -> AppColor {
        let all = AppColor.allCases
        let next = self.rawValue + 1
        return all[next < all.count ? next : 0]
    }
}

struct Device {
    static func name() -> String {
        return UIDevice.current.name
    }
}

actor DatabaseService {
    let kDatabaseName = "db"
    let kColorDocID = "color"
    let kColorKeyName = "color"
    let kServiceType = "color-sync"
    
    let db: Database
    let collection: Collection
    let multipeerSync: MultipeerSync
    
    var listener: ListenerToken?
    var colorChangeObserver: ((AppColor?)->Void)?
    
    var peerIDsPublisher: AnyPublisher<[MCPeerID], Never> {
        return multipeerSync.peerIDsPublisher
    }
    
    init() {
        db = try! Database(name: kDatabaseName)
        collection = try! db.defaultCollection()
        
        let peerID = MCPeerID(displayName: Device.name())
        multipeerSync = MultipeerSync(serviceType: kServiceType, peerID: peerID, collections: [collection])
    }
    
    func setColor(_ color: AppColor) throws {
        let doc = try collection.document(id: kColorDocID)?.toMutable() ?? MutableDocument(id: kColorDocID)
        doc.setInt(color.rawValue, forKey: kColorKeyName)
        try collection.save(document: doc)
    }
    
    func getColor() throws -> AppColor? {
        guard let doc = try collection.document(id: kColorDocID) else { return nil }
        return AppColor(rawValue: doc.int(forKey: kColorKeyName))
    }
    
    func setColorChangeObserver(_ observer: ((AppColor?)->Void)?) {
        colorChangeObserver = observer
        if observer != nil {
            if listener == nil {
                listener = collection.addChangeListener(listener: { change in
                    if change.documentIDs.contains(self.kColorDocID) {
                        self.colorChangeObserver?(try? self.getColor())
                    }
                })
            }
        } else {
            if let listener = self.listener {
                listener.remove()
            }
        }
    }
    
    func startSync() {
        multipeerSync.start()
    }
    
    func stopSync() {
        multipeerSync.stop()
    }
}

extension String: Error, LocalizedError {
    public var errorDescription: String? { return self }
}
