// RemindMeAgainApp.swift
//
// A reminder app with the following features:
// - Create one-time or recurring reminders (hourly, daily, weekly, monthly, yearly)
// - Customizable notification sounds
// - Snooze functionality (5m to 24h options)
// - Notification persistence (60-minute repeating backup notifications)
// - Deep linking from notifications to reminder details
//
// Key Components:
// 1. Reminder Model: Stores reminder data including title, dates, sound, and recurrence
// 2. ReminderStore: Manages persistence and notification scheduling (@MainActor)
// 3. NotificationHandler: Handles notification interactions and navigation
// 4. ReminderDelegate: UNUserNotificationCenterDelegate implementation
// 5. Views: ContentView (main list), ReminderDetailView, EditSheet
//
// Data Flow:
// - User creates reminders → stored in ReminderStore → scheduled with UNUserNotificationCenter
// - Notifications trigger → handled by ReminderDelegate → updates UI via NotificationHandler
// - All data persisted to JSON file in Documents directory
//
// Usage Notes:
// - Requires Notification permissions
// - Tested on iOS 15+
// - Uses SwiftUI and Combine frameworks
//
// Known Issues:
// - None currently
//
// Created by: Vajrasar Goswami (prompting ChatGPT, Gemini, and Deepseek)
// Last Updated: July 04, 2025


import SwiftUI
import UserNotifications

// MARK: - Constants
let SOUND_OPTIONS = ["default", "radar.wav", "bell.caf", "calm.caf"]
let SNOOZE_MINUTES = [5, 15, 30, 60, 240, 360, 720, 1440]
let RECURRENCE_OPTIONS = ["None", "Hourly", "Daily", "Weekly", "Monthly", "Yearly"]

// MARK: - Data Model
struct Reminder: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var title: String
    var eventDate: Date
    var reminderDate: Date
    var soundName: String
    var recurrence: String
    var nextTriggerDate: Date?
    var snoozedUntil: Date?
}

// MARK: - Data Store
@MainActor final class ReminderStore: ObservableObject {
    @Published private(set) var reminders: [Reminder] = []
    private let center = UNUserNotificationCenter.current()
    private let url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("reminders.json")
    
    // CRUD Operations
    func add(_ title: String, event: Date, remind: Date, sound: String, recurrence: String) {
        let newReminder = Reminder(
            id: UUID().uuidString,
            title: title,
            eventDate: event,
            reminderDate: remind,
            soundName: sound,
            recurrence: recurrence,
            nextTriggerDate: remind
        )
        reminders.append(newReminder)
        schedule(newReminder)
        save()
    }
    
    func update(_ reminder: Reminder) {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        reminders[index] = reminder
        reschedule(reminder)
        save()
    }
    
    func delete(_ reminder: Reminder) {
        reminders.removeAll { $0.id == reminder.id }
        center.removePendingNotificationRequests(withIdentifiers: [reminder.id, "AUTO_\(reminder.id)"])
        save()
    }
    
    func snooze(_ reminder: Reminder, minutes: Int) {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        let snoozeDate = Date().addingTimeInterval(Double(minutes) * 60)
        reminders[index].snoozedUntil = snoozeDate
        reschedule(reminders[index])
        save()
    }
    
    func getReminder(withID id: String) -> Reminder? {
        reminders.first { $0.id == id }
    }
    
    // Private methods
    private func save() {
        do {
            let data = try JSONEncoder().encode(reminders)
            try data.write(to: url)
        } catch {
            print("Error saving reminders: \(error.localizedDescription)")
        }
    }
    
    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Reminder].self, from: data) else { return }
        reminders = decoded
        reminders.forEach { reschedule($0) }
    }
    
    private func reschedule(_ reminder: Reminder) {
        center.removePendingNotificationRequests(withIdentifiers: [reminder.id, "AUTO_\(reminder.id)"])
        schedule(reminder)
    }
    
    private func schedule(_ reminder: Reminder) {
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = "\(reminder.title) at \(reminder.eventDate.formatted(date: .omitted, time: .shortened))"
        content.sound = reminder.soundName == "default" ? .default : .init(named: .init(rawValue: reminder.soundName))
        content.categoryIdentifier = "REMINDER"
        content.userInfo = ["reminderID": reminder.id]
        
        // Calculate next trigger date
        let now = Date()
        var triggerDate: Date
        
        if let snoozedUntil = reminder.snoozedUntil, snoozedUntil > now {
            // Use snooze time if set and in the future
            triggerDate = snoozedUntil
        } else if reminder.recurrence == "None" {
            // For one-time reminders
            triggerDate = reminder.reminderDate
        } else {
            // For recurring reminders
            var nextTrigger = reminder.reminderDate
            var components = DateComponents()
            
            switch reminder.recurrence {
            case "Hourly": components.hour = 1
            case "Daily": components.day = 1
            case "Weekly": components.weekOfYear = 1
            case "Monthly": components.month = 1
            case "Yearly": components.year = 1
            default: break
            }
            
            while nextTrigger <= now {
                nextTrigger = Calendar.current.date(byAdding: components, to: nextTrigger) ?? nextTrigger
            }
            triggerDate = nextTrigger
        }
        
        // Update next trigger in model
        if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders[index].nextTriggerDate = triggerDate
        }
        
        // Only schedule if trigger is in the future
        if triggerDate > now {
            let calendarTrigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate),
                repeats: false
            )
            center.add(UNNotificationRequest(
                identifier: reminder.id,
                content: content,
                trigger: calendarTrigger
            ))
            
            // 60-minute backup notification
            let backupTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: true)
            center.add(UNNotificationRequest(
                identifier: "AUTO_\(reminder.id)",
                content: content,
                trigger: backupTrigger
            ))
        }
    }
}

