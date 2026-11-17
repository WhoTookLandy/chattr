import Testing
import Foundation
import Core
@testable import Features

/// The open intent reaches `onWillPresent` unchanged, on every open path,
/// and never leaks into a later presentation — that's what lets the preview
/// menu's Watch / Listen / Chat Only bypass Settings → When a Chat Opens.
@MainActor
@Suite("ChatTabsModel open intent")
struct ChatTabsModelOpenIntentTests {
    private func channel(_ name: String) -> ChannelDescriptor {
        ChannelDescriptor(
            channelId: name, channelLoginName: name,
            channelDisplayName: name, profileImageURL: nil
        )
    }

    private final class Recorder {
        var intents: [ChatOpenIntent] = []
    }

    private func model(recording recorder: Recorder) -> ChatTabsModel {
        let model = ChatTabsModel()
        model.onWillPresent = { _, intent in recorder.intents.append(intent) }
        return model
    }

    @Test("A plain open is implicit")
    func defaultIsImplicit() {
        let recorder = Recorder()
        let model = model(recording: recorder)
        model.open(channel: channel("a"))
        #expect(recorder.intents == [.implicit])
    }

    @Test("Explicit intent reaches onWillPresent when the pager presents")
    func explicitNewTab() {
        let recorder = Recorder()
        let model = model(recording: recorder)
        model.open(channel: channel("a"), intent: .explicit)
        #expect(recorder.intents == [.explicit])
    }

    @Test("Explicit intent reaches onWillPresent while already presented")
    func explicitWhilePresented() {
        let recorder = Recorder()
        let model = model(recording: recorder)
        model.open(channel: channel("a"))
        model.open(channel: channel("b"), intent: .explicit)
        model.open(channel: channel("a"), intent: .explicit)
        #expect(recorder.intents == [.implicit, .explicit, .explicit])
    }

    @Test("Explicit intent doesn't leak into the next presentation")
    func intentResets() {
        let recorder = Recorder()
        let model = model(recording: recorder)
        let a = model.open(channel: channel("a"), intent: .explicit)
        model.isPresented = false
        model.isPresented = true
        model.isPresented = false
        model.present(tabId: a, intent: .explicit)
        model.isPresented = false
        model.present(tabId: a)
        #expect(recorder.intents == [.explicit, .implicit, .explicit, .implicit])
    }
}
