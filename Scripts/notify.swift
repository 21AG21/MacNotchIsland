import Foundation

// Sends a `notchisland://` URL to a running Notch Island through the distributed
// notification the app listens on, which is the same path `Scripts/notchctl` takes when it
// hands the URL to LaunchServices. Used by the smoke test, where the app is launched straight
// out of its bundle and LaunchServices has never been told the scheme exists.
let url = CommandLine.arguments.dropFirst().first ?? "notchisland://home"
DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.macnotchisland.api"),
                                                             object: url, userInfo: nil, deliverImmediately: true)
// The post is handed to distnoted, not to the app; a process that exits on the next line can
// outrun its own notification.
Thread.sleep(forTimeInterval: 0.3)
