//  RemindMeAgainApp.swift  –  FINAL 2025-07-03
//  Fully working: add / edit / delete reminders, custom sounds, snooze (1-24 h)

import SwiftUI
import UserNotifications

// MARK: – Globals
let SOUND_OPTIONS = ["default", "radar.wav", "bell.caf", "calm.caf"]
// Added 5, 15, 30 minutes to snooze options
let SNOOZE_MINUTES = [5, 15, 30, 60, 240, 360, 720, 1440] // 5m,15m,30m,1h,4h,6h,12h,24h

// MARK: – Model
struct Reminder: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var title: String
    var eventDate: Date
    var reminderDate: Date
    var soundName: String
}

// MARK: – Store
@MainActor final class ReminderStore: ObservableObject {
    @Published private(set) var reminders: [Reminder] = []
    private let center = UNUserNotificationCenter.current()
    private let url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("reminders.json")

    // CRUD
    func add(_ title: String, event: Date, remind: Date, sound: String) {
        let r = Reminder(id: UUID().uuidString, title: title, eventDate: event, reminderDate: remind, soundName: sound)
        reminders.append(r)
        schedule(r)
        save()
    }

    func update(_ r: Reminder) {
        guard let i = reminders.firstIndex(where: { $0.id == r.id }) else { return }
        reminders[i] = r
        center.removePendingNotificationRequests(withIdentifiers: [r.id, "AUTO_\(r.id)"])
        schedule(r)
        save()
    }

    func delete(_ r: Reminder) {
        reminders.removeAll { $0.id == r.id }
        center.removePendingNotificationRequests(withIdentifiers: [r.id, "AUTO_\(r.id)"])
        save()
    }

    // persistence
    private func save() {
        do {
            let data = try JSONEncoder().encode(reminders)
            try data.write(to: url)
        } catch {
            print("Error saving reminders: \(error)")
        }
    }

    private func load() {
        if let d = try? Data(contentsOf: url),
           let arr = try? JSONDecoder().decode([Reminder].self, from: d) {
            reminders = arr
        }
    }

    init() {
        load()
    }

    // schedule + 30 s backup
    private func schedule(_ r: Reminder) {
        let content = UNMutableNotificationContent()
        let df = DateFormatter()
        df.timeStyle = .short
        content.body = "Reminder • \(r.title) at \(df.string(from: r.eventDate))"
        content.sound = r.soundName == "default" ? .default : .init(named: .init(rawValue: r.soundName))
        content.categoryIdentifier = "REMINDER"

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: r.reminderDate)
        let calendarTrigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: calendarTrigger))

        let timeIntervalTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 30, repeats: false)
        center.add(UNNotificationRequest(identifier: "AUTO_\(r.id)", content: content, trigger: timeIntervalTrigger))
    }
}

// MARK: – Delegate
final class ReminderDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive res: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        defer { done() }
        let id = res.notification.request.identifier
        c.removePendingNotificationRequests(withIdentifiers: ["AUTO_\(id)"])
        guard res.actionIdentifier.starts(with: "SNOOZE_"), let mins = Int(res.actionIdentifier.dropFirst(7)) else { return }
        let timeIntervalTrigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(mins) * 60, repeats: false)
        c.add(UNNotificationRequest(identifier: id, content: res.notification.request.content, trigger: timeIntervalTrigger))
    }
}

// MARK: – App
@main struct RemindMeAgainApp: App {
    @StateObject private var store = ReminderStore()
    private var delegate: ReminderDelegate?    // hold strong ref

    init() {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // Updated snooze action titles to show minutes for less than an hour
        let acts = SNOOZE_MINUTES.map { minutes in
            let title: String
            if minutes < 60 {
                title = "Snooze \(minutes)m"
            } else {
                title = "Snooze \(minutes/60)h"
            }
            return UNNotificationAction(identifier: "SNOOZE_\(minutes)", title: title, options: [])
        }
        c.setNotificationCategories([.init(identifier: "REMINDER", actions: acts, intentIdentifiers: [], options: [])])
        let del = ReminderDelegate()
        c.delegate = del
        self.delegate = del
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
        }
    }
}

