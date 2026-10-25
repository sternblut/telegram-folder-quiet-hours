// A development harness, not part of the patch: an exhaustive check of the folder quiet hours rule — "a chat is
// silent when a folder whose quiet hours are on shows it" — against the folder's own chat list, as Postbox builds it
// for the folder tab. See verification/README.md for how to run it; the report it wrote is verification/report.txt.
import Foundation
import Postbox
import SwiftSignalKit

private struct CheckedChat {
    let peer: Peer
    let groupId: PeerGroupId
    let rowIsContact: Bool
    let isMuted: Bool
    let isUnread: Bool
    let title: String
    let kind: String
}

private struct SelfCheckReport {
    var checks = 0
    var notificationMismatches: [String] = []
    var rowMismatches: [String] = []
    var folderTabRowMismatches = 0
    var folderTabRowChecks = 0
    var storedChecks = 0
    var storedMismatches: [String] = []
    var holes = 0
}

private func note(_ list: inout [String], _ line: String) {
    if list.count < 60 {
        list.append(line)
    }
}

private func describeKind(_ peer: Peer, accountPeerId: PeerId) -> String {
    if peer.id == accountPeerId {
        return "self"
    }
    switch peer {
    case let user as TelegramUser:
        if user.botInfo != nil {
            return "bot"
        } else if user.flags.contains(.isSupport) {
            return "support"
        } else {
            return "user"
        }
    case is TelegramSecretChat:
        return "secret"
    case is TelegramGroup:
        return "group"
    case let channel as TelegramChannel:
        if case .broadcast = channel.info {
            return "channel"
        } else {
            return channel.flags.contains(.isForum) ? "forum" : "supergroup"
        }
    default:
        return String(describing: type(of: peer))
    }
}

private func describeFilter(_ data: ChatListFilterData) -> String {
    var parts: [String] = []
    let names: [(ChatListFilterPeerCategories, String)] = [(.contacts, "contacts"), (.nonContacts, "nonContacts"), (.groups, "groups"), (.channels, "channels"), (.bots, "bots")]
    parts.append("{" + names.filter { data.categories.contains($0.0) }.map { $0.1 }.joined(separator: ",") + "}")
    if data.excludeMuted { parts.append("excludeMuted") }
    if data.excludeRead { parts.append("excludeRead") }
    if data.excludeArchived { parts.append("excludeArchived") }
    return parts.joined(separator: " ")
}

