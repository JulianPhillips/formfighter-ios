import SwiftUI
import Firebase
import FirebaseAnalytics
import FirebaseCore
import WishKit
import TipKit
import FirebaseFirestore
import FirebaseMessaging

@main
struct FormFighterApp: App {
    
    // MARK: We store in UserDefaults wether the user completed the onboarding and the chosen GPT language.
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("gptLanguage") var gptLanguage: GPTLanguage = .english
    @AppStorage("systemThemeValue") var systemTheme: Int = ColorSchemeType.allCases.first?.rawValue ?? 0
    
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.colorScheme) var colorScheme
    
    @StateObject var purchasesManager = PurchasesManager.shared
    @StateObject var authManager = AuthManager()
    @StateObject var userManager = UserManager.shared
    @State private var pendingCoachId: String?
    @State private var showCoachConfirmation = false
    @State private var showSplash = true
    @State private var selectedTab: TabIdentifier = .profile
    
    let cameraManager = CameraManager() // Create an instance of CameraManager
    
    private var db: Firestore!
    
    // Add class-level delegate
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    init() {
        setupFirebase()
        db = Firestore.firestore()
        setupWishKit()
        setupTips()
//        debugActions()
        
        // Force solid navigation bar appearance
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(ThemeColors.background)
        appearance.shadowColor = .clear
        
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().tintColor = UIColor(ThemeColors.primary)
        
        setupCrashlytics()
    }
    
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ZStack {
                    Group {
                        if !hasCompletedOnboarding {
                            onboarding
                        } else if !userManager.isAuthenticated {
                            LoginView(showPaywallInTheOnboarding: false)
                        } else if userManager.isAuthenticated && purchasesManager.isSubscribed {
                            TabView(selection: $selectedTab) {
                                VisionView()
                                    .tabItem { 
                                        Label("Train", systemImage: "figure.boxing")
                                            .foregroundStyle(ThemeColors.primary)
                                    }
                                    .toolbarBackground(.visible, for: .navigationBar)
                                    .toolbarBackground(ThemeColors.background, for: .navigationBar)
                                    .navigationBarTitleDisplayMode(.inline)
                                    .toolbar {
                                        ToolbarItem(placement: .principal) {
                                            Text("Train")
                                                .font(.headline)
                                                .foregroundColor(ThemeColors.primary)
                                        }
                                    }
                                    .tag(TabIdentifier.vision)
                               
                                ProfileView()
                                    .tabItem { 
                                        Label("Progress", systemImage: "chart.line.uptrend.xyaxis")
                                            .foregroundStyle(ThemeColors.primary)
                                    }
                                    .tag(TabIdentifier.profile)

                                SettingsView(vm: SettingsVM())
                                    .tabItem { 
                                        Label("Settings", systemImage: "gearshape.fill")
                                            .foregroundStyle(ThemeColors.primary)
                                    }
                                    .tag(TabIdentifier.settings)
                            }
                            .tint(ThemeColors.primary)
                            .background(ThemeColors.background)
                            .toolbarBackground(.visible, for: .tabBar)
                            .toolbarBackground(ThemeColors.background, for: .tabBar)
                        } else {
                            PaywallView()
                        }
                    }
                    .opacity(showSplash ? 0 : 1)
                    
                    if showSplash {
                        SplashScreenView()
                            .transition(.opacity)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    withAnimation(.easeOut(duration: 0.3)) {
                                        showSplash = false
                                    }
                                }
                            }
                    }
                }
                .preferredColorScheme(selectedScheme)
                .environmentObject(purchasesManager)
                .environmentObject(authManager)
                .environmentObject(userManager)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .alert("Join Team", isPresented: $showCoachConfirmation) {
                    Button("Cancel", role: .cancel) {
                        pendingCoachId = nil
                    }
                    Button("Join") {
                        assignCoach()
                    }
                } message: {
                    if let coachId = pendingCoachId {
                        Text("Would you like to join Coach \(coachId)'s team?")
                    }
                }
                .onChange(of: scenePhase) { newScenePhase in
                    switch newScenePhase {
                    case .active:
                    //    purchasesManager.fetchCustomerInfo()
                        userManager.setAuthenticationState()
                    default:
                        break
                    }
                }
                .onAppear {
                    Tracker.appOpened()
                    Tracker.appSessionBegan()
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .background {
                        Tracker.appSessionEnded()
                    }
                }
            }
            .environment(\.tabSelection, $selectedTab)
        }
    }
    
    var onboarding: some View {
        NavigationStack {
            // MARK: - You can change the type of onboarding you want commenting and uncommenting the views.
             //MultiplePagesOnboardingView()
            OnePageOnboardingView()
        }
    }
    
    var selectedScheme: ColorScheme? {
        guard let theme = ColorSchemeType(rawValue: systemTheme) else { return nil}
        switch theme {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
    
    // MARK: Uncomment this method in init() to execute utility actions while developing your app.
    // For example, resetting the onboarding state, deleting free credits from the keychain, etc
    // Feel free to add or comment as many as you need.
    private func debugActions() {
        #if DEBUG
//        KeychainManager.shared.deleteFreeExtraCredits()
//        KeychainManager.shared.setFreeCredits(with: Const.freeCredits)
//        KeychainManager.shared.deleteAuthToken()
//        hasCompletedOnboarding = false
        
        if #available(iOS 17.0, *) {
            // This forces all Tips to show up in every single execution.
            Tips.showAllTipsForTesting()
        }
        
        #endif
    }
    
    private func setupFirebase() {
        // Only configure Firebase once
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
            
            // Configure analytics and crashlytics
            #if DEBUG
                Analytics.setAnalyticsCollectionEnabled(false)
                Logger.log(message: "Analytics disabled in DEBUG mode", event: .debug)
            #else
                Analytics.setAnalyticsCollectionEnabled(!isTestFlight())
                Logger.log(message: "Analytics enabled in RELEASE mode", event: .debug)
            #endif
            
            // Configure Crashlytics
            Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
            
            // Configure Messaging
            Messaging.messaging().isAutoInitEnabled = true
        }
    }
    
    // Customer Feedback Support.
    // https://github.com/wishkit/wishkit-iosse
    private func setupWishKit() {
        WishKit.configure(with: Const.WishKit.key)
        
        // Show the status badge of a feature request (e.g. pending, approved, etc.).
        WishKit.config.statusBadge = .show

        // Shows full description of a feature request in the list.
        WishKit.config.expandDescriptionInList = true

        // Hide the segmented control.
        WishKit.config.buttons.segmentedControl.display = .hide

        // Remove drop shadow.
        WishKit.config.dropShadow = .hide

        // Hide comment section
        WishKit.config.commentSection = .hide

        // Position the Add-Button.
        WishKit.config.buttons.addButton.bottomPadding = .large

        // This is for the Add-Button, Segmented Control, and Vote-Button.
        WishKit.theme.primaryColor = .brand

        // Set the secondary color (this is for the cells and text fields).
        WishKit.theme.secondaryColor = .set(light: .brand.opacity(0.1), dark: .brand.opacity(0.05))

        // Set the tertiary color (this is for the background).
        WishKit.theme.tertiaryColor = .setBoth(to: .customBackground)

        // Segmented Control (Text color)
        WishKit.config.buttons.segmentedControl.defaultTextColor = .setBoth(to: .white)

        WishKit.config.buttons.segmentedControl.activeTextColor = .setBoth(to: .white)

        // Save Button (Text color)
        WishKit.config.buttons.saveButton.textColor = .set(light: .white, dark: .white)

    }
    
    // Check this nice tutorial for more Tip configurations:
    // https://asynclearn.medium.com/suggesting-features-to-users-with-tipkit-8128178d6114
    private func setupTips() {
        if #available(iOS 17, *) {
            try? Tips.configure([
                .displayFrequency(.immediate)
              ])
        }
    }
    
    private func isTestFlight() -> Bool {
        guard let appStoreReceiptURL = Bundle.main.appStoreReceiptURL else {
            return false
        }
        
        return appStoreReceiptURL.lastPathComponent == "sandboxReceipt"
    }
    
    private func handleDeepLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems,
              let coachId = queryItems.first(where: { $0.name == "coach" })?.value else { 
            return 
        }
        
        checkAndPromptForCoach(coachId: coachId)
    }
    
    private func checkAndPromptForCoach(coachId: String) {
        var userId = ""
        if userManager.userId.isEmpty { return } else {
            userId = userManager.userId
        }
        
        db.collection("users").document(userId).getDocument { document, error in
            guard let document = document,
                  document.exists,
                  let data = document.data(),
                  let existingCoach = data["myCoach"] as? String? else {
                return
            }
            
            if let existingCoach = existingCoach {
                print("User already has a coach: \(existingCoach)")
                return
            }
            
            db.collection("users").document(coachId).getDocument { coachDoc, error in
                guard let coachDoc = coachDoc,
                      coachDoc.exists,
                      let _ = coachDoc.data() else {
                    print("Coach not found or error: \(error?.localizedDescription ?? "unknown error")")
                    return
                }
                
                pendingCoachId = coachId
                showCoachConfirmation = true
            }
        }
    }
    
    private func assignCoach() {
        guard let coachId = pendingCoachId else {return}
            
    var userId = ""
    if userManager.userId.isEmpty { return } else {
                    userId = userManager.userId
                }
                
            
        
        db.collection("users").document(userId).setData([
            "myCoach": coachId
        ], merge: true) { error in
            if let error = error {
                print("Error assigning coach: \(error.localizedDescription)")
            } else {
                print("Coach assigned successfully")
                pendingCoachId = nil
            }
        }
    }
    
    private func logScreenView(_ screenName: String) {
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: screenName,
            AnalyticsParameterScreenClass: "FormFighterApp"
        ])
    }
    
    func setupCrashlytics() {
        Crashlytics.crashlytics().setCustomValue(UIDevice.current.systemVersion, forKey: "ios_version")
        Crashlytics.crashlytics().setCustomValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", forKey: "app_version")
    }
}
