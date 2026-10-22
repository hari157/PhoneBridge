// Recent calls (saved as JSON) and the Mac's contacts (read with the Contacts framework).

import Contacts
import Foundation

final class RecentsStore: ObservableObject {
    @Published private(set) var calls: [CallRecord] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recents.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            calls = (try? decoder.decode([CallRecord].self, from: data)) ?? []
        }
    }

    func add(_ record: CallRecord) {
        calls.insert(record, at: 0)
        if calls.count > 200 { calls.removeLast(calls.count - 200) }
        save()
    }

    func remove(_ record: CallRecord) {
        calls.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        calls = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(calls).write(to: url, options: .atomic)
    }
}

struct ContactItem: Identifiable {
    let id: String
    let name: String
    let numbers: [String]
}

final class ContactsStore: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var contacts: [ContactItem] = []
    @Published private(set) var access: Access = .unknown
    private var byNumber: [String: String] = [:]

    func load() {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { [weak self] granted, _ in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.access = .denied }
                return
            }
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.sortOrder = .userDefault
            var items: [ContactItem] = []
            var map: [String: String] = [:]
            try? store.enumerateContacts(with: request) { c, _ in
                let numbers = c.phoneNumbers.map { $0.value.stringValue }
                guard !numbers.isEmpty else { return }
                var name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                if name.isEmpty { name = c.organizationName }
                if name.isEmpty { name = numbers[0] }
                items.append(ContactItem(id: c.identifier, name: name, numbers: numbers))
                for n in numbers { map[Self.key(n)] = name }
            }
            DispatchQueue.main.async {
                self.contacts = items
                self.byNumber = map
                self.access = .granted
            }
        }
    }

    /// Matches on the last 10 digits, so "+91 98765 43210" and "09876543210" find the same contact.
    func name(for number: String) -> String? {
        let k = Self.key(number)
        return k.count >= 6 ? byNumber[k] : nil
    }

    static func key(_ number: String) -> String {
        String(number.filter(\.isNumber).suffix(10))
    }
}
