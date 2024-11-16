import SwiftUI
import AVFoundation
import Vision
import Photos
import AVKit
import FirebaseFirestore
import Alamofire
import os

// Create a dedicated error type
enum ResultsViewError: LocalizedError {
    case userNotLoggedIn
    case failedToCreateFeedback(Error)
    case uploadError(Error)
    
    var errorDescription: String? {
        switch self {
        case .userNotLoggedIn:
            return "User not logged in"
        case .failedToCreateFeedback(let error):
            return "Failed to create feedback: \(error.localizedDescription)"
        case .uploadError(let error):
            return "Upload error: \(error.localizedDescription)"
        }
    }
}

struct ResultsView: View {
    var videoURL: URL
    @Environment(\.dismiss) var dismiss
    @AppStorage("selectedTab") private var selectedTab: String = TabIdentifier.vision.rawValue
    @State private var shouldSwitchToProfile = false
    
    @State private var player: AVPlayer
    @State private var shouldNavigateToFeedback = false
    @EnvironmentObject var userManager: UserManager
    @State private var isUploading = false
    @State private var activeError: ResultsViewError?
    @State private var feedbackId: String?
    let db = Firestore.firestore()
    
    init(videoURL: URL) {
        self.videoURL = videoURL
        self._player = State(initialValue: AVPlayer(url: videoURL))
    }
    
    var body: some View {
        ZStack {
            // Video player
            VideoPlayer(player: player)
                .edgesIgnoringSafeArea(.all)
                .disabled(true)
                .onAppear {
                    player.play()
                }
            
            // Upload overlay
            if isUploading {
                Color.black.opacity(0.5)
                uploadingView
            }
            
            // Buttons at bottom
            VStack {
                Spacer()
                HStack(spacing: 20) {
                    Button("Discard") {
                        deleteTemporaryVideo()
                        dismiss()
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.red)
                    .cornerRadius(10)
                    
                    Button("Save") {
                        Task {
                            await initiateFeedback()
                        }
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(10)
                    .disabled(isUploading)
                }
                .padding(.bottom, 30)
            }
        }
        .navigationDestination(isPresented: $shouldNavigateToFeedback) {
            if let feedbackId = feedbackId {
                FeedbackView(feedbackId: feedbackId, videoURL: videoURL)
                    .environmentObject(UserManager.shared)
            }
        }
        .navigationBarBackButtonHidden(true)
        .alert(
            "Error",
            isPresented: Binding(
                get: { activeError != nil },
                set: { if !$0 { activeError = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) {
                    activeError = nil
                }
            },
            message: {
                if let error = activeError {
                    Text(error.localizedDescription)
                }
            }
        )
        .onDisappear {
            // Cleanup
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }
    
    func deleteTemporaryVideo() {
        do {
            try FileManager.default.removeItem(at: videoURL)
            print("Temporary video file deleted.")
        } catch {
            print("Error deleting video file: \(error)")
        }
    }
    
    private func initiateFeedback() async {
        guard !isUploading else { return }
        guard !userManager.userId.isEmpty else {
            activeError = .userNotLoggedIn
            return
        }
        
        isUploading = true
        defer { isUploading = false }
        
        do {
            let userDoc = try await db.collection("users").document(userManager.userId).getDocument()
            let coachId = userDoc.data()?["myCoach"] as? String
            
            let feedbackRef = try await db.collection("feedback").addDocument(data: [
                "userId": userManager.userId,
                "coachId": coachId as Any,
                "createdAt": Timestamp(date: Date()),
                "status": "pending",
                "fileName": videoURL.lastPathComponent
            ])
            
            // Upload video immediately after creating feedback document
            await uploadToServer(feedbackId: feedbackRef.documentID, coachId: coachId)
        } catch {
            activeError = .failedToCreateFeedback(error)
        }
    }
    
    private func uploadToServer(feedbackId: String, coachId: String?) async {
        print("⚡️ Starting upload")
        isUploading = true
        
        do {
            let headers: HTTPHeaders = [
                "userID": userManager.userId,
                "Content-Type": "multipart/form-data"
            ]
            
            print("⚡️ feedbackId: \(feedbackId)")
            print("⚡️ coachId: \(coachId ?? "nil")")
            print("⚡️ videoURL: \(videoURL)")
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                AF.upload(multipartFormData: { multipartFormData in
                    multipartFormData.append(
                        videoURL,
                        withName: "file",
                        fileName: videoURL.lastPathComponent,
                        mimeType: "video/quicktime"
                    )
                    
                    multipartFormData.append(
                        feedbackId.data(using: .utf8)!,
                        withName: "feedbackId"
                    )
                    
                    if let coachId = coachId {
                        multipartFormData.append(
                            coachId.data(using: .utf8)!,
                            withName: "coachId"
                        )
                    }
                }, to: "https://www.form-fighter.com/api/upload",
                   headers: headers)
                .uploadProgress { progress in
                    print("Upload Progress: \(progress.fractionCompleted)")
                }
                .response { response in
                    if let error = response.error {
                        print("⚡️ Upload failed: \(error)")
                        continuation.resume(throwing: error)
                    } else {
                        print("⚡️ Upload success")
                        Task { @MainActor in
                            print("⚡️ Setting navigation state")
                            self.isUploading = false
                            self.feedbackId = feedbackId
                            print("⚡️ Switching to profile tab")
                            selectedTab = TabIdentifier.profile.rawValue
                            NotificationCenter.default.post(
                                name: NSNotification.Name("OpenFeedback"),
                                object: nil,
                                userInfo: ["feedbackId": feedbackId]
                            )
                            dismiss()  // Dismiss the camera flow
                        }
                        continuation.resume()
                    }
                }
            }
        } catch {
            print("⚡️ Upload error: \(error)")
            await MainActor.run {
                activeError = .uploadError(error)
                isUploading = false
            }
        }
    }
    
    private var uploadingView: some View {
        VStack(spacing: 20) {
            if isUploading {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding()
                Text("Uploading...")
            } else {
                Image(systemName: "figure.martial.arts")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                Text("Upload Complete!")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
