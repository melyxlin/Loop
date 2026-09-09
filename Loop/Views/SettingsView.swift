//
//  SettingsView.swift
//  LoopUI
//
//  Created by Rick Pasetto on 6/24/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import HealthKit
import LoopKit
import LoopKitUI
import MockKit
import SwiftUI
import LoopUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.dismissAction) private var dismiss
    @Environment(\.appName) private var appName
    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.carbTintColor) private var carbTintColor
    @Environment(\.glucoseTintColor) private var glucoseTintColor
    @Environment(\.insulinTintColor) private var insulinTintColor
    @Environment(\.isInvestigationalDevice) private var isInvestigationalDevice

    @State var viewModel: SettingsViewModel
    @ObservedObject var versionUpdateViewModel: VersionUpdateViewModel

    enum Destination {
        enum Alert: String, Identifiable {
            var id: String {
                rawValue
            }
            
            case deleteCGMData
            case deletePumpData
            case deleteAllTestingData
        }
        
        enum ActionSheet: String, Identifiable {
            var id: String {
                rawValue
            }
            
            case cgmPicker
            case pumpPicker
            case servicePicker
        }
        
        enum Sheet: String, Identifiable {
            var id: String {
                rawValue
            }
            
            case favoriteFoods
            case presets
            case profiles
        }
    }
    
    @State private var actionSheet: Destination.ActionSheet?
    @State private var alert: Destination.Alert?
    @State private var sheet: Destination.Sheet?
    @State private var showingPreferences = false
    @State private var searchText = ""
    
    var localizedAppNameAndVersion: String

    init(viewModel: SettingsViewModel, localizedAppNameAndVersion: String) {
        self.viewModel = viewModel
        self.versionUpdateViewModel = viewModel.versionUpdateViewModel
        self.localizedAppNameAndVersion = localizedAppNameAndVersion
    }
    
    public var body: some View {
        NavigationView {
            List {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Group {
                        loopSection
                        if versionUpdateViewModel.softwareUpdateAvailable {
                            softwareUpdateSection
                        }
                        if FeatureFlags.dosingStrategySelectionEnabled {
                            dosingStrategySection
                        }
                        alertManagementSection
                        statisticsSection
                        if viewModel.pumpManagerSettingsViewModel.isSetUp() {
                            therapySection
                        }
                        presetsSection
                        autoPresetsSection
                        bolusProSection
                        siteAtlasSection
                        foodFinderSection
                        deviceSettingsSection
                        healthAccessSection
                        if FeatureFlags.allowExperimentalFeatures {
                            favoriteFoodsSection
                        }
                        if FeatureFlags.allowExperimentalFeatures {
                            preferencesSection
                        }
                        if (viewModel.pumpManagerSettingsViewModel.isTestingDevice || viewModel.cgmManagerSettingsViewModel.isTestingDevice) && viewModel.showDeleteTestData {
                            deleteDataSection
                        }
                    }
                    Group {
                        if viewModel.servicesViewModel.showServices {
                            servicesSection
                        }
                        
                        // Catch-all for menu items without a dedicated section (e.g. .custom).
                        // .configuration items render in the configuration section and
                        // .support items in the Support section, so exclude both to avoid
                        // showing them twice.
                        ForEach(pluginMenuItems.filter({ $0.section != .support && $0.section != .configuration })) { item in
                            item.view
                        }
                        
                        supportSection
                        
                        if let profileExpiration = BuildDetails.default.profileExpiration, FeatureFlags.profileExpirationSettingsViewEnabled {
                            appExpirationSection(profileExpiration: profileExpiration)
                        }
                    }
                    }
                else {
                    searchResults
                }
            }
            .insetGroupedListStyle()
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(NSLocalizedString("Search Settings", comment: "Settings search field prompt"))
            )
            .navigationBarTitle(Text(NSLocalizedString("Settings", comment: "Settings screen title")))
            .navigationBarItems(trailing: dismissButton)
            .alert(item: $alert) { alert in
                switch alert {
                case .deleteCGMData:
                    return makeDeleteAlert(for: self.viewModel.cgmManagerSettingsViewModel)
                case .deletePumpData:
                    return makeDeleteAlert(for: self.viewModel.pumpManagerSettingsViewModel)
                case .deleteAllTestingData:
                    return SwiftUI.Alert(title: Text("Delete All Testing Data"),
                                         message: Text("Are you sure you want to delete all your testing Data?\n(This action is not reversible)"),
                                         primaryButton: .cancel(),
                                         secondaryButton: .destructive(Text("Delete"), action: viewModel.deleteAllTestingData))
                }
            }
            .sheet(item: $sheet) { sheet in
                Group {
                    switch sheet {
                    case .presets:
                        if let carbStore = viewModel.deviceManager?.carbStore, let doseStore = viewModel.deviceManager?.doseStore, let glucoseStore = viewModel.deviceManager?.glucoseStore {
                            PresetsView(
                                roundBasalRate: viewModel.deliveryDelegate?.roundBasalRate,
                                carbStore: carbStore,
                                doseStore: doseStore,
                                glucoseStore: glucoseStore,
                                trainingContent: viewModel.availableSupports.flatMap({ $0.trainingMedia(for: .presets) }),
                                automationHistory: { viewModel.delegate?.automationHistory ?? [] }
                            )
                        }
                    case .favoriteFoods:
                        FavoriteFoodsView(insightsDelegate: viewModel.favoriteFoodInsightsDelegate)
                    case .profiles:
                        ProfileView(viewModel: ProfileViewModel(therapySettings: self.viewModel.therapySettings(),
                                                                delegate: self.viewModel.therapySettingsViewModelDelegate))
                    }
                }
                .environmentObject(displayGlucosePreference)
                .environment(\.dismissAction, self.dismiss)
                .environment(\.appName, self.appName)
                .environment(\.chartColorPalette, .primary)
                .environment(\.carbTintColor, self.carbTintColor)
                .environment(\.glucoseTintColor, self.glucoseTintColor)
                .environment(\.guidanceColors, self.guidanceColors)
                .environment(\.insulinTintColor, self.insulinTintColor)
            }
        }
        .navigationViewStyle(.stack)
    }
    
    @ViewBuilder
    private var searchResults: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Closed Loop
        if matchesSearch(query, terms: [
            "closed loop", "loop", "automation", "insulin automation"
        ]) {
            loopSection
        }

        // Dosing Strategy
        if FeatureFlags.dosingStrategySelectionEnabled,
           matchesSearch(query, terms: [
               "dosing strategy", "automatic bolus", "temp basal",
               "automatic dosing"
           ])
        {
            dosingStrategySection
        }

        // Alert Management
        if matchesSearch(query, terms: [
            "alert management", "alerts", "notifications",
            "mute", "sounds", "permissions"
        ]) {
            alertManagementSearchSection
        }

        // Live Activity
        if matchesSearch(query, terms: [
            "live activity", "dynamic island",
            "lock screen", "carplay"
        ]) {
            liveActivitySearchSection
        }

        // Statistics
        if matchesSearch(query, terms: [
            "statistics", "stats", "agp", "tir",
            "time in range", "glucose", "gmi",
            "average", "variability", "cgm active"
        ]) {
            statisticsSection
        }

        // Therapy Settings
        if viewModel.pumpManagerSettingsViewModel.isSetUp(),
           matchesSearch(query, terms: [
               "therapy", "therapy settings",
               "basal", "basal rates",
               "carb ratio", "carb ratios",
               "correction", "correction range",
               "sensitivity", "isf",
               "insulin model"
           ])
        {
            therapySearchSection
        }

        // Profiles
        if viewModel.pumpManagerSettingsViewModel.isSetUp(),
           matchesSearch(query, terms: [
               "profile", "profiles"
           ])
        {
            profilesSearchSection
        }

        // Plugin configuration items
        if viewModel.pumpManagerSettingsViewModel.isSetUp(),
           matchesSearch(query, terms: [
               "usage data", "usage data sharing",
               "data sharing", "configuration"
           ])
        {
            configurationSearchSection
        }

        // Algorithm Experiments
        if viewModel.pumpManagerSettingsViewModel.isSetUp(),
           FeatureFlags.allowAlgorithmExperiments,
           matchesSearch(query, terms: [
               "algorithm", "algorithm experiments",
               "experiments", "experimental"
           ])
        {
            algorithmExperimentsSection
        }

        // Presets
        if matchesSearch(query, terms: [
            "preset", "presets", "override", "overrides",
            "temporary settings", "temporary adjustment"
        ]) {
            presetsSection
        }

        // AutoPresets
        if matchesSearch(query, terms: [
            "autopresets", "auto presets", "automatic preset",
            "activity", "walking", "exercise",
            "location", "geofence", "calendar"
        ]) {
            autoPresetsSection
        }

        // BolusPro
        if matchesSearch(query, terms: [
            "boluspro", "bolus pro",
            "protein", "fat", "fpu",
            "extended meal", "long absorption"
        ]) {
            bolusProSection
        }

        // Site Atlas
        if matchesSearch(query, terms: [
            "site atlas", "siteatlas",
            "site rotation", "pump site",
            "sensor site"
        ]) {
            siteAtlasSection
        }

        // FoodFinder
        if matchesSearch(query, terms: [
            "foodfinder", "food finder",
            "food", "barcode", "ai",
            "openfoodfacts"
        ]) {
            foodFinderSection
        }

        // Pump
        if matchesSearch(query, terms: [
            "pump", "insulin pump", "pod", "omnipod"
        ]) {
            pumpSearchSection
        }

        // CGM
        if matchesSearch(query, terms: [
            "cgm", "continuous glucose monitor",
            "glucose monitor", "dexcom", "sensor"
        ]) {
            cgmSearchSection
        }

        // Apple Health
        if matchesSearch(query, terms: [
            "apple health", "healthkit", "health",
            "health data"
        ]) {
            healthAccessSection
        }

        // Favorite Foods
        if FeatureFlags.allowExperimentalFeatures,
           matchesSearch(query, terms: [
               "favorite food", "favorite foods",
               "favorites", "carb entry"
           ])
        {
            favoriteFoodsSection
        }

        // Preferences
        if FeatureFlags.allowExperimentalFeatures,
           matchesSearch(query, terms: [
               "preferences", "preference",
               "customize", "customization"
           ])
        {
            preferencesSection
        }

        // Testing data
        if (viewModel.pumpManagerSettingsViewModel.isTestingDevice ||
            viewModel.cgmManagerSettingsViewModel.isTestingDevice),
           viewModel.showDeleteTestData,
           matchesSearch(query, terms: [
               "delete", "delete testing data",
               "testing data", "delete pump",
               "delete cgm"
           ])
        {
            deleteDataSection
        }

        // Services
        if viewModel.servicesViewModel.showServices,
           matchesSearch(query, terms: [
               "service", "services", "add service"
           ])
        {
            servicesSection
        }

        // Support
        if matchesSearch(query, terms: [
            "support", "issue", "issue report",
            "bug", "bug report",
            "critical event", "critical event logs",
            "export logs", "logs",
            "version"
        ]) {
            supportSection
        }
    }

    private func matchesSearch(_ query: String, terms: [String]) -> Bool {
        guard !query.isEmpty else {
            return false
        }

        return terms.contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }
    
    private var liveActivitySearchSection: some View {
        Section {
            NavigationLink(destination: LiveActivityManagementView()) {
                LargeButton(
                    action: {},
                    includeArrow: false,
                    imageView: Image(systemName: "rectangle.on.rectangle")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30),
                    label: NSLocalizedString(
                        "Live Activity",
                        comment: "Live Activity settings button text"
                    ),
                    descriptiveText: NSLocalizedString(
                        "Lock Screen, Dynamic Island, and CarPlay display",
                        comment: "Live Activity settings descriptive text"
                    )
                )
            }
        }
    }
    
    private var alertManagementSearchSection: some View {
        Section {
            NavigationLink(
                destination: AlertManagementView(
                    checker: viewModel.alertPermissionsChecker,
                    alertMuter: viewModel.alertMuter,
                    glucoseAlertManager: viewModel.deviceManager?.glucoseAlertManager,
                    alertStore: viewModel.deviceManager?.alertManager?.alertStore
                )
            ) {
                LargeButton(
                    action: {},
                    includeArrow: false,
                    imageView: Image(systemName: "bell.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30),
                    secondaryImageView: alertWarning,
                    label: NSLocalizedString(
                        "Alert Management",
                        comment: "Alert Permissions button text"
                    ),
                    descriptiveText: NSLocalizedString(
                        "iOS Permissions and Mute All App Sounds",
                        comment: "Alert Permissions descriptive text"
                    )
                )
            }
        }
    }

    private var configurationSearchSection: some View {
        Section {
            ForEach(pluginMenuItems.filter { $0.section == .configuration }) { item in
                item.view
            }
        }
    }

    private var pumpSearchSection: some View {
        Section(header: SectionHeader(
            label: NSLocalizedString("Devices", comment: "")
        )) {
            pumpSection
                .accessibilityIdentifier("settingsViewInsulinPump")
        }
    }

    private var cgmSearchSection: some View {
        Section(header: SectionHeader(
            label: NSLocalizedString("Devices", comment: "")
        )) {
            cgmSection
                .accessibilityIdentifier("settingsViewCGM")
        }
    }
    
    private var profilesSearchSection: some View {
        Section {
            Button {
                sheet = .profiles
            } label: {
                HStack {
                    Image(systemName: "person.crop.circle")
                        .foregroundColor(.accentColor)
                        .frame(width: 30)

                    Text("Profiles")
                        .foregroundColor(.primary)
                }
            }
        }
    }

    private var therapySearchSection: some View {
        Section {
            NavigationLink(destination: therapySettingsView) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.accentColor)
                        .frame(width: 30)

                    Text("Therapy Settings")
                        .foregroundColor(.primary)
                }
            }
        }
    }

    private func menuItemsForSection(name: String) -> some View {
        Section(header: SectionHeader(label: name)) {
            ForEach(pluginMenuItems.filter {$0.section.customLocalizedTitle == name}) { item in
                item.view
            }
        }
    }

    private var closedLoopToggleState: Binding<Bool> {
        Binding(
            get: {
                if self.viewModel.isCGMInputPaused {
                    return false
                }

                return self.viewModel.closedLoopPreference
            },
            set: { newValue in
                guard !self.viewModel.isCGMInputPaused else {
                    return
                }

                self.viewModel.closedLoopPreference = newValue
            }
        )
    }
}

