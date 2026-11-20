//
//  ServicesManager.swift
//  Loop
//
//  Created by Darin Krauss on 5/22/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import os.log
import LoopKit
import LoopKitUI
import LoopCore
import Combine

@MainActor
class ServicesManager {

    private let pluginManager: PluginManager

    private let alertManager: AlertManager

    let analyticsServicesManager: AnalyticsServicesManager

    let loggingServicesManager: LoggingServicesManager

    let remoteDataServicesManager: RemoteDataServicesManager
    
    let settingsManager: SettingsManager
    
    weak var servicesManagerDelegate: ServicesManagerDelegate?
    weak var servicesManagerDosingDelegate: ServicesManagerDosingDelegate?
    weak var supportManager: SupportManager?
    weak var therapySettingsViewModelDelegate: TherapySettingsViewModelDelegate?
    
    private var services = [Service]()

    private let servicesLock = UnfairLock()

    private let log = OSLog(category: "ServicesManager")
    
    lazy private var cancellables = Set<AnyCancellable>()

    @PersistedProperty(key: "Services")
    var rawServices: [Service.RawValue]?

    init(
        pluginManager: PluginManager,
        alertManager: AlertManager,
        analyticsServicesManager: AnalyticsServicesManager,
        loggingServicesManager: LoggingServicesManager,
        remoteDataServicesManager: RemoteDataServicesManager,
        settingsManager: SettingsManager,
        servicesManagerDelegate: ServicesManagerDelegate,
        servicesManagerDosingDelegate: ServicesManagerDosingDelegate
    ) {
        self.pluginManager = pluginManager
        self.alertManager = alertManager
        self.analyticsServicesManager = analyticsServicesManager
        self.loggingServicesManager = loggingServicesManager
        self.remoteDataServicesManager = remoteDataServicesManager
        self.settingsManager = settingsManager
        self.servicesManagerDelegate = servicesManagerDelegate
        self.servicesManagerDosingDelegate = servicesManagerDosingDelegate
        restoreState()
    }

    public var availableServices: [ServiceDescriptor] {
        return pluginManager.availableServices + availableStaticServices
    }

    func setupService(withIdentifier identifier: String) -> Swift.Result<SetupUIResult<ServiceViewController, Service>, Error> {
        switch setupServiceUI(withIdentifier: identifier) {
        case .failure(let error):
            return .failure(error)
        case .success(let success):
            switch success {
            case .userInteractionRequired(let viewController):
                return .success(.userInteractionRequired(viewController))
            case .createdAndOnboarded(let serviceUI):
                return .success(.createdAndOnboarded(serviceUI))
            }
        }
    }

    struct UnknownServiceIdentifierError: Error {}
    
    fileprivate func setupServiceUI(withIdentifier identifier: String) -> Swift.Result<SetupUIResult<ServiceViewController, ServiceUI>, Error> {
        guard let serviceUIType = serviceUITypeByIdentifier(identifier) else {
            return .failure(UnknownServiceIdentifierError())
        }

        let result = serviceUIType.setupViewController(colorPalette: .default, pluginHost: self, allowDebugFeatures: FeatureFlags.allowDebugFeatures)
        if case .createdAndOnboarded(let serviceUI) = result {
            serviceOnboarding(didCreateService: serviceUI)
            serviceOnboarding(didOnboardService: serviceUI)
        }

        return .success(result)
    }

    func serviceUITypeByIdentifier(_ identifier: String) -> ServiceUI.Type? {
        return pluginManager.getServiceTypeByIdentifier(identifier) ?? staticServicesByIdentifier[identifier] as? ServiceUI.Type
    }

    private func serviceTypeFromRawValue(_ rawValue: Service.RawStateValue) -> Service.Type? {
        guard let identifier = rawValue["serviceIdentifier"] as? String else {
            return nil
        }

        return serviceUITypeByIdentifier(identifier)
    }

