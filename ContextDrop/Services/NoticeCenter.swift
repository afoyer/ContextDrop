import Observation

/// The one-line message shown above the input ("Saved /name → ~/code", "AirDrop isn’t available…").
/// Anything in the app can post one; the Quick Chat panel and the chat view show it until it is dismissed.
/// The room window has its own (`RoomStore.notice`), because it is a different window.
@MainActor
@Observable
final class NoticeCenter {
    var text: String?
}