struct PluginMenuItem<Content: View>: Identifiable {
    var id: String {
        return pluginIdentifier + String(describing: offset)
    }

    let section: SettingsMenuSection
    let view: Content
    let pluginIdentifier: String
    let offset: Int
}

extension SettingsView {
        
    private var dismissButton: some View {
        Button(action: dismiss) {
            Text("Done").bold()
        }.accessibilityIdentifier("button_done")
    }
    
    private var loopSection: some View {
        Section(
            header: Group {
                if isInvestigationalDevice {
                    Text(Image(systemName: "exclamationmark.triangle.fill"))
                        .foregroundColor(guidanceColors.warning) +
                    Text(" ") +
                    Text("CAUTION - Investigational device. Limited by Federal (or United States) law to investigational use.")
                }
            }
            .font(.footnote)
            .textCase(nil)
            .foregroundColor(.primary)
            .padding(.bottom, 6)
        ) {
            ConfirmationToggle(
                isOn: closedLoopToggleState,
                confirmOn: false,
                alertTitle: NSLocalizedString("Are you sure you want to turn automation OFF?", comment: "Closed loop alert title"),
                alertBody: NSLocalizedString("Your pump and CGM will continue operating but the app will not make automatic adjustments. You will receive your scheduled basal rate(s).", comment: "Closed loop alert message"),
                confirmAction: .init(label: { Text("Yes, turn OFF") })
            ) {
                HStack(spacing: 12) {
                    LoopCircleView(
                        closedLoop: viewModel.automaticDosingEnabled,
                        freshness: viewModel.loopStatusCircleFreshness,
                        deviceIssue: viewModel.deviceIssue
                    )
                    .frame(width: 36, height: 36)
                    .padding(12)
                    
                    VStack(alignment: .leading) {
                        Text("Closed Loop", comment: "The title text for the looping enabled switch cell")
                        DescriptiveText(label: NSLocalizedString("Insulin Automation", comment: "Closed loop settings button descriptive text"))
                        if !viewModel.isOnboardingComplete {
                            DescriptiveText(
                                label: NSLocalizedString(
                                    "Closed Loop requires Setup to be Complete",
                                    comment: "The description text for the looping enabled switch cell when onboarding is not complete"
                                )
                            )
                        } else if viewModel.isCGMInputPaused {
                            DescriptiveText(
                                label: NSLocalizedString(
                                    "Closed Loop is unavailable while CGM input is paused.",
                                    comment: "Closed loop description while CGM input is paused"
                                )
                            )
                        } else if let closedLoopDescriptiveText = viewModel.closedLoopDescriptiveText {
                            DescriptiveText(label: closedLoopDescriptiveText)
                        }
                    }
                }
            }
            .accessibilityIdentifier("settingsViewClosedLoopToggle")
            .disabled(!viewModel.isOnboardingComplete || viewModel.isCGMInputPaused)
            .padding(.vertical)
        }
    }
    
