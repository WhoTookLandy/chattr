import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

extension ChannelSession {

    /// Moves this running session onto `newClient`: the account signed in
    /// again and got a new client, and the one this session was built with
    /// holds a credential that stops working once its access token expires.
    ///
    /// Only the transport changes. Subscribers, the ring and every other
    /// piece of session state stay, so tabs keep their session reference.
    /// The old client's subscriptions are deleted (best-effort), the same
    /// topics are subscribed on the new client's socket, and a gap resync
    /// covers whatever was broadcast in between. A topic that can't be
    /// subscribed right away is retried in the background (`retryTopics`).
    ///
    /// Called only by `ChannelSessionRegistry.clientReplaced`: on started
    /// sessions, and never two rebinds of one session at a time.
    ///
    /// Returns the client the session was on, or nil when there was nothing
    /// to do (already on `newClient`, or stopped).
    @discardableResult
    func rebind(to newClient: TwitchClient) async -> TwitchClient? {
        guard !isStopped, newClient !== client else { return nil }
        logger.notice("Rebinding #\(self.channelLoginName, privacy: .public) to the account's new client")
        let oldClient = client

        // Nothing received from here until the new subscriptions are live:
        // the resync below fills from this point.
        let gapFloor = lastLiveReceiptAt

        // Background work that would go on subscribing with the old client.
        retryTopics([])
        liveEventsTask?.cancel()
        liveEventsTask = nil

        let oldTopics = topics
        let oldIds = activeSubscriptionIds
        activeSubscriptionIds = []
        let hadModerationEvents = resetModerationEvents()
        let http = chatActions.http

        client = newClient
        topics = EventSubTopics(
            client: newClient,
            channelId: channelId,
            accountUserId: accountUserId,
            channelLoginName: channelLoginName,
            authRetry: authRetry
        )
        chatActions = HelixChatActions(
            client: newClient,
            channelId: channelId,
            accountUserId: accountUserId,
            authRetry: authRetry,
            http: http
        )

        // Old side first, same order as a release followed by a re-acquire.
        // The registry has usually closed the old socket already; deleting
        // still frees the subscriptions' quota instead of waiting for Twitch
        // to expire them. Best-effort: the old credential may be dead.
        await oldTopics.unsubscribe(oldIds)
        guard !isStopped else { return oldClient }

        let wanted = [EventSubTopics.SessionTopic.chat] + EventSubTopics.SessionTopic.enrichment
        var failed = wanted
        do {
            try await newClient.eventSub.connect()
            needsEventSubConnect = false
            failed = await subscribeTopics(wanted)
        } catch {
            // The retry task connects, then subscribes everything.
            needsEventSubConnect = true
            logger.error("Couldn't connect EventSub on the new client for #\(self.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public); retrying")
        }
        guard !isStopped else { return oldClient }
        // If chat has to be retried, that retry resyncs from the same floor.
        chatGapFloor = failed.contains(.chat) ? gapFloor : nil
        retryTopics(failed)

        if hadModerationEvents {
            await enableModerationEvents()
        }
        if channelId == accountUserId, !isStopped {
            liveEventsTask = Task { [weak self] in
                await self?.startLiveEvents()
            }
        }
        await resyncAfterReconnect(droppedAt: gapFloor)
        return oldClient
    }
}