    private func serviceFromRawValue(_ rawValue: Service.RawStateValue) -> Service? {
        guard let serviceType = serviceTypeFromRawValue(rawValue),
            let rawState = rawValue["state"] as? Service.RawStateValue
            else {
                return nil
        }

        return serviceType.init(rawState: rawState)
    }

    public var activeServices: [Service] {
        return servicesLock.withLock { services }
    }

    public func getServices() -> [Service] {
        return servicesLock.withLock { services }
    }

    public func addActiveService(_ service: Service) {
        servicesLock.withLock {
            service.serviceDelegate = self
            service.stateDelegate = self

            services.append(service)

            if let analyticsService = service as? AnalyticsService {
                analyticsServicesManager.addService(analyticsService)
            }
            if let loggingService = service as? LoggingService {
                loggingServicesManager.addService(loggingService)
            }
            if let remoteDataService = service as? RemoteDataService {
                remoteDataServicesManager.addService(remoteDataService)
            }
            if let provider = service as? SupportProviding {
                supportManager?.addSupport(provider.createSupport())
            }

            saveState()
        }
    }

    public func removeActiveService(_ service: Service) {
        servicesLock.withLock {
            if let provider = service as? SupportProviding {
                supportManager?.removeSupport(provider.createSupport())
            }
            if let remoteDataService = service as? RemoteDataService {
                remoteDataServicesManager.removeService(remoteDataService)
            }
            if let loggingService = service as? LoggingService {
                loggingServicesManager.removeService(loggingService)
            }
            if let analyticsService = service as? AnalyticsService {
                analyticsServicesManager.removeService(analyticsService)
            }

            services.removeAll { $0.pluginIdentifier == service.pluginIdentifier }

            service.serviceDelegate = nil
            service.stateDelegate = nil

            saveState()
        }
    }

    private func saveState() {
        rawServices = services.compactMap { $0.rawValue }
        UserDefaults.appGroup?.clearLegacyServicesState()
    }

    private func restoreState() {
        let rawServices = rawServices ?? UserDefaults.appGroup?.legacyServicesState ?? []
        rawServices.forEach { rawValue in
            if let service = serviceFromRawValue(rawValue) {
                service.serviceDelegate = self
                service.stateDelegate = self

                services.append(service)

                if let analyticsService = service as? AnalyticsService {
                    analyticsServicesManager.restoreService(analyticsService)
                }
                if let loggingService = service as? LoggingService {
                    loggingServicesManager.restoreService(loggingService)
                }
                if let remoteDataService = service as? RemoteDataService {
                    remoteDataServicesManager.restoreService(remoteDataService)
                }
            }
        }
    }
    
    func handleRemoteNotification(_ notification: [String: AnyObject]) {
        Task {
            log.default("Remote Notification: Handling notification %{public}@", notification)
            
            guard FeatureFlags.remoteCommandsEnabled else {
                log.error("Remote Notification: Remote Commands not enabled.")
                return
            }
            
            let backgroundTask = await beginBackgroundTask(name: "Handle Remote Notification")
            do {
                try await remoteDataServicesManager.remoteNotificationWasReceived(notification)
            } catch {
                log.error("Remote Notification: Error: %{public}@", String(describing: error))
            }
            
            await endBackgroundTask(backgroundTask)
            log.default("Remote Notification: Finished handling")
        }
    }
    
    private func beginBackgroundTask(name: String) async -> UIBackgroundTaskIdentifier? {
        var backgroundTask: UIBackgroundTaskIdentifier?
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) {
            guard let backgroundTask = backgroundTask else {return}
            Task {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
            
            self.log.error("Background Task Expired: %{public}@", name)
        }
        
        return backgroundTask
    }
    
    private func endBackgroundTask(_ backgroundTask: UIBackgroundTaskIdentifier?) async {
        guard let backgroundTask else {return}
        UIApplication.shared.endBackgroundTask(backgroundTask)
    }
}

