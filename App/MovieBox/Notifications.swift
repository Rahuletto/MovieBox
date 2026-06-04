import Foundation

extension Notification.Name {
    /// Posted when Finder or `open` launches MovieBox with a `.moviebox_*.stream` file.
    static let movieBoxOpenStreamFile = Notification.Name("MovieBoxOpenStreamFile")
    /// Magnet links, `.torrent` files, and other import URLs.
    static let movieBoxOpenImportURL = Notification.Name("MovieBoxOpenImportURL")
}
