import Foundation

struct FolderItem: Identifiable, Comparable, Codable {
    let id: UUID
    let name: String
    let path: String
    let size: Int64
    let isDirectory: Bool
    
    var percentage: Double = 0.0
    
    // Optional fields kept for internal processing but not displayed
    let itemCount: Int
    let lastModified: Date
    var children: [FolderItem] = []
    
    var formattedSize: String {
        ByteFormatter.formatFileSize(size).replacingOccurrences(of: ",", with: "")
    }
    
    var formattedItemCount: String {
        if itemCount >= 1000000 {
            return String(format: "%.1fM", Double(itemCount) / 1_000_000.0)
        } else if itemCount >= 1000 {
            return String(format: "%.1fK", Double(itemCount) / 1000.0)
        } else {
            return "\(itemCount)"
        }
    }
    
    var relativeModified: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: lastModified, relativeTo: Date())
    }
    
    static func < (lhs: FolderItem, rhs: FolderItem) -> Bool {
        return lhs.size > rhs.size // Sort by size descending
    }
    
    // Standard initializer
    init(name: String, path: String, size: Int64, isDirectory: Bool, itemCount: Int, lastModified: Date, children: [FolderItem] = []) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.percentage = 0.0
        self.itemCount = itemCount
        self.lastModified = lastModified
        self.children = children
    }
    
    // Custom Codable implementation to handle UUID properly
    private enum CodingKeys: String, CodingKey {
        case id, name, path, size, isDirectory, percentage, itemCount, lastModified, children
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        size = try container.decode(Int64.self, forKey: .size)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        percentage = try container.decodeIfPresent(Double.self, forKey: .percentage) ?? 0.0
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        lastModified = try container.decode(Date.self, forKey: .lastModified)
        children = try container.decodeIfPresent([FolderItem].self, forKey: .children) ?? []
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(size, forKey: .size)
        try container.encode(isDirectory, forKey: .isDirectory)
        try container.encode(percentage, forKey: .percentage)
        try container.encode(itemCount, forKey: .itemCount)
        try container.encode(lastModified, forKey: .lastModified)
        try container.encode(children, forKey: .children)
    }
}