// MARK: – Main View
struct ContentView: View {
    @EnvironmentObject private var store: ReminderStore
    @State private var title = ""
    @State private var eventDate = Date()
    @State private var remindDate = Date().addingTimeInterval(60)
    @State private var sound = "default"
    @State private var toast: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("New Reminder") {
                    TextField("Event title", text: $title)
                    // Conditional background for Event DatePicker
                    DatePicker("Event", selection: $eventDate, displayedComponents: [.date, .hourAndMinute])
                        .background(eventDate < remindDate ? Color.red.opacity(0.3) : Color.clear) // Changed logic
                        .cornerRadius(8)
                    DatePicker("Remind", selection: $remindDate, displayedComponents: [.date, .hourAndMinute])
                    Picker("Sound", selection: $sound) {
                        ForEach(SOUND_OPTIONS, id: \.self) { s in
                            Text(s == "default" ? "Default" : s).tag(s)
                        }
                    }
                    Button("Remind") {
                        add()
                    }
                    .disabled(title.isEmpty || remindDate < Date())
                }
                Section("Upcoming Events") {
                    ForEach(store.reminders) { r in
                        NavigationLink(destination: EditSheet(rem: r)) {
                            ReminderRow(reminder: r) { rem in
                                store.delete(rem)
                                toast = "Event removed"
                            }
                        }
                    }
                }
            }
            .navigationTitle("Simple Reminders")
            .toast($toast)
        }
    }

    private func add() {
        store.add(title, event: eventDate, remind: remindDate, sound: sound)
        toast = "Event added"
        title = ""
        eventDate = Date()
        remindDate = Date().addingTimeInterval(60)
        sound = "default"
    }
}

struct ReminderRow: View {
    var reminder: Reminder
    var onDelete: (Reminder) -> Void

    var body: some View {
        HStack {
            // Changed format to "<event-title> at <event-time>"
            Text("\(reminder.title) at \(reminder.eventDate.formatted(date: .omitted, time: .shortened))")
            Spacer()
            Button(action: {
                onDelete(reminder)
            }) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.red) // Changed color from green to red
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: – Edit
struct EditSheet: View {
    @EnvironmentObject private var store: ReminderStore
    @Environment(\.dismiss) private var dismiss
    @State var rem: Reminder
    @State private var showToast = false // Renamed to avoid conflict with `toast` in ContentView
    @State private var showingDeleteConfirmation = false // New state for delete confirmation

    var body: some View {
        Form {
            TextField("Title", text: $rem.title)
            DatePicker("Event", selection: $rem.eventDate, displayedComponents: [.date, .hourAndMinute])
            DatePicker("Remind", selection: $rem.reminderDate, displayedComponents: [.date, .hourAndMinute])
            Picker("Sound", selection: $rem.soundName) {
                ForEach(SOUND_OPTIONS, id: \.self) { soundOption in
                    Text(soundOption)
                }
            }
            Button("Save") {
                store.update(rem)
                showToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    dismiss()
                }
            }

            // New delete button
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Text("Delete Reminder")
                    .frame(maxWidth: .infinity) // Make button span full width
            }
        }
        .navigationTitle("Edit Reminder")
        .alert("Event edited", isPresented: $showToast) {
            Button("OK", role: .cancel) {}
        }
        // Confirmation dialog for deletion
        .confirmationDialog("Are you sure you want to delete this reminder?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(rem)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}

// MARK: – Toast helper
extension View {
    func toast(_ text: Binding<String?>) -> some View {
        ZStack {
            self
            if let t = text.wrappedValue {
                Text(t)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                            withAnimation {
                                text.wrappedValue = nil
                            }
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: text.wrappedValue)
    }
}

