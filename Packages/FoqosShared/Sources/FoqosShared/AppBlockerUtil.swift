import ManagedSettings
import SwiftUI

public class AppBlockerUtil {
  public let store = ManagedSettingsStore(
    named: ManagedSettingsStore.Name("familyFoqosAppRestrictions")
  )

  // A separate store intersects the adult filter with domain allow mode instead of
  // treating allowed domains as exceptions to the adult filter.
  private let safetyStore = ManagedSettingsStore(named: .init("familyFoqosProfileSafety"))

  public init() {}

  public func activateRestrictions(for profile: SharedData.ProfileSnapshot) {
    Log.info("Starting restrictions", category: .familyControls)

    let selection = profile.selectedActivity
    let allowOnlyApps = profile.enableAllowMode
    let allowOnlyDomains = profile.enableAllowModeDomains
    let strict = profile.enableStrictMode
    let enableSafariBlocking = profile.enableSafariBlocking
    let domains = getWebDomains(from: profile)

    let applicationTokens = selection.applicationTokens
    let categoriesTokens = selection.categoryTokens
    let webTokens = selection.webDomainTokens

    if allowOnlyApps {
      store.shield.applicationCategories =
        .all(except: applicationTokens)

      if enableSafariBlocking {
        store.shield.webDomainCategories = .all(except: webTokens)
      }

    } else {
      store.shield.applications = applicationTokens
      store.shield.applicationCategories = .specific(categoriesTokens)

      if enableSafariBlocking {
        store.shield.webDomainCategories = .specific(categoriesTokens)
        store.shield.webDomains = webTokens
      }
    }

    if allowOnlyDomains {
      store.webContent.blockedByFilter = .all(except: domains)
    } else {
      store.webContent.blockedByFilter = .specific(domains)
    }

    store.application.denyAppRemoval = strict
    applySafetySettings(for: profile)
  }

  public func deactivateRestrictions() {
    deactivateRestrictions(keepingSafeguardsFor: nil)
  }

  public func deactivateRestrictions(keepingSafeguardsFor profile: SharedData.ProfileSnapshot?) {
    Log.info("Stopping restrictions", category: .familyControls)

    guard let profile else {
      store.clearAllSettings()
      safetyStore.clearAllSettings()
      return
    }

    // Reapply the pin after process reconstruction without transiently lifting safeguards.
    store.application.denyAppRemoval = profile.enableStrictMode
    applySafetySettings(for: profile)
    store.shield.applications = nil
    store.shield.applicationCategories = nil
    store.shield.webDomains = nil
    store.shield.webDomainCategories = nil
    store.webContent.blockedByFilter = nil
  }

  private func applySafetySettings(for profile: SharedData.ProfileSnapshot) {
    safetyStore.webContent.blockedByFilter =
      profile.blockAdultWebsites == true ? .auto([], except: []) : nil
    safetyStore.application.denyAppInstallation = profile.blockAppInstallation == true
  }

  public func getWebDomains(from profile: SharedData.ProfileSnapshot) -> Set<WebDomain> {
    if let domains = profile.domains {
      return Set(domains.map { WebDomain(domain: $0) })
    }

    return []
  }
}
