//
//  MultipeerManager.swift
//  multipeer-sync
//
//  Created by Pasin Suriyentrakorn on 8/3/24.
//

import Foundation
import CouchbaseLiteSwift
import MultipeerConnectivity
import Combine
import os

/// MultipeerSync is a class that manages peer-to-peer synchronization using the Multipeer Connectivity framework.
/// It facilitates peer discovery, advertising, and connection management within a peer network.
///
/// Peer Discovery
/// - Peer Discovery & Advertising : Advertises the local peer and browses for other peers offering the same service type.
/// - Connection : Establishes and manages connections between peers, where each peer connects to all other peers it discovers.
///
/// Peer Role
/// - One-Way Connections: Between two peers, one peer acts as a listener (passive peer) while the other acts as a replicator (active peer).
/// - Role Determination: The peer role is determined by comparing UUIDs. The peer with the smaller UUID becomes the active (replicator) peer,
///                  while the peer with the larger UUID becomes the passive (listener) peer.
///
/// Replicator Configuration
/// - Active Peers: For active peers, the replicator is configured as a continuous push-pull replicator to handle ongoing synchronization of data.
///
class MultipeerSync : NSObject {
    private let serviceType: String
    private let myPeerID: MCPeerID
    private let myPeerUUID: String
    private let connectionManager: ConnectionManager
    
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser: MCNearbyServiceBrowser
    
    static let logEnabled = true
    static let logger: os.Logger = {
        if logEnabled {
            return Logger(subsystem: Bundle.main.bundleIdentifier!, category: "MultipeerSync")
        } else {
            return Logger(OSLog.disabled)
        }
    }()
    
    init(serviceType: String, peerID: MCPeerID, collections: [Collection]) {
        self.serviceType = serviceType
        self.myPeerID = peerID
        self.myPeerUUID = UUID().uuidString // Generate the uuid for the peer
        self.connectionManager = ConnectionManager(collections: collections)

        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["uuid" : myPeerUUID], serviceType: serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        
        super.init()
        
        advertiser.delegate = self
        browser.delegate = self
    }
    
    func start() {
        MultipeerSync.logger.info("Start Multipeer Sync ...")
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }
    
    func stop() {
        MultipeerSync.logger.info("Stop Multipeer Sync ...")
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        connectionManager.stopAllConnections()
    }
    
    func peers() -> [MCPeerID] {
        return connectionManager.peers()
    }
    
    var peerIDsPublisher: AnyPublisher<[MCPeerID], Never> {
        return connectionManager.peerIDsPublisher
    }
}

/// MCSessionDelegate
extension MultipeerSync : MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .connected {
            MultipeerSync.logger.info("Peer Connected : \(peerID.displayName)")
            connectionManager.startConnection(forPeer: peerID)
        } else if state == .notConnected {
            MultipeerSync.logger.info("Peer Disconnected : \(peerID.displayName)")
            connectionManager.stopConnection(forPeer: peerID)
        }
    }
    
    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        connectionManager.receiveData(data, forPeer: peerID)
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { }
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) { }
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { }
}

/// MCNearbyServiceAdvertiserDelegate
extension MultipeerSync : MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        if (connectionManager.containsPeer(peerID)) {
            MultipeerSync.logger.debug("Reject Invitation From Peer : \(peerID.displayName) as Already Connected")
            invitationHandler(false, nil)
            return
        }
        
        MultipeerSync.logger.info("Accept Invitation From Peer : \(peerID.displayName)")
        let session = MCSession(peer: self.myPeerID)
        session.delegate = self
        connectionManager.registerPeer(peerID, peerUUID: nil, session: session, listenerPeer: false)
        invitationHandler(true, session)
    }
}

/// MCNearbyServiceBrowserDelegate
extension MultipeerSync : MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String : String]?) {
        guard let info = info, let uuid = info["uuid"] else { return }
        
        // A simple logic for creating one-way connection between two peers:
        // Only invite when my uuid is less than the advertiser's uuid.
        if myPeerUUID < uuid {
            if (connectionManager.containsPeer(peerID)) {
                MultipeerSync.logger.debug("Ignore Found Peer : \(peerID.displayName) as Already Connected")
                return
            }
            
            MultipeerSync.logger.info("Found and Invite Peer : \(peerID.displayName)")
            let session = MCSession(peer: self.myPeerID)
            session.delegate = self
            connectionManager.registerPeer(peerID, peerUUID: uuid, session: session, listenerPeer: true)
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Note: This may not be necessary as session will be disconnected?
        connectionManager.stopConnection(forPeer: peerID)
    }
}