    private var softwareUpdateSection: some View {
        Section(footer: Text(viewModel.versionUpdateViewModel.footer(appName: appName))) {
            NavigationLink(destination: viewModel.versionUpdateViewModel.softwareUpdateView) {
                HStack {
                    Text(NSLocalizedString("Software Update", comment: "Software update button link text"))
                    Spacer()
                    viewModel.versionUpdateViewModel.icon
                }
            }
        }
    }

    private var dosingStrategySection: some View {
        Section(header: SectionHeader(label: NSLocalizedString("Dosing Strategy", comment: "The title of the Dosing Strategy section in settings"))) {
            
            NavigationLink(destination: DosingStrategySelectionView(automaticDosingStrategy: $viewModel.automaticDosingStrategy))
            {
                HStack {
                    Text(viewModel.automaticDosingStrategy.title)
                }
            }
        }
    }
    
    @ViewBuilder
    private var alertWarning: some View {
        if viewModel.alertPermissionsChecker.showWarning || viewModel.alertPermissionsChecker.notificationCenterSettings.scheduledDeliveryEnabled {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.critical)
                .accessibilityIdentifier("settingsViewAlertManagementAlertWarning")
        } else if viewModel.alertMuter.configuration.shouldMute {
            Image(systemName: "speaker.slash.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(guidanceColors.critical)
                .padding(5)
        }
    }

