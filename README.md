## couchbase-lite-multipeer-sync-sample

This sample project demonstrates peer-to-peer synchronization using Apple's Multipeer Connectivity Framework.

The application showcases color synchronization between peers, akin to the color sync feature in the Simple-Sync application, but utilizing the Multipeer Connectivity framework instead of the Apple Network Framework.

### Overview

The `MultipeerSync` class manages peer-to-peer synchronization by leveraging the Multipeer Connectivity framework. It handles peer discovery, advertising, and connection management within a network of peers. The class provides two primary functions for initiating and terminating synchronization.

**Key Features:**

- **Peer Discovery & Advertising:**
  - Advertises the local peer and searches for other peers offering the same service type.
  - Establishes and manages connections among peers, enabling each peer to connect with all discovered peers in a simple full mesh topology.
  - The full mesh topology as implemented in this sample is generally suitable for a small number of peers. For a larger number of peers, it is more efficient to select a subset of peers to act as advertiser peers, forming a cluster of server peers. This approach reduces the network traffic and complexity of maintaining connections.
  
- **Peer Role:**
  - **One-Way Connections:** In a peer-to-peer connection, one peer acts as a listener (passive peer) and the other as a replicator (active peer).
  - **Role Determination:** The peer role is assigned based on UUIDs. The peer with the smaller UUID becomes the active (replicator) peer, while the peer with the larger UUID is the passive (listener) peer.

- **Replicator Configuration:**
  - **Active Peers:** Configures the replicator as a continuous push-pull replicator for ongoing data synchronization.

### Prerequisites

- Xcode 15 or later

### Getting Started

* Clone the repo
* Open `multipeer-sync.xcodeproj` using XCode
* Select an iOS simulator or device
* Run the app