// MARK: - Notification Handling
final class NotificationHandler: ObservableObject {
    @Published var selectedReminderID: String?
    weak var store: ReminderStore?
}

final class ReminderDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onNotificationTap: ((String) -> Void)?
    weak var store: ReminderStore?
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                              didReceive response: UNNotificationResponse,
                              withCompletionHandler completion: @escaping () -> Void) {
        defer { completion() }
        
        let userInfo = response.notification.request.content.userInfo
        guard let reminderID = userInfo["reminderID"] as? String else { return }
        
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // Handle notification tap
            DispatchQueue.main.async {
                self.onNotificationTap?(reminderID)
            }
        } else if response.actionIdentifier.starts(with: "SNOOZE_"),
                  let minutes = Int(response.actionIdentifier.dropFirst(7)) {
            // Handle snooze action
            DispatchQueue.main.async {
                if let reminder = self.store?.getReminder(withID: reminderID) {
                    self.store?.snooze(reminder, minutes: minutes)
                }
            }
        }
    }
}

// MARK: - App Structure
@main struct RemindMeAgainApp: App {
    @StateObject private var store = ReminderStore()
    @StateObject private var notificationHandler = NotificationHandler()
    private let delegate = ReminderDelegate()
    
    init() {
        configureNotifications()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(store: store, notificationHandler: notificationHandler)
                .onAppear {
                    delegate.store = store
                    delegate.onNotificationTap = { id in
                        notificationHandler.selectedReminderID = id
                    }
                    notificationHandler.store = store
                    UNUserNotificationCenter.current().delegate = delegate
                }
        }
    }
    
    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        
        let actions = SNOOZE_MINUTES.map { minutes in
            let title = minutes < 60 ? "Snooze \(minutes)m" : "Snooze \(minutes/60)h"
            return UNNotificationAction(identifier: "SNOOZE_\(minutes)", title: title, options: [])
        }
        
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "REMINDER",
                actions: actions,
                intentIdentifiers: [],
                options: []
            )
        ])
    }
}

// MARK: - Views
struct ContentView: View {
    @ObservedObject var store: ReminderStore
    @ObservedObject var notificationHandler: NotificationHandler
    @State private var newReminder = NewReminderData()
    @State private var toastMessage: String?
    
    var body: some View {
        NavigationStack {
            List {
                newReminderSection
                remindersListSection
            }
            .navigationTitle("Remind Me Again")
            .overlay(toastOverlay)
            .background(
                NavigationLink(
                    destination: Group {
                        if let id = notificationHandler.selectedReminderID,
                           let reminder = store.getReminder(withID: id) {
                            ReminderDetailView(reminder: reminder, store: store)
                        }
                    },
                    isActive: Binding(
                        get: { notificationHandler.selectedReminderID != nil },
                        set: { if !$0 { notificationHandler.selectedReminderID = nil } }
                    ),
                    label: { EmptyView() }
                )
            )
        }
    }
    
    private var newReminderSection: some View {
        Section("New Reminder") {
            TextField("Event title", text: $newReminder.title)
            DatePicker("Event", selection: $newReminder.eventDate, displayedComponents: [.date, .hourAndMinute])
            DatePicker("Remind", selection: $newReminder.reminderDate, displayedComponents: [.date, .hourAndMinute])
            Picker("Sound", selection: $newReminder.sound) {
                ForEach(SOUND_OPTIONS, id: \.self) { sound in
                    Text(sound == "default" ? "Default" : sound)
                }
            }
            Picker("Recurrence", selection: $newReminder.recurrence) {
                ForEach(RECURRENCE_OPTIONS, id: \.self) { freq in
                    Text(freq)
                }
            }
            Button("Add Reminder") {
                addReminder()
            }
            .disabled(newReminder.title.isEmpty || newReminder.reminderDate < Date())
        }
    }
    
