import Contacts

/// Saves a person from a screenshot or chat into the Mac's Contacts (syncs to the iPhone).
enum ContactBook {
    enum Result { case saved, exists, denied, failed }

    static func save(name: String, phone: String?, email: String?, note: String?) async -> Result {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return .denied }
        let digits = phone.map { $0.filter { $0.isNumber || $0 == "+" } } ?? ""
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor]
        if digits.count >= 6,
           let found = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: digits)),
                                                  keysToFetch: keys), !found.isEmpty {
            return .exists
        }
        let c = CNMutableContact()
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        c.givenName = parts.first ?? name
        if parts.count > 1 { c.familyName = parts[1] }
        if !digits.isEmpty { c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone!))] }
        if let email, email.contains("@") { c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)] }
        // Notes need a special entitlement on current macOS, so the context goes into the job title field instead.
        if let note, !note.isEmpty { c.jobTitle = note }
        let req = CNSaveRequest()
        req.add(c, toContainerWithIdentifier: nil)
        do { try store.execute(req); return .saved } catch { return .failed }
    }
}