public protocol ServicesManagerDosingDelegate: AnyObject {
    func deliverBolus(amountInUnits: Double, decisionId: UUID?, request: DoseMetadata.RemoteRequest?) async throws
}

public protocol ServicesManagerDelegate: AnyObject {
    func enactOverride(name: String, duration: TemporaryScheduleOverride.Duration?, remoteAddress: String) async throws
    func cancelCurrentOverride() async throws
    func deliverCarbs(amountInGrams: Double, absorptionTime: TimeInterval?, foodType: String?, startDate: Date?) async throws
}

// MARK: - StatefulPluggableDelegate
extension ServicesManager: StatefulPluggableDelegate {
    func pluginDidUpdateState(_ plugin: StatefulPluggable) {
        saveState()
    }

    func pluginWantsDeletion(_ plugin: StatefulPluggable) {
        guard let service = plugin as? Service else { return }
        log.default("Service with identifier '%{public}@' deleted", service.pluginIdentifier)
        removeActiveService(service)
    }
}

// MARK: - PluginHost
extension ServicesManager: PluginHost {
    nonisolated var hostIdentifier: String {
        return Bundle.main.hostIdentifier
    }

    nonisolated var hostVersion: String {
        return Bundle.main.hostVersion
    }
}

// MARK: - ServiceDelegate

extension ServicesManager: ServiceDelegate {
    func enactRemoteOverride(name: String, durationTime: TimeInterval?, remoteAddress: String) async throws {
        
        var duration: TemporaryScheduleOverride.Duration? = nil
        if let durationTime = durationTime {
            
            guard durationTime <= LoopConstants.maxOverrideDurationTime else {
                throw OverrideActionError.durationExceedsMax(LoopConstants.maxOverrideDurationTime)
            }
            
            guard durationTime >= 0 else {
                throw OverrideActionError.negativeDuration
            }
            
            if durationTime == 0 {
                duration = .indefinite
            } else {
                duration = .finite(durationTime)
            }
        }
        
        try await servicesManagerDelegate?.enactOverride(name: name, duration: duration, remoteAddress: remoteAddress)
        await remoteDataServicesManager.performUpload(for: .overrides)
    }
    
    enum OverrideActionError: LocalizedError {
        
        case durationExceedsMax(TimeInterval)
        case negativeDuration
        
        var errorDescription: String? {
            switch self {
            case .durationExceedsMax(let maxDurationTime):
                return String(format: NSLocalizedString("Duration exceeds: %1$.1f hours", comment: "Override error description: duration exceed max (1: max duration in hours)."), maxDurationTime.hours)
            case .negativeDuration:
                return String(format: NSLocalizedString("Negative duration not allowed", comment: "Override error description: negative duration error."))
            }
        }
    }
    
    func cancelRemoteOverride() async throws {
        try await servicesManagerDelegate?.cancelCurrentOverride()
        await remoteDataServicesManager.performUpload(for: .overrides)
    }
    
    func deliverRemoteCarbs(amountInGrams: Double, absorptionTime: TimeInterval?, foodType: String?, startDate: Date?) async throws {
        do {
            try await servicesManagerDelegate?.deliverCarbs(amountInGrams: amountInGrams, absorptionTime: absorptionTime, foodType: foodType, startDate: startDate)
            NotificationManager.sendRemoteCarbEntryNotification(amountInGrams: amountInGrams)
            await remoteDataServicesManager.performUpload(for: .carb)
            analyticsServicesManager.didAddCarbs(source: "Remote")
        } catch {
            NotificationManager.sendRemoteCarbEntryFailureNotification(for: error, amountInGrams: amountInGrams)
            throw error
        }
    }
    
    func deliverRemoteBolus(amountInUnits: Double, decisionId: UUID?) async throws {
        try await deliverRemoteBolus(amountInUnits: amountInUnits, decisionId: decisionId, request: nil)
    }