    private var remindersListSection: some View {
        Section("Upcoming Reminders") {
            ForEach(store.reminders) { reminder in
                NavigationLink {
                    ReminderDetailView(reminder: reminder, store: store)
                } label: {
                    ReminderRow(reminder: reminder)
                }
            }
        }
    }
    
    private var toastOverlay: some View {
        Group {
            if let message = toastMessage {
                Text(message)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation {
                                toastMessage = nil
                            }
                        }
                    }
            }
        }
        .animation(.easeInOut, value: toastMessage)
    }
    
    private func addReminder() {
        store.add(
            newReminder.title,
            event: newReminder.eventDate,
            remind: newReminder.reminderDate,
            sound: newReminder.sound,
            recurrence: newReminder.recurrence
        )
        toastMessage = "Reminder added"
        newReminder = NewReminderData()
    }
}

struct ReminderRow: View {
    let reminder: Reminder
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reminder.title).font(.headline)
            Text(reminder.eventDate.formatted(date: .omitted, time: .shortened))
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if reminder.recurrence != "None" {
                Text("Recurs: \(reminder.recurrence)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if let nextTrigger = reminder.nextTriggerDate {
                Text("Next: \(nextTrigger.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if let snoozedUntil = reminder.snoozedUntil {
                Text("Snoozed until: \(snoozedUntil.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ReminderDetailView: View {
    let reminder: Reminder
    @ObservedObject var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    @State private var showEditSheet = false
    @State private var showDeleteConfirmation = false
    
    private var formattedEventDate: String {
        reminder.eventDate.formatted(date: .abbreviated, time: .shortened)
    }
    
    private var formattedReminderDate: String {
        reminder.reminderDate.formatted(date: .abbreviated, time: .shortened)
    }
    
    private var formattedNextTrigger: String? {
        reminder.nextTriggerDate?.formatted(date: .abbreviated, time: .shortened)
    }
    
    private var formattedSnoozedUntil: String? {
        reminder.snoozedUntil?.formatted(date: .abbreviated, time: .shortened)
    }
    
    var body: some View {
        List {
            Section {
                DetailRow(label: "Title", value: reminder.title)
                DetailRow(label: "Event Time", value: formattedEventDate)
                DetailRow(label: "Reminder Time", value: formattedReminderDate)
                DetailRow(label: "Sound", value: reminder.soundName == "default" ? "Default" : reminder.soundName)
                DetailRow(label: "Recurrence", value: reminder.recurrence)
                
                if let trigger = formattedNextTrigger {
                    DetailRow(label: "Next Trigger", value: trigger)
                }
                
                if let snoozed = formattedSnoozedUntil {
                    DetailRow(label: "Snoozed Until", value: snoozed)
                        .foregroundColor(.orange)
                }
            }
            
            Section {
                Button("Edit") { showEditSheet = true }
                Button(role: .destructive) { showDeleteConfirmation = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Reminder Details")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditSheet) {
            EditSheet(reminder: reminder, store: store)
        }
        .confirmationDialog(
            "Delete Reminder",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.delete(reminder)
                dismiss()
            }
        }
    }
}

struct EditSheet: View {
    @State private var editedReminder: Reminder
    @ObservedObject var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    
    init(reminder: Reminder, store: ReminderStore) {
        self._editedReminder = State(initialValue: reminder)
        self.store = store
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $editedReminder.title)
                    DatePicker("Event", selection: $editedReminder.eventDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Remind", selection: $editedReminder.reminderDate, displayedComponents: [.date, .hourAndMinute])
                    
                    Picker("Sound", selection: $editedReminder.soundName) {
                        ForEach(SOUND_OPTIONS, id: \.self) { sound in
                            Text(sound == "default" ? "Default" : sound)
                        }
                    }
                    
                    Picker("Recurrence", selection: $editedReminder.recurrence) {
                        ForEach(RECURRENCE_OPTIONS, id: \.self) { freq in
                            Text(freq)
                        }
                    }
                }
                
                Section {
                    Button(role: .destructive) {
                        store.delete(editedReminder)
                        dismiss()
                    } label: {
                        Label("Delete Reminder", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Edit Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.update(editedReminder)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var color: Color = .primary
    
    var body: some View {
        HStack {
            Text(label).fontWeight(.medium)
            Spacer()
            Text(value)
                .foregroundColor(color)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }
}

struct NewReminderData {
    var title = ""
    var eventDate = Date()
    var reminderDate = Date().addingTimeInterval(60)
    var sound = "default"
    var recurrence = "None"
}