    private var alertManagementSection: some View {
        Section {
            NavigationLink(destination: AlertManagementView(
                checker: viewModel.alertPermissionsChecker,
                alertMuter: viewModel.alertMuter,
                glucoseAlertManager: viewModel.deviceManager?.glucoseAlertManager,
                alertStore: viewModel.deviceManager?.alertManager?.alertStore
            )) {
                LargeButton(
                    action: {},
                    includeArrow: false,
                    imageView: Image(systemName: "bell.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30),
                    secondaryImageView: alertWarning,
                    label: NSLocalizedString("Alert Management", comment: "Alert Permissions button text"),
                    descriptiveText: NSLocalizedString("iOS Permissions and Mute All App Sounds", comment: "Alert Permissions descriptive text")
                )
                .accessibilityIdentifier("settingsViewAlertManagement")
            }
            NavigationLink(destination: LiveActivityManagementView()) {
                LargeButton(
                    action: {},
                    includeArrow: false,
                    imageView: Image(systemName: "rectangle.on.rectangle")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30),
                    label: NSLocalizedString("Live Activity", comment: "Live Activity settings button text"),
                    descriptiveText: NSLocalizedString("Lock Screen, Dynamic Island, and CarPlay display", comment: "Live Activity settings descriptive text")
                )
                .accessibilityIdentifier("settingsViewLiveActivity")
            }
        }
    }