/// MessageEndpointConnection implementation that uses MultipeerConnectivity Framework.
fileprivate class MultipeerConnection : MessageEndpointConnection {
    enum ConnectError: Error {
        case invalidHandshake
        case unknown
    }
    
    typealias AcceptConnection = (MultipeerConnection) -> Void
    
    private let lock = NSLock()
    private var replicatorConnection: ReplicatorConnection?
    private var connected = false
    private var openCompletion: ((Bool, MessagingError?) -> Void)?
    
    let session: MCSession
    let peerID: MCPeerID
    let peerUUID: String?
    let active: Bool
    let acceptConnection: AcceptConnection?
    
    static func active(peerID: MCPeerID, session: MCSession, peerUUID: String) -> MultipeerConnection {
        return MultipeerConnection(peerID: peerID, session: session, active: true, peerUUID: peerUUID)
    }
    
    static func passive(peerID: MCPeerID, session: MCSession, acceptConnection: @escaping AcceptConnection) -> MultipeerConnection {
        return MultipeerConnection(peerID: peerID, session: session, active: false, peerUUID: nil, acceptConnection: acceptConnection)
    }
    
    private init(peerID: MCPeerID, session: MCSession, active: Bool, peerUUID: String? = nil, acceptConnection: AcceptConnection? = nil) {
        self.peerID = peerID
        self.session = session
        self.peerUUID = peerUUID
        self.active = active
        self.acceptConnection = acceptConnection
    }
    
    func isConnected() -> Bool {
        lock.lock()
        defer {lock.unlock()}
        
        return connected
    }
    
    func open(connection: any ReplicatorConnection, completion: @escaping (Bool, MessagingError?) -> Void) {
        lock.lock()
        defer {lock.unlock()}
        
        replicatorConnection = connection
        openCompletion = completion
        
        // Perform CONNECT handshake to ensure that the listener's connection is ready before
        // the replicator starts to replicate.
        // Steps:
        // 1. Replicator opens a connection to the listener and sends the CONNECT message.
        // 2. Listener receives CONNECT message and accepts the replicator's connection.
        // 3. Listener replies with the OK message.
        // 4. Replicator completes openning the connection and starts the replication.
        do {
            if active {
                MultipeerSync.logger.debug("Send CONNECT to Peer : \(self.peerID.displayName)")
                try send(data: "CONNECT".data(using: .utf8)!)
            } else {
                MultipeerSync.logger.debug("Send OK to Peer : \(self.peerID.displayName)")
                try send(data: "OK".data(using: .utf8)!)
                openCompleted(success: true)
            }
        } catch {
            openCompleted(success: false, error: error)
        }
    }
    
    private func openCompleted(success: (Bool), error: Error? = nil) {
        guard let completion = openCompletion else { return }
        
        if (success) {
            MultipeerSync.logger.debug("Successful Open Connection to Peer : \(self.peerID.displayName)")
            connected = true
            completion(true, nil)
        } else {
            let err = error ?? ConnectError.unknown
            MultipeerSync.logger.warning("Failed to Open Connection to Peer : \(self.peerID.displayName), Error : \(err)")
            completion(false, MessagingError(error: err, isRecoverable: false))
            session.disconnect()
        }
        openCompletion = nil
    }
    
    func close(error: (any Error)?, completion: @escaping () -> Void) {
        lock.lock()
        defer {lock.unlock()}
        
        MultipeerSync.logger.debug("Close Connection to Peer : \(self.peerID.displayName)")
        session.disconnect()
        replicatorConnection = nil
        completion()
    }
    
    func send(message: Message, completion: @escaping (Bool, MessagingError?) -> Void) {
        lock.lock()
        defer {lock.unlock()}
        
        do {
            try send(data: message.toData())
            completion(true, nil)
        } catch {
            MultipeerSync.logger.error("Error Sending Message to Peer : \(self.peerID.displayName), Error: \(error)")
            completion(false, MessagingError(error: error, isRecoverable: false))
        }
    }
    
    func send(data: Data) throws {
        try session.send(data, toPeers: [self.peerID], with: .reliable)
    }
    
    func receive(data: Data) {
        lock.lock()
        defer {lock.unlock()}
        
        if !connected {
            handleHandshake(withData: data)
        } else {
            replicatorConnection?.receive(message: Message.fromData(data))
        }
    }
    
    private func handleHandshake(withData data: Data) {
        let message = String(data: data, encoding: .utf8)
        if (active) {
            assert(message == "OK")
            MultipeerSync.logger.debug("Receive OK from Peer : \(self.peerID.displayName)")
            openCompleted(success: true)
        } else {
            assert(message == "CONNECT")
            assert(acceptConnection != nil)
            MultipeerSync.logger.debug("Receive CONNECT from Peer : \(self.peerID.displayName)")
            acceptConnection!(self)
        }
    }
    
    func disconnect() {
        lock.lock()
        defer {lock.unlock()}
        
        session.disconnect()
    }
}

