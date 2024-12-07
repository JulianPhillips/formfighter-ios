//
//  ProfileVM.swift
//  FormFighter
//
//  Created by Julian Parker on 10/4/24.
//


import Foundation
import Firebase
import FirebaseFirestore
import os.log

class ProfileVM: ObservableObject {
    @Published var feedbacks: [FeedbackListItem] = []
    @Published var isLoading = true
    @Published var error: String?
    
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var hasInitialized = false
    private let logger = OSLog(subsystem: "com.formfighter", category: "ProfileVM")
    
    struct FeedbackListItem: Identifiable {
        let id: String
        let date: Date
        let status: FeedbackStatus
        let videoUrl: String?
        let score: Double
        
        var isCompleted: Bool {
            return status == .completed
        }
        
        var isLoading: Bool {
            return status.isProcessing
        }
    }
    
  
    
    @Published var hourlyStats: [PunchStats] = []
    @Published var dailyStats: [PunchStats] = []
    @Published var weeklyStats: [PunchStats] = []
    
    private func processStatsData() {
        let calendar = Calendar.current
        let now = Date()
        
        // Process hourly stats (24 hours)
        let dayAgo = calendar.date(byAdding: .hour, value: -24, to: now)!
        hourlyStats = processTimeIntervalStats(
            from: dayAgo,
            to: now,
            interval: .hour,
            calendar: calendar
        )
        
        // Process daily stats (7 days)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        dailyStats = processTimeIntervalStats(
            from: weekAgo,
            to: now,
            interval: .day,
            calendar: calendar
        )
        
        // Process weekly stats (4 weeks)
        let monthAgo = calendar.date(byAdding: .day, value: -28, to: now)!
        weeklyStats = processTimeIntervalStats(
            from: monthAgo,
            to: now,
            interval: .weekOfYear,
            calendar: calendar
        )
    }
    
    private func processTimeIntervalStats(
        from startDate: Date,
        to endDate: Date,
        interval: Calendar.Component,
        calendar: Calendar
    ) -> [PunchStats] {
        var stats: [PunchStats] = []
        var currentDate = startDate
        
        while currentDate <= endDate {
            let nextDate = calendar.date(byAdding: interval, value: 1, to: currentDate)!
            let periodFeedbacks = feedbacks.filter { feedback in
                feedback.date >= currentDate && feedback.date < nextDate && feedback.isCompleted
            }
            
            if !periodFeedbacks.isEmpty {
                let averageScore = periodFeedbacks.reduce(0.0) { $0 + $1.score } / Double(periodFeedbacks.count)
                
                stats.append(PunchStats(
                    timestamp: currentDate,
                    score: averageScore,
                    count: periodFeedbacks.count
                ))
            }
            
            currentDate = nextDate
        }
        
        return stats
    }
    
    func fetchUserFeedback(userId: String) {
        guard !hasInitialized else { return }
        hasInitialized = true
        
        os_log("Fetching feedback for user: %@", log: logger, type: .debug, userId)
        isLoading = true
        
        let feedbackRef = db.collection("feedback")
            .whereField("userId", isEqualTo: userId)
        
        listener = feedbackRef.addSnapshotListener { [weak self] (snapshot: QuerySnapshot?, error: Error?) in
            guard let self = self else { return }
            
            if let error = error {
                os_log("Error fetching feedback: %@", log: self.logger, type: .error, error.localizedDescription)
                self.error = error.localizedDescription
                self.isLoading = false
                return
            }
            
            guard let documents = snapshot?.documents else {
                os_log("No feedback documents found", log: self.logger, type: .debug)
                self.isLoading = false
                return
            }
            
            self.feedbacks = documents.compactMap { document in
                let data = document.data()
                
                // Skip if document has an error field or missing/null status
                guard data["error"] == nil,  // Skip if error field exists
                      let statusString = data["status"] as? String,  // Skip if status is null or not a string
                      !statusString.isEmpty,  // Skip if status is empty string
                      let status = FeedbackStatus(rawValue: statusString)  // Skip if status is not valid
                else {
                    os_log("Skipping invalid feedback: %@", log: self.logger, type: .debug, document.documentID)
                    return nil
                }
                
                // Check for modelFeedback.body.error
                if let modelFeedback = data["modelFeedback"] as? [String: Any],
                   let body = modelFeedback["body"] as? [String: Any] {
                    // If there's any error field in body, skip this feedback
                    if let error = body["error"] as? String {
                        os_log("Skipping feedback with body error: %@ - Error: %@", 
                              log: self.logger, 
                              type: .debug, 
                              document.documentID,
                              error)
                        return nil
                    }
                }
                
                let jabScore: Double
                
                if status == .completed {
                    if let modelFeedback = data["modelFeedback"] as? [String: Any],
                       let body = modelFeedback["body"] as? [String: Any],
                       let score = body["jab_score"] as? Double {
                        jabScore = score
                    } else {
                        jabScore = 0.0
                    }
                } else {
                    jabScore = 0.0
                }
                
                os_log("Processing feedback: %@ with status: %@", log: self.logger, type: .debug, document.documentID, status.rawValue)
                
                return FeedbackListItem(
                    id: document.documentID,
                    date: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
                    status: status,
                    videoUrl: data["videoUrl"] as? String,
                    score: jabScore
                )
            }
            
            os_log("Fetched %d valid feedback items", log: self.logger, type: .debug, self.feedbacks.count)
            self.isLoading = false
            self.processStatsData()
        }
    }
    
    deinit {
        os_log("ProfileVM deinitializing, removing listener", log: logger, type: .debug)
        listener?.remove()
    }
}