    @ViewBuilder
    private var statisticsSection: some View {
        if let glucoseStore = viewModel.deviceManager?.glucoseStore {
            Section {
                NavigationLink(destination: StatisticsView(glucoseStore: glucoseStore)) {
                    LargeButton(
                        action: {},
                        includeArrow: false,
                        imageView: Image(systemName: "chart.xyaxis.line")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 30),
                        label: NSLocalizedString("Statistics", comment: "Statistics settings button text"),
                        descriptiveText: NSLocalizedString("Glucose overview and ambulatory glucose profile", comment: "Statistics settings descriptive text")
                    )
                    .accessibilityIdentifier("settingsViewStatistics")
                }
            }
        }
    }

    private func healthKitSharingStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        viewModel.deviceManager?.healthKitSharingStatus(for: type) ?? .notDetermined
    }

    @ViewBuilder
    private var healthAccessWarning: some View {
        let denied = healthKitSharingStatus(for: HealthKitSampleStore.glucoseType) == .sharingDenied
            || healthKitSharingStatus(for: HealthKitSampleStore.insulinQuantityType) == .sharingDenied
        if denied {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.critical)
                .accessibilityIdentifier("settingsViewHealthAccessWarning")
        }
    }

    private var healthAccessSection: some View {
        Section {
            NavigationLink(destination: HealthAccessView(
                glucoseSharingStatus: { healthKitSharingStatus(for: HealthKitSampleStore.glucoseType) },
                insulinSharingStatus: { healthKitSharingStatus(for: HealthKitSampleStore.insulinQuantityType) },
                carbSharingStatus: { healthKitSharingStatus(for: HealthKitSampleStore.carbType) }
            )) {
                LargeButton(
                    action: {},
                    includeArrow: false,
                    imageView: Image(systemName: "heart.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30),
                    secondaryImageView: healthAccessWarning,
                    label: NSLocalizedString("Apple Health", comment: "Apple Health settings button text"),
                    descriptiveText: NSLocalizedString("Glucose, Insulin, and Carb Data Access", comment: "Apple Health settings descriptive text")
                )
                .accessibilityIdentifier("settingsViewHealthAccess")
            }
        }
    }

    private var therapySettingsView: some View {
        TherapySettingsView(
            mode: .settings,
            viewModel: TherapySettingsViewModel(
                therapySettings: viewModel.therapySettings(),
                delegate: viewModel.therapySettingsViewModelDelegate
            )
        )
        .environmentObject(displayGlucosePreference)
        .environment(\.dismissAction, self.dismiss)
        .environment(\.appName, self.appName)
        .environment(\.chartColorPalette, .primary)
        .environment(\.carbTintColor, self.carbTintColor)
        .environment(\.glucoseTintColor, self.glucoseTintColor)
        .environment(\.guidanceColors, self.guidanceColors)
        .environment(\.insulinTintColor, self.insulinTintColor)
    }

    private var therapySection: some View {
        Section {
            NavigationLink(destination: therapySettingsView) {
                LargeButton(action: {},
                            includeArrow: false,
                            imageView: Image("Therapy Icon"),
                            label: NSLocalizedString("Therapy Settings", comment: "Title text for button to Therapy Settings"),
                            descriptiveText: NSLocalizedString("Diabetes Treatment", comment: "Descriptive text for Therapy Settings"))
                .accessibilityIdentifier("button_TherapySettings")
            }

            LargeButton(action: { sheet = .profiles },
                        includeArrow: true,
                        imageView: AnyView(Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 30, weight: .bold))),
                        label: NSLocalizedString("Profiles", comment: "Title text for button to Profiles"),
                        descriptiveText: NSLocalizedString("Switch between profiles for different scenarios", comment: "Descriptive text for Profiles"))
            ForEach(pluginMenuItems.filter {$0.section == .configuration}) { item in
                item.view
            }

            if FeatureFlags.allowAlgorithmExperiments {
                algorithmExperimentsSection
            }
        }
    }

    private var presetsSection: some View {
        Section {
            LargeButton(
                action: { sheet = .presets },
                includeArrow: true,
                imageView: Image("Presets Icon"),
                label: NSLocalizedString("Presets", comment: "Title text for button to Preset Settings"),
                descriptiveText: NSLocalizedString("Temporary Settings Adjustments", comment: "Descriptive text for Preset Settings")
            ).accessibilityIdentifier("button_Presets")
        }
    }
    
    private var autoPresetsSection: some View {
        Section {
            NavigationLink(destination: AutoPresets_SettingsView()) {
                LargeButton(
                    action: {},
                    includeArrow: false,
                    imageView: Image(systemName: "figure.walk.motion")
                        .font(.system(size: 30)),
                    label: NSLocalizedString(
                        "AutoPresets",
                        comment: "Title text for button to AutoPresets Settings"
                    ),
                    descriptiveText: NSLocalizedString(
                        "Automatically activate presets based on activity",
                        comment: "Descriptive text for AutoPresets Settings"
                    )
                )
            }
        }
    }
    
    private var bolusProSection: some View {
        Section {
            NavigationLink(destination: BolusPro_SettingsView()) {
                LargeButton(
                    action: {},
                    includeArrow: false,
                    imageView: Image(systemName: "drop.halffull")
                        .font(.system(size: 30)),
                    label: NSLocalizedString(
                        "BolusPro",
                        comment: "Title text for button to BolusPro Settings"
                    ),
                    descriptiveText: NSLocalizedString(
                        "Protein & fat-aware bolusing for long absorption meals",
                        comment: "Descriptive text for BolusPro Settings"
                    )
                )
            }
        }
    }
    
    private var siteAtlasSection: some View {
        Section {
            NavigationLink(destination: SiteAtlas_SettingsView()) {
                LargeButton(
                    action: {},
                    includeArrow: false,
                    imageView: Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 30)),
                    label: NSLocalizedString(
                        "Site Atlas",
                        comment: "Title text for button to Site Atlas Settings"
                    ),
                    descriptiveText: NSLocalizedString(
                        "Track pump & sensor site rotation",
                        comment: "Descriptive text for Site Atlas Settings"
                    )
                )
            }
        }
    }
    
    private var foodFinderSection: some View {
        Section {
            NavigationLink(destination: AISettingsView()) {
                LargeButton(
                    action: {},
                    includeArrow: false,
                    imageView: Image(systemName: "fork.knife")
                        .font(.system(size: 30)),
                    label: NSLocalizedString(
                        "FoodFinder",
                        comment: "Title text for button to FoodFinder Settings"
                    ),
                    descriptiveText: NSLocalizedString(
                        "Food search, barcode & AI settings",
                        comment: "Descriptive text for FoodFinder Settings"
                    )
                )
            }
        }
    }

    private var pluginMenuItems: [PluginMenuItem<some View>] {
        self.viewModel.availableSupports.flatMap { plugin in
            plugin.configurationMenuItems().enumerated().map { index, item in
                PluginMenuItem(section: item.section, view: item.view, pluginIdentifier: plugin.pluginIdentifier, offset: index)
            }
        }
    }

    private var deviceSettingsSection: some View {
        Section(header: SectionHeader(label: NSLocalizedString("Devices", comment: ""))) {
            pumpSection
                .accessibilityIdentifier("settingsViewInsulinPump")
            
            cgmSection
                .accessibilityIdentifier("settingsViewCGM")
        }
    }
    
    @ViewBuilder
    private var pumpSection: some View {
        if viewModel.pumpManagerSettingsViewModel.isSetUp() {
            LargeButton(action: self.viewModel.pumpManagerSettingsViewModel.didTap,
                        includeArrow: true,
                        imageView: deviceImage(uiImage: viewModel.pumpManagerSettingsViewModel.image()),
                        label: viewModel.pumpManagerSettingsViewModel.name(),
                        descriptiveText: NSLocalizedString("Insulin Pump", comment: "Descriptive text for Insulin Pump"))
        } else if viewModel.isOnboardingComplete {
            LargeButton(action: { actionSheet = .pumpPicker },
                        includeArrow: false,
                        imageView: plusImage,
                        label: NSLocalizedString("Add Pump", comment: "Title text for button to add pump device"),
                        descriptiveText: NSLocalizedString("Tap here to set up a pump", comment: "Descriptive text for button to add pump device"))
            .background(
                PluginPopover(
                    isPresented: pickerBinding(.pumpPicker),
                    title: NSLocalizedString("Add Pump", comment: "The title of the pump chooser in settings"),
                    actions: pumpChoices
                )
            )
        }
    }

    private func pickerBinding(_ destination: Destination.ActionSheet) -> Binding<Bool> {
        Binding(
            get: { actionSheet == destination },
            set: { isPresented in
                if !isPresented, actionSheet == destination {
                    actionSheet = nil
                }
            }
        )
    }

    private var pumpChoices: [PluginPopover.Action] {
        viewModel.pumpManagerSettingsViewModel.availableDevices.map { availableDevice in
            .init(title: availableDevice.localizedTitle) {
                self.viewModel.pumpManagerSettingsViewModel.didTapAdd(availableDevice)
            }
        }
    }

    @ViewBuilder
    private var cgmSection: some View {
        if viewModel.cgmManagerSettingsViewModel.isSetUp() {
            LargeButton(action: self.viewModel.cgmManagerSettingsViewModel.didTap,
                        includeArrow: true,
                        imageView: deviceImage(uiImage: viewModel.cgmManagerSettingsViewModel.image()),
                        label: viewModel.cgmManagerSettingsViewModel.name(),
                        descriptiveText: NSLocalizedString("Continuous Glucose Monitor", comment: "Descriptive text for Continuous Glucose Monitor"))

        } else {
            LargeButton(action: { actionSheet = .cgmPicker },
                        includeArrow: false,
                        imageView: plusImage,
                        label: NSLocalizedString("Add CGM", comment: "Title text for button to add CGM device"),
                        descriptiveText: NSLocalizedString("Tap here to set up a CGM", comment: "Descriptive text for button to add CGM device"))
            .background(
                PluginPopover(
                    isPresented: pickerBinding(.cgmPicker),
                    title: NSLocalizedString("Add CGM", comment: "The title of the CGM chooser in settings"),
                    actions: cgmChoices
                )
            )
        }
    }
    
    private var favoriteFoodsSection: some View {
        Section {
            LargeButton(action: { sheet = .favoriteFoods },
                        includeArrow: true,
                        imageView: Image("Favorite Foods Icon").renderingMode(.template).foregroundColor(carbTintColor),
                        label: "Favorite Foods",
                        descriptiveText: "Simplify Carb Entry")
        }
    }

    private var preferencesSection: some View {
        Section {
            LargeButton(action: { showingPreferences = true },
                        includeArrow: true,
                        imageView: Image(systemName: "gearshape.fill").font(.system(size: 30, weight: .bold)),
                        label: NSLocalizedString("Preferences", comment: "Title text for button to Preferences"),
                        descriptiveText: NSLocalizedString("Customize your Loop experience by adjusting additional settings", comment: "Descriptive text for Preferences"))
        }
        .sheet(isPresented: $showingPreferences) {
            PreferencesView(viewModel: PreferencesViewModel(preferencesProvider: Preferences.shared))
                .environmentObject(displayGlucosePreference)
                .environment(\.dismissAction, { showingPreferences = false })
        }
    }

    private var cgmChoices: [PluginPopover.Action] {
        viewModel.cgmManagerSettingsViewModel.availableDevices
            .sorted(by: {$0.localizedTitle < $1.localizedTitle})
            .map { availableDevice in
                .init(title: availableDevice.localizedTitle) {
                    self.viewModel.cgmManagerSettingsViewModel.didTapAdd(availableDevice)
                }
            }
    }

    private var servicesSection: some View {
        Section(header: SectionHeader(label: NSLocalizedString("Services", comment: "The title of the services section in settings"))) {
            ForEach(viewModel.servicesViewModel.activeServices().indices, id: \.self) { index in
                LargeButton(action: { self.viewModel.servicesViewModel.didTapService(index) },
                            includeArrow: true,
                            imageView: self.serviceImage(uiImage: (self.viewModel.servicesViewModel.activeServices()[index] as? ServiceUI)?.image),
                            label: self.viewModel.servicesViewModel.activeServices()[index].localizedTitle,
                            descriptiveText: "")
            }
            if viewModel.servicesViewModel.inactiveServices().count > 0 {
                LargeButton(action: { actionSheet = .servicePicker },
                            includeArrow: false,
                            imageView: plusImage,
                            label: NSLocalizedString("Add Service", comment: "The title of the add service button in settings"),
                            descriptiveText: NSLocalizedString("Tap here to set up a Service", comment: "The descriptive text of the add service button in settings"))
                .background(
                    PluginPopover(
                        isPresented: pickerBinding(.servicePicker),
                        title: NSLocalizedString("Add Service", comment: "The title of the add service action sheet in settings"),
                        actions: serviceChoices
                    )
                )
            }
        }
    }

    private var serviceChoices: [PluginPopover.Action] {
        viewModel.servicesViewModel.inactiveServices().map { availableService in
            .init(title: availableService.localizedTitle) {
                self.viewModel.servicesViewModel.didTapAddService(availableService)
            }
        }
    }

    private var deleteDataSection: some View {
        Section {
            if viewModel.pumpManagerSettingsViewModel.isTestingDevice {
                Button(action: { alert = .deletePumpData }) {
                    HStack {
                        Spacer()
                        Text("Delete Testing Pump Data").accentColor(.destructive)
                        Spacer()
                    }
                }
            }
            if viewModel.cgmManagerSettingsViewModel.isTestingDevice {
                Button(action: { alert = .deleteCGMData }) {
                    HStack {
                        Spacer()
                        Text("Delete Testing CGM Data").accentColor(.destructive)
                        Spacer()
                    }
                }
            }
            if viewModel.cgmManagerSettingsViewModel.isTestingDevice,
               viewModel.pumpManagerSettingsViewModel.isTestingDevice
            {
                Button(action: { alert = .deleteAllTestingData }) {
                    HStack {
                        Spacer()
                        Text("Delete All Testing Data").accentColor(.destructive)
                        Spacer()
                    }
                }
            }
        }
    }
    
    private func makeDeleteAlert<T>(for model: DeviceViewModel<T>) -> SwiftUI.Alert {
        return SwiftUI.Alert(title: Text("Delete Testing Data"),
                             message: Text("Are you sure you want to delete all your \(model.name()) Data?\n(This action is not reversible)", comment: "Confirmation before you delete all your Simulated Test Devices data"),
                             primaryButton: .cancel(),
                             secondaryButton: .destructive(Text("Delete"), action: model.deleteTestingDataFunc()))
    }
    
    private var supportSection: some View {
        Section(header: SectionHeader(label: NSLocalizedString("Support", comment: "The title of the support section in settings"))) {
            Button(action: {
                self.viewModel.didTapIssueReport()
            }) {
                Text("Issue Report", comment: "The title text for the issue report menu item")
            }

            ForEach(pluginMenuItems.filter( { $0.section == .support })) {
                $0.view
            }

            NavigationLink(destination: CriticalEventLogExportView(viewModel: viewModel.criticalEventLogExportViewModel)) {
                Text(NSLocalizedString("Export Critical Event Logs", comment: "The title of the export critical event logs in support"))
            }

            HStack {
                Text(NSLocalizedString("Version", comment: "Label for the app version row in the Support section"))
                Spacer()
                Text(localizedAppNameAndVersion)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    /*
     DIY loop specific component to show users the amount of time remaining on their build before a rebuild is necessary.
     */
    private func appExpirationSection(profileExpiration: Date) -> some View {
        let expirationDate = AppExpirationAlerter.calculateExpirationDate(profileExpiration: profileExpiration)
        let isTestFlight = AppExpirationAlerter.isTestFlightBuild()
        let nearExpiration = AppExpirationAlerter.isNearExpiration(expirationDate: expirationDate)
        let profileExpirationMsg = AppExpirationAlerter.createProfileExpirationSettingsMessage(expirationDate: expirationDate)
        let readableExpirationTime = Self.dateFormatter.string(from: expirationDate)
        
        if isTestFlight {
            return createAppExpirationSection(
                headerLabel: NSLocalizedString("TestFlight", comment: "Settings app TestFlight section"),
                footerLabel: NSLocalizedString("TestFlight expires ", comment: "Time that build expires") + readableExpirationTime,
                expirationLabel: NSLocalizedString("TestFlight Expiration", comment: "Settings TestFlight expiration view"),
                updateURL: "https://loopkit.github.io/loopdocs/gh-actions/gh-update/",
                nearExpiration: nearExpiration,
                expirationMessage: profileExpirationMsg
            )
        } else {
            return createAppExpirationSection(
                headerLabel: NSLocalizedString("App Profile", comment: "Settings app profile section"),
                footerLabel: NSLocalizedString("Profile expires ", comment: "Time that profile expires") + readableExpirationTime,
                expirationLabel: NSLocalizedString("Profile Expiration", comment: "Settings App Profile expiration view"),
                updateURL: "https://loopkit.github.io/loopdocs/build/updating/",
                nearExpiration: nearExpiration,
                expirationMessage: profileExpirationMsg
            )
        }
    }
    
    private func createAppExpirationSection(headerLabel: String, footerLabel: String, expirationLabel: String, updateURL: String, nearExpiration: Bool, expirationMessage: String) -> some View {
        return Section(
            header: SectionHeader(label: headerLabel),
            footer: Text(footerLabel)
        ) {
            if nearExpiration {
                Text(expirationMessage).foregroundColor(.red)
            } else {
                HStack {
                    Text(expirationLabel)
                    Spacer()
                    Text(expirationMessage).foregroundColor(Color.secondary)
                }
            }
            Button(action: {
                UIApplication.shared.open(URL(string: updateURL)!)
            }) {
                Text(NSLocalizedString("How to update (LoopDocs)", comment: "The title text for how to update"))
            }
        }
    }

    private static var dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        return dateFormatter // formats date like "February 4, 2023 at 2:35 PM"
    }()

    private var plusImage: some View {
        Image(systemName: "plus.circle")
            .resizable()
            .scaledToFit()
            .accentColor(Color(.systemGray))
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
    }
    
    @ViewBuilder
    private func deviceImage(uiImage: UIImage?) -> some View {
        if let uiImage = uiImage {
            Image(uiImage: uiImage)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
        } else {
            Spacer()
        }
    }
    
    @ViewBuilder
    private func serviceImage(uiImage: UIImage?) -> some View {
        deviceImage(uiImage: uiImage)
    }
}  // end extension SettingsView

// MARK: - LargeButton

fileprivate struct LargeButton<Content: View, SecondaryContent: View>: View {
    
    let action: () -> Void
    var includeArrow: Bool
    let imageView: Content
    let secondaryImageView: SecondaryContent
    let label: String
    let descriptiveText: String
    
    init(
        action: @escaping () -> Void,
        includeArrow: Bool = true,
        imageView: Content,
        secondaryImageView: SecondaryContent = EmptyView(),
        label: String,
        descriptiveText: String
    ) {
        self.action = action
        self.includeArrow = includeArrow
        self.imageView = imageView
        self.secondaryImageView = secondaryImageView
        self.label = label
        self.descriptiveText = descriptiveText
    }

    // TODO: The design doesn't show this, but do we need to consider different values here for different size classes?
    private let spacing: CGFloat = 15
    private let imageWidth: CGFloat = 60
    private let imageHeight: CGFloat = 60
    private let secondaryImageWidth: CGFloat = 30
    private let secondaryImageHeight: CGFloat = 30
    private let topBottomPadding: CGFloat = 10
    
    public var body: some View {
        Button(action: action) {
            HStack {
                HStack(spacing: spacing) {
                    imageView.frame(maxWidth: imageWidth, maxHeight: imageHeight)
                    VStack(alignment: .leading) {
                        Text(label)
                            .foregroundColor(.primary)
                        DescriptiveText(label: descriptiveText)
                    }
                }
                
                if !(secondaryImageView is EmptyView) || includeArrow {
                    Spacer()
                }
                
                if !(secondaryImageView is EmptyView) {
                    secondaryImageView.frame(width: secondaryImageWidth, height: secondaryImageHeight)
                }
                
                if includeArrow {
                    // TODO: Ick. I can't use a NavigationLink because we're not Navigating, but this seems worse somehow.
                    Image(systemName: "chevron.right").foregroundColor(.gray).font(.footnote)
                }
            }
            .padding(EdgeInsets(top: topBottomPadding, leading: 0, bottom: topBottomPadding, trailing: 0))
        }
    }
}

/// Presents the plugin chooser as a UIKit action sheet anchored to the tapped row.
///
/// A SwiftUI `.actionSheet`/`.confirmationDialog` presented from a `List` row breaks
/// under the Liquid Glass design, so the sheet is presented from a hosted
/// `UIViewController` positioned behind the row instead.
struct PluginPopover: UIViewControllerRepresentable {
    struct Action {
        let title: String
        let handler: () -> Void
    }

    @Binding var isPresented: Bool
    let title: String
    let actions: [Action]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let coordinator = context.coordinator

        if !isPresented {
            coordinator.didPresent = false
            return
        }

        guard !coordinator.didPresent else { return }
        guard uiViewController.presentedViewController == nil else { return }

        coordinator.didPresent = true
        coordinator.onDismiss = { self.isPresented = false }

        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for action in actions {
            alert.addAction(UIAlertAction(title: action.title, style: .default) { _ in
                self.isPresented = false
                action.handler()
            })
        }

        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Cancel", comment: "The title of the cancel action in an action sheet"),
            style: .destructive
        ) { _ in
            self.isPresented = false
        })

        if let popover = alert.popoverPresentationController {
            popover.sourceView = uiViewController.view
            popover.sourceRect = uiViewController.view.bounds
            popover.delegate = coordinator
        }

        uiViewController.present(alert, animated: true)
    }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var didPresent = false
        var onDismiss: (() -> Void)?

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onDismiss?()
        }
    }
}

public struct SettingsView_Previews: PreviewProvider {
        
    public static var previews: some View {
        let displayGlucosePreference = DisplayGlucosePreference(displayGlucoseUnit: .milligramsPerDeciliter)
        let viewModel = SettingsViewModel.preview
        return Group {
            SettingsView(viewModel: viewModel, localizedAppNameAndVersion: "Loop Demo V1")
                .colorScheme(.light)
                .previewDevice(PreviewDevice(rawValue: "iPhone SE 2"))
                .previewDisplayName("SE light")
                .environmentObject(displayGlucosePreference)
            
            SettingsView(viewModel: viewModel, localizedAppNameAndVersion: "Loop Demo V1")
                .colorScheme(.dark)
                .previewDevice(PreviewDevice(rawValue: "iPhone 11 Pro Max"))
                .previewDisplayName("11 Pro dark")
                .environmentObject(displayGlucosePreference)
        }
    }
}