///ConnectionManager is a class for managning the connected peers and their multipeer connections.
fileprivate class ConnectionManager {
    private let lock = NSLock()
    
    private var connections: [MCPeerID: MultipeerConnection] = [:]
    
    private var replicators: [MCPeerID: Replicator] = [:]
    
    private let collections: [Collection]
    
    private let listener: MessageEndpointListener
    
    private let peerIDsSubject = PassthroughSubject<[MCPeerID], Never>()
    
    var peerIDsPublisher: AnyPublisher<[MCPeerID], Never> {
        peerIDsSubject.eraseToAnyPublisher()
    }
    
    init(collections: [Collection]) {
        self.collections = collections
        let config = MessageEndpointListenerConfiguration(collections: collections, protocolType: .messageStream)
        self.listener = MessageEndpointListener(config: config)
    }
    
    func registerPeer(_ peerID: MCPeerID, peerUUID: String?, session: MCSession, listenerPeer: Bool) {
        lock.lock()
        defer {lock.unlock()}
        
        var connection: MultipeerConnection
        if (listenerPeer) {
            // Replicator's connection (peer is a listener)
            MultipeerSync.logger.debug("Register Connection to Listener Peer : \(peerID.displayName), PeerUUID: \(peerUUID!)")
            connection = MultipeerConnection.active(peerID: peerID, session: session, peerUUID: peerUUID!)
        } else {
            // Listener's connection
            MultipeerSync.logger.debug("Register Connection to Replicator Peer : \(peerID.displayName)")
            connection = MultipeerConnection.passive(peerID: peerID, session: session, acceptConnection: { connection in
                MultipeerSync.logger.info("Listener Peer Accepts Connection for Replicator Peer : \(peerID.displayName)")
                self.listener.accept(connection: connection)
            })
        }
        connections[connection.peerID] = connection
        peerIDsSubject.send(Array(connections.keys))
    }
    
    func containsPeer(_ peerID: MCPeerID) -> Bool {
        lock.lock()
        defer {lock.unlock()}
        
        return connections[peerID] != nil
    }
    
    func peers() -> [MCPeerID] {
        lock.lock()
        defer {lock.unlock()}
        
        return Array(connections.keys)
    }
    
    func startConnection(forPeer peerID: MCPeerID) {
        lock.lock()
        defer {lock.unlock()}
        
        guard let connection = connections[peerID] else { return }
        
        if (connection.active) {
            startReplicator(forConnection: connection)
        }
    }
    
    func stopConnection(forPeer peerID: MCPeerID) {
        lock.lock()
        defer {lock.unlock()}
        
        guard let connection = connections[peerID] else { return }
        
        MultipeerSync.logger.info("Stop Connection to Peer : \(connection.peerID.displayName)")
        stopConnection(connection)
        peerIDsSubject.send(Array(connections.keys))
    }
    
    func stopAllConnections() {
        lock.lock()
        defer {lock.unlock()}
        
        MultipeerSync.logger.info("Stop All Connections ...")
        let conns = connections.values
        for connection in conns {
            stopConnection(connection)
        }
        peerIDsSubject.send(Array(connections.keys))
    }
    
    func receiveData(_ data: Data, forPeer peerID: MCPeerID) {
        lock.lock()
        defer {lock.unlock()}
        
        guard let connection = connections[peerID] else { return }
        connection.receive(data: data)
    }
    
    private func stopConnection(_ connection: MultipeerConnection) {
        if connection.isConnected() {
            if connection.active {
                if let r = replicators[connection.peerID] {
                    MultipeerSync.logger.debug("Stop Replicator to Listener Peer: \(connection.peerID.displayName)")
                    r.stop()
                    replicators.removeValue(forKey: connection.peerID)
                }
            } else {
                MultipeerSync.logger.debug("Close Listener Connection for Replicator Peer: \(connection.peerID.displayName)")
                listener.close(connection: connection)
            }
        } else {
            connection.disconnect()
        }
        connections.removeValue(forKey: connection.peerID)
    }
    
    private func startReplicator(forConnection connection: MultipeerConnection) {
        MultipeerSync.logger.info("Start Replicator to Listener Peer: \(connection.peerID.displayName)")
        let endpoint = MessageEndpoint(uid: connection.peerUUID!, target: connection,
                                       protocolType: .messageStream, delegate: self)
        
        var config = ReplicatorConfiguration(target: endpoint)
        config.addCollections(self.collections)
        config.continuous = true
        
        let replicator = Replicator(config: config)
        replicators[connection.peerID] = replicator
        replicator.start()
    }
}

extension ConnectionManager : MessageEndpointDelegate {
    func createConnection(endpoint: MessageEndpoint) -> any MessageEndpointConnection {
        return endpoint.target as! MessageEndpointConnection
    }
}