public func quietHoursSelfCheck(account: Account) -> Signal<String, NoError> {
    let postbox = account.postbox
    let accountPeerId = account.peerId

    func viewPeerIds(_ predicate: ChatListFilterPredicate?, groupId: PeerGroupId) -> Signal<(Set<PeerId>, [CheckedChat], Int), NoError> {
        return postbox.tailChatListView(groupId: groupId, filterPredicate: predicate, count: 5000, summaryComponents: ChatListEntrySummaryComponents(), extractCachedData: nil, accountPeerId: accountPeerId)
        |> take(1)
        |> map { view, _ -> (Set<PeerId>, [CheckedChat], Int) in
            var ids = Set<PeerId>()
            var chats: [CheckedChat] = []
            var holes = 0
            for entry in view.entries {
                switch entry {
                case let .MessageEntry(data):
                    let peerId = data.index.messageIndex.id.peerId
                    ids.insert(peerId)
                    if let peer = data.renderedPeer.peers[peerId] {
                        let title: String
                        if let user = peer as? TelegramUser {
                            title = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
                        } else {
                            title = peer.debugDisplayTitle
                        }
                        chats.append(CheckedChat(peer: peer, groupId: groupId, rowIsContact: data.isContact, isMuted: data.isRemovedFromTotalUnreadCount, isUnread: data.readState?.state.isUnread ?? false, title: title, kind: describeKind(peer, accountPeerId: accountPeerId)))
                    }
                case .HoleEntry:
                    holes += 1
                }
            }
            if view.earlierIndex != nil {
                holes += 1000
            }
            return (ids, chats, holes)
        }
    }

    func cleared(_ data: ChatListFilterData) -> ChatListFilterData {
        var data = data
        data.excludeMuted = false
        data.excludeRead = false
        return data
    }

    func folderView(_ data: ChatListFilterData) -> Signal<Set<PeerId>, NoError> {
        return viewPeerIds(chatListFilterPredicate(filter: cleared(data), accountPeerId: accountPeerId), groupId: .root)
        |> map { $0.0 }
    }

    return combineLatest(viewPeerIds(nil, groupId: .root), viewPeerIds(nil, groupId: Namespaces.PeerGroup.archive))
    |> take(1)
    |> mapToSignal { root, archive -> Signal<String, NoError> in
        let chats = root.1 + archive.1
        let holes = root.2 + archive.2

        // Every folder rule: 32 sets of chat types × exclude muted × exclude read × exclude archived, and for each
        // chat every membership — none, included, excluded, pinned and their combinations — over 8 rounds.
        var configs: [ChatListFilterData] = []
        for categories in 0 ..< 32 {
            for flags in 0 ..< 8 {
                for round in 0 ..< 8 {
                    var include: [PeerId] = []
                    var exclude: [PeerId] = []
                    var pinned: [PeerId] = []
                    for (index, chat) in chats.enumerated() {
                        let membership = (index + round) % 8
                        if membership & 1 != 0 || membership & 4 != 0 {
                            include.append(chat.peer.id)
                        }
                        if membership & 2 != 0 {
                            exclude.append(chat.peer.id)
                        }
                        if membership & 4 != 0 {
                            pinned.append(chat.peer.id)
                        }
                    }
                    configs.append(ChatListFilterData(
                        isShared: false,
                        hasSharedLinks: false,
                        categories: ChatListFilterPeerCategories(rawValue: Int32(categories)),
                        excludeMuted: flags & 1 != 0,
                        excludeRead: flags & 2 != 0,
                        excludeArchived: flags & 4 != 0,
                        includePeers: ChatListFilterIncludePeers(peers: include, pinnedPeers: pinned),
                        excludePeers: exclude,
                        color: nil
                    ))
                }
            }
        }
        // Two quiet folders at once: a fixed spread of pairs.
        var pairs: [(Int, Int)] = []
        var seed: UInt64 = 0x51_7c_c1_b7_27_22_0a_95
        for _ in 0 ..< 400 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let a = Int((seed >> 33) % UInt64(configs.count))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let b = Int((seed >> 33) % UInt64(configs.count))
            pairs.append((a, b))
        }

        // In batches: a chain of one signal per folder rule would nest 2048 subscribers deep.
        func checkConfigs(from start: Int, _ views: [Int: Set<PeerId>]) -> Signal<[Int: Set<PeerId>], NoError> {
            if start >= configs.count {
                return .single(views)
            }
            let batch = Array(start ..< min(start + 32, configs.count))
            return combineLatest(batch.map { index in folderView(configs[index]) |> map { (index, $0) } })
            |> take(1)
            |> mapToSignal { results -> Signal<[Int: Set<PeerId>], NoError> in
                var views = views
                for (index, ids) in results {
                    views[index] = ids
                }
                return checkConfigs(from: start + 32, views)
            }
        }

        let storedFolders = postbox.transaction { transaction -> [ChatListFilter] in
            return _internal_currentChatListFilters(transaction: transaction).filter { filter in
                if case .filter = filter {
                    return true
                } else {
                    return false
                }
            }
        }

        return combineLatest(checkConfigs(from: 0, [:]), storedFolders)
        |> mapToSignal { views, storedFolders -> Signal<(([Int: Set<PeerId>], [ChatListFilter]), [Int32: Set<PeerId>]), NoError> in
            let storedViews = storedFolders.map { filter -> Signal<(Int32, Set<PeerId>), NoError> in
                guard case let .filter(id, _, _, data) = filter else {
                    return .complete()
                }
                return folderView(data) |> map { (id, $0) }
            }
            return combineLatest(storedViews)
            |> map { list -> (([Int: Set<PeerId>], [ChatListFilter]), [Int32: Set<PeerId>]) in
                var result: [Int32: Set<PeerId>] = [:]
                for (id, ids) in list {
                    result[id] = ids
                }
                return ((views, storedFolders), result)
            }
        }
        |> mapToSignal { input, storedViews -> Signal<String, NoError> in
            let (views, storedFolders) = input
            return postbox.transaction { transaction -> String in
                var report = SelfCheckReport()
                report.holes = holes
                func notificationPath(_ filters: [ChatListFilter], _ chat: CheckedChat) -> Bool {
                    // As _internal_chatListFiltersIncludePeer decides once it has the quiet folders.
                    let isContact = transaction.isPeerContact(peerId: chat.peer.notificationSettingsPeerId ?? chat.peer.id)
                    let groupId = transaction.getPeerChatListIndex(chat.peer.id).flatMap { EngineChatList.Group($0.0) }
                    return ChatListFiltersInclusion(filters: filters, accountPeerId: accountPeerId).includes(peer: EnginePeer(chat.peer), groupId: groupId, isContact: isContact)
                }
                func rowPath(_ filters: [ChatListFilter], _ chat: CheckedChat, listGroupId: PeerGroupId) -> Bool {
                    // As a chat list row decides: the list it is shown in, the row's contact status.
                    return ChatListFiltersInclusion(filters: filters, accountPeerId: accountPeerId).includes(peer: EnginePeer(chat.peer), groupId: EngineChatList.Group(listGroupId), isContact: chat.rowIsContact)
                }
                func describe(_ chat: CheckedChat) -> String {
                    return "\(chat.title) [\(chat.kind)\(chat.groupId == .root ? "" : ", archived")\(chat.rowIsContact ? ", contact" : "")\(chat.isMuted ? ", muted" : "")\(chat.isUnread ? ", unread" : "")]"
                }
                let folder: (ChatListFilterData) -> ChatListFilter = { data in
                    return .filter(id: 100, title: ChatFolderTitle(text: "Check", entities: [], enableAnimations: false), emoticon: nil, data: data)
                }

                for (index, data) in configs.enumerated() {
                    let expected = views[index] ?? Set()
                    for chat in chats {
                        report.checks += 1
                        let inFolder = expected.contains(chat.peer.id)
                        let membership = "include \(data.includePeers.peers.contains(chat.peer.id)) exclude \(data.excludePeers.contains(chat.peer.id)) pinned \(data.includePeers.pinnedPeers.contains(chat.peer.id))"
                        if notificationPath([folder(data)], chat) != inFolder {
                            note(&report.notificationMismatches, "\(describe(chat)) folder \(describeFilter(data)) \(membership): shown \(inFolder), silent \(!inFolder)")
                        }
                        if rowPath([folder(data)], chat, listGroupId: chat.groupId) != inFolder {
                            note(&report.rowMismatches, "\(describe(chat)) folder \(describeFilter(data)) \(membership): shown \(inFolder), grey \(!inFolder)")
                        }
                        if chat.groupId != .root {
                            // An archived chat shown in a folder tab: the row is checked as the tab's list.
                            report.folderTabRowChecks += 1
                            if rowPath([folder(data)], chat, listGroupId: .root) != inFolder {
                                report.folderTabRowMismatches += 1
                            }
                        }
                    }
                }
                for (a, b) in pairs {
                    let expected = (views[a] ?? Set()).union(views[b] ?? Set())
                    let filters = [folder(configs[a]), .filter(id: 101, title: ChatFolderTitle(text: "Check 2", entities: [], enableAnimations: false), emoticon: nil, data: configs[b])]
                    for chat in chats {
                        report.checks += 1
                        let inFolder = expected.contains(chat.peer.id)
                        if notificationPath(filters, chat) != inFolder {
                            note(&report.notificationMismatches, "\(describe(chat)) two folders \(describeFilter(configs[a])) + \(describeFilter(configs[b])): shown \(inFolder)")
                        }
                        if rowPath(filters, chat, listGroupId: chat.groupId) != inFolder {
                            note(&report.rowMismatches, "\(describe(chat)) two folders: shown \(inFolder)")
                        }
                    }
                }
                // The account's own folders, through the very function the app and the notification extension call.
                let storedIds = storedFolders.map { $0.id }
                for mask in 1 ..< (1 << storedIds.count) {
                    var quietIds = Set<Int32>()
                    var expected = Set<PeerId>()
                    for (bit, id) in storedIds.enumerated() where mask & (1 << bit) != 0 {
                        quietIds.insert(id)
                        expected.formUnion(storedViews[id] ?? Set())
                    }
                    for chat in chats {
                        report.storedChecks += 1
                        let silent = _internal_chatListFiltersIncludePeer(transaction: transaction, filterIds: quietIds, peerId: chat.peer.id, accountPeerId: accountPeerId)
                        if silent != expected.contains(chat.peer.id) {
                            note(&report.storedMismatches, "\(describe(chat)) quiet folders \(quietIds.sorted()): shown \(expected.contains(chat.peer.id)), silent \(silent)")
                        }
                    }
                }

                var kinds: [String: Int] = [:]
                for chat in chats {
                    let key = chat.kind + (chat.groupId == .root ? "" : " archived") + (chat.rowIsContact ? " contact" : "") + (chat.isMuted ? " muted" : "") + (chat.isUnread ? " unread" : "")
                    kinds[key, default: 0] += 1
                }
                var lines: [String] = []
                lines.append("Folder quiet hours self-check, \(Date())")
                lines.append("chats: \(chats.count) (\(kinds.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")))")
                lines.append("chat list holes or more chats than loaded: \(report.holes)")
                lines.append("folder rules: \(configs.count) single folders + \(pairs.count) pairs of folders; checks: \(report.checks)")
                lines.append("notification path mismatches: \(report.notificationMismatches.count)\(report.notificationMismatches.count == 60 ? "+" : "")")
                lines.append(contentsOf: report.notificationMismatches.map { "  N " + $0 })
                lines.append("chat list row mismatches (row in its own list): \(report.rowMismatches.count)\(report.rowMismatches.count == 60 ? "+" : "")")
                lines.append(contentsOf: report.rowMismatches.map { "  R " + $0 })
                lines.append("archived chat rows inside a folder tab (known limit): \(report.folderTabRowMismatches) of \(report.folderTabRowChecks)")
                lines.append("account folders \(storedIds), every set of quiet ones, _internal_chatListFiltersIncludePeer: \(report.storedChecks) checks, mismatches \(report.storedMismatches.count)")
                lines.append(contentsOf: report.storedMismatches.map { "  S " + $0 })
                for chat in chats {
                    lines.append("  chat: \(describe(chat))")
                }
                return lines.joined(separator: "\n")
            }
        }
    }
}