    func deliverRemoteBolus(amountInUnits: Double, decisionId: UUID?, request: DoseMetadata.RemoteRequest?) async throws {
        do {
            
            guard amountInUnits > 0 else {
                throw BolusActionError.invalidBolus
            }
            
            guard let maxBolusAmount = settingsManager.loopSettings.maximumBolus else {
                throw BolusActionError.missingMaxBolus
            }
            
            guard amountInUnits <= maxBolusAmount else {
                throw BolusActionError.exceedsMaxBolus
            }
            
            try await servicesManagerDosingDelegate?.deliverBolus(amountInUnits: amountInUnits, decisionId: decisionId, request: request)
            NotificationManager.sendRemoteBolusNotification(amount: amountInUnits)
            await remoteDataServicesManager.performUpload(for: .dose)
            analyticsServicesManager.didBolus(source: "Remote")
        } catch {
            NotificationManager.sendRemoteBolusFailureNotification(for: error, amountInUnits: amountInUnits)
            throw error
        }
    }
    
    enum BolusActionError: LocalizedError {
        
        case invalidBolus
        case missingMaxBolus
        case exceedsMaxBolus
        
        var errorDescription: String? {
            switch self {
            case .invalidBolus:
                return NSLocalizedString("Invalid Bolus Amount", comment: "Bolus error description: invalid bolus amount.")
            case .missingMaxBolus:
                return NSLocalizedString("Missing maximum allowed bolus in settings", comment: "Bolus error description: missing maximum bolus in settings.")
            case .exceedsMaxBolus:
                return NSLocalizedString("Exceeds maximum allowed bolus in settings", comment: "Bolus error description: bolus exceeds maximum bolus in settings.")
            }
        }
    }
}

// MARK: - RemoteCarbEditActionDelegate

protocol ServicesManagerCarbEditDelegate: AnyObject {
    func deleteCarbs(syncIdentifier: String) async throws -> StoredCarbEntry
    func replaceCarbs(syncIdentifier: String, amountInGrams: Double, absorptionTime: TimeInterval, foodType: String?, startDate: Date) async throws -> StoredCarbEntry
}

extension ServicesManager: RemoteCarbEditActionDelegate {
    func deleteRemoteCarbs(syncIdentifier: String) async throws {
        do {
            guard let carbEditDelegate = servicesManagerDelegate as? ServicesManagerCarbEditDelegate else {
                throw RemoteCarbCommandError.internalError
            }
            let deleted = try await carbEditDelegate.deleteCarbs(syncIdentifier: syncIdentifier)
            let body = String(format: NSLocalizedString("Remote Carbs Delete: %d grams removed", comment: "The notification body for a successful remote carb delete. (1: Carb amount in grams)"), Int(deleted.quantity.doubleValue(for: .gram)))
            NotificationManager.sendRemoteCarbChangeNotification(body: body)
            await remoteDataServicesManager.performUpload(for: .carb)
        } catch {
            let body = NSLocalizedString("Remote Carbs Delete", comment: "The notification body prefix for a failed remote carb delete")
            NotificationManager.sendRemoteCarbChangeFailureNotification(body: body, error: error)
            throw error
        }
    }

    func replaceRemoteCarbs(syncIdentifier: String, amountInGrams: Double, absorptionTime: TimeInterval, foodType: String?, startDate: Date) async throws {
        let body = String(format: NSLocalizedString("Remote Carbs Edit: %d grams", comment: "The carb amount message for a remote carb edit notification. (1: Carb amount in grams)"), Int(amountInGrams))
        do {
            guard let carbEditDelegate = servicesManagerDelegate as? ServicesManagerCarbEditDelegate else {
                throw RemoteCarbCommandError.internalError
            }
            _ = try await carbEditDelegate.replaceCarbs(syncIdentifier: syncIdentifier, amountInGrams: amountInGrams, absorptionTime: absorptionTime, foodType: foodType, startDate: startDate)
            NotificationManager.sendRemoteCarbChangeNotification(body: body)
            await remoteDataServicesManager.performUpload(for: .carb)
        } catch {
            NotificationManager.sendRemoteCarbChangeFailureNotification(body: body, error: error)
            throw error
        }
    }

    enum RemoteCarbCommandError: LocalizedError {
        case internalError

        var errorDescription: String? {
            switch self {
            case .internalError:
                return NSLocalizedString("Internal error", comment: "Remote carb command error description: internal error.")
            }
        }
    }
}

extension ServicesManager: AlertIssuer {
    func issueAlert(_ alert: Alert) async {
        await alertManager.issueAlert(alert)
    }

    func retractAlert(identifier: Alert.Identifier) async {
        await alertManager.retractAlert(identifier: identifier)
    }
}

extension ServicesManager: ActiveServicesProvider { }

// MARK: - ServiceOnboardingDelegate

extension ServicesManager: ServiceOnboardingDelegate {
    func serviceOnboarding(didCreateService service: Service) {
        log.default("Service with identifier '%{public}@' created", service.pluginIdentifier)
        addActiveService(service)
    }

    func serviceOnboarding(didOnboardService service: Service) {
        precondition(service.isOnboarded)
        log.default("Service with identifier '%{public}@' onboarded", service.pluginIdentifier)
    }
}

extension ServicesManager {
    var availableSupports: [SupportUI] {
        activeServices.compactMap { ($0 as? SupportUI) ?? ($0 as? SupportProviding)?.createSupport() }
    }
}

// Service extension for rawValue
extension Service {
    typealias RawValue = [String: Any]

    var rawValue: RawValue {
        return [
            "serviceIdentifier": pluginIdentifier,
            "state": rawState
        ]
    }
}

// MARK: - RemoteProfileActionDelegate

extension ServicesManager: RemoteProfileActionDelegate {
    @MainActor
    func activateRemoteProfile(name: String, verify: (GlucoseRangeSchedule, CarbRatioSchedule, BasalRateSchedule, InsulinSensitivitySchedule) throws -> Void) async throws {
        do {
            guard let therapySettingsViewModelDelegate else {
                throw RemoteProfileActionError.unavailable
            }
            let viewModel = ProfileViewModel(therapySettings: settingsManager.therapySettings, delegate: therapySettingsViewModelDelegate)
            guard therapySettingsViewModelDelegate.pumpSupportedIncrements() != nil else {
                throw RemoteProfileActionError.noPump
            }
            guard let profile = try viewModel.savedProfile(named: name) else {
                throw RemoteProfileActionError.profileNotFound(name)
            }
            try profile.verify(with: verify)
            if case .failure(let error) = viewModel.validateProfile(profile) {
                throw error
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                viewModel.loadProfile(profile: profile) { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
            sendRemoteProfileNotification(name: name, error: nil)
        } catch {
            sendRemoteProfileNotification(name: name, error: error)
            throw error
        }
    }

    private func sendRemoteProfileNotification(name: String, error: Error?) {
        let notification = UNMutableNotificationContent()
        let title = String(format: NSLocalizedString("Remote Profile Switch: %1$@", comment: "The message for a remote profile switch notification. (1: profile name)"), name)
        notification.body = [title, error?.localizedDescription ?? "Success!"].joined(separator: "\n")
        notification.sound = .default

        let request = UNNotificationRequest(
            identifier: error == nil ? "com.loopkit.Loop.RemoteProfile" : "com.loopkit.Loop.RemoteProfileFailure",
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    enum RemoteProfileActionError: LocalizedError {
        case unavailable
        case noPump
        case profileNotFound(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return NSLocalizedString("Profile switching is not available", comment: "Remote profile switch error description: profile view model delegate missing.")
            case .noPump:
                return NSLocalizedString("No pump is configured", comment: "Remote profile switch error description: no pump.")
            case .profileNotFound(let name):
                return String(format: NSLocalizedString("No saved profile named %1$@", comment: "Remote profile switch error description: profile not found. (1: profile name)"), name)
            }
        }
    }
}
