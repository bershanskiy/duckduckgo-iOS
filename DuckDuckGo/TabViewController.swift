//
//  TabViewController.swift
//  DuckDuckGo
//
//  Copyright © 2017 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import WebKit
import Core
import StoreKit
import LocalAuthentication
import os.log
import BrowserServicesKit
import UserScript
import SwiftUI

// swiftlint:disable file_length
// swiftlint:disable type_body_length
class TabViewController: UIViewController {
// swiftlint:enable type_body_length

    private struct Constants {
        static let frameLoadInterruptedErrorCode = 102
        
        static let trackerNetworksAnimationDelay: TimeInterval = 0.7
        
        static let secGPCHeader = "Sec-GPC"

        static let navigationExpectationInterval = 3.0
    }
    
    @IBOutlet private(set) weak var error: UIView!
    @IBOutlet private(set) weak var errorInfoImage: UIImageView!
    @IBOutlet private(set) weak var errorHeader: UILabel!
    @IBOutlet private(set) weak var errorMessage: UILabel!
    @IBOutlet weak var webViewContainer: UIView!
    
    @IBOutlet var showBarsTapGestureRecogniser: UITapGestureRecognizer!

    private let instrumentation = TabInstrumentation()

    var isLinkPreview = false
    
    var openedByPage = false
    weak var openingTab: TabViewController? {
        didSet {
            delegate?.tabLoadingStateDidChange(tab: self)
        }
    }
    
    weak var delegate: TabDelegate?
    weak var chromeDelegate: BrowserChromeDelegate?

    var findInPage: FindInPage? {
        get { return findInPageScript?.findInPage }
        set { findInPageScript?.findInPage = newValue }
    }

    let progressWorker = WebProgressWorker()

    private(set) var webView: WKWebView!
    private lazy var appRatingPrompt: AppRatingPrompt = AppRatingPrompt()
    private weak var privacyController: PrivacyProtectionController?
    // TODO: share Dark Reader implementation across tabs
    private lazy var darkReader: DarkReader = DarkReader()

    private(set) lazy var appUrls: AppUrls = AppUrls()
    private var storageCache: StorageCache = AppDependencyProvider.shared.storageCache.current
    private lazy var appSettings = AppDependencyProvider.shared.appSettings

    internal lazy var featureFlagger = AppDependencyProvider.shared.featureFlagger
    private lazy var featureFlaggerInternalUserDecider = AppDependencyProvider.shared.featureFlaggerInternalUserDecider

    lazy var bookmarksManager = BookmarksManager()

    private(set) var urlToSiteRating: [URL: SiteRating] = [:]
    private(set) var siteRating: SiteRating?
    private(set) var tabModel: Tab

    private let requeryLogic = RequeryLogic()

    private static let tld = AppDependencyProvider.shared.storageCache.current.tld
    private let adClickAttributionDetection = ContentBlocking.shared.makeAdClickAttributionDetection(tld: tld)
    let adClickAttributionLogic = ContentBlocking.shared.makeAdClickAttributionLogic(tld: tld)

    private var httpsForced: Bool = false
    private var lastUpgradedURL: URL?
    private var lastError: Error?
    private var shouldReloadOnError = false
    private var failingUrls = Set<String>()

    private var trackerNetworksDetectedOnPage = Set<String>()
    private var pageHasTrackers = false

    private var detectedLoginURL: URL?
    private var preserveLoginsWorker: PreserveLoginsWorker?

    private var trackersInfoWorkItem: DispatchWorkItem?
    
    // Required to know when to disable autofill, see SaveLoginViewModel for details
    // Stored in memory on TabViewController for privacy reasons
    private var domainSaveLoginPromptLastShownOn: String?

    // If no trackers dax dialog was shown recently in this tab, ie without the user navigating somewhere else, e.g. backgrounding or tab switcher
    private var woShownRecently = false

    // Temporary to gather some data.  Fire a follow up if no trackers dax dialog was shown and then trackers appear.
    private var fireWoFollowUp = false
    
    // In certain conditions we try to present a dax dialog when one is already showing, so check to ensure we don't
    var isShowingFullScreenDaxDialog = false
    
    var temporaryDownloadForPreviewedFile: Download?
    var mostRecentAutoPreviewDownloadID: UUID?
    private var blobDownloadTargetFrame: WKFrameInfo?

    let userAgentManager: UserAgentManager = DefaultUserAgentManager.shared

    public var url: URL? {
        willSet {
            if newValue != url {
                delegate?.closeFindInPage(tab: self)
            }
        }
        didSet {
            updateTabModel()
            delegate?.tabLoadingStateDidChange(tab: self)
            checkLoginDetectionAfterNavigation()
        }
    }
    
    override var title: String? {
        didSet {
            updateTabModel()
            delegate?.tabLoadingStateDidChange(tab: self)
        }
    }
    
    public var canGoBack: Bool {
        let webViewCanGoBack = webView.canGoBack
        let navigatedToError = webView.url != nil && isError
        return webViewCanGoBack || navigatedToError || openingTab != nil
    }
    
    public var canGoForward: Bool {
        let webViewCanGoForward = webView.canGoForward
        return webViewCanGoForward && !isError
    }
    
    public var isError: Bool {
        return !error.isHidden
    }
    
    public var errorText: String? {
        return errorMessage.text
    }
    
    public var link: Core.Link? {
        if isError {
            if let url = url ?? webView.url ?? URL(string: "") {
                return Link(title: errorText, url: url)
            }
        }
        
        guard let url = url else {
            return tabModel.link
        }
        
        let activeLink = Link(title: title, url: url)
        guard let storedLink = tabModel.link else {
            return activeLink
        }
        
        return activeLink.merge(with: storedLink)
    }

    lazy var emailManager: EmailManager = {
        let emailManager = EmailManager()
        emailManager.aliasPermissionDelegate = self
        emailManager.requestDelegate = self
        return emailManager
    }()
    
    lazy var vaultManager: SecureVaultManager = {
        let manager = SecureVaultManager()
        manager.delegate = self
        return manager
    }()
    
    private static let debugEvents = EventMapping<AMPProtectionDebugEvents> { event, _, _, onComplete in
        let domainEvent: Pixel.Event
        switch event {
        case .ampBlockingRulesCompilationFailed:
            domainEvent = .ampBlockingRulesCompilationFailed
            Pixel.fire(pixel: domainEvent,
                       withAdditionalParameters: [:],
                       onComplete: onComplete)
        }
    }
    
    private lazy var linkProtection: LinkProtection = {
        LinkProtection(privacyManager: ContentBlocking.shared.privacyConfigurationManager,
                       contentBlockingManager: ContentBlocking.shared.contentBlockingManager,
                       errorReporting: Self.debugEvents)

    }()
    
    private lazy var referrerTrimming: ReferrerTrimming = {
        ReferrerTrimming(privacyManager: ContentBlocking.shared.privacyConfigurationManager,
                         contentBlockingManager: ContentBlocking.shared.contentBlockingManager,
                         tld: AppDependencyProvider.shared.storageCache.current.tld)
    }()

    private var canDisplayJavaScriptAlert: Bool {
        return presentedViewController == nil
            && delegate?.tabCheckIfItsBeingCurrentlyPresented(self) ?? false
            && !self.jsAlertController.isShown
            // disable new alerts to appear when navigation is expected
            && navigationExpectationTimer == nil
    }

    func present(_ alert: WebJSAlert) {
        self.jsAlertController.present(alert)
    }

    private func dismissJSAlertIfNeeded() {
        if jsAlertController.isShown {
            jsAlertController.dismiss(animated: false)
        }
    }

    private var navigationExpectationTimer: Timer? {
        willSet {
            navigationExpectationTimer?.invalidate()
        }
    }

    private func scheduleNavigationExpectation(destinationURL: URL?, onSessionRestored: (() -> Void)? = nil) {
        guard navigationExpectationTimer == nil else { return }

        navigationExpectationTimer = Timer.scheduledTimer(withTimeInterval: Constants.navigationExpectationInterval,
                                                          repeats: false) { [weak self] _ in
            Pixel.fire(pixel: .webKitDidBecomeUnresponsive)
            self?.navigationExpectationTimer = nil

            #if DEBUG
                func fileLine(file: StaticString = #file, line: Int = #line) -> String {
                    return "\(("\(file)" as NSString).lastPathComponent):\(line + 1)"
                }
                os_log("""
                    -----------------------------------------------------------------------
                    BREAK: WebView process has appeared hung and will be TERMINATED
                    Check %s to temporarily disable this behaviour
                    Hit Continue (^⌘Y) to continue program execution
                    -----------------------------------------------------------------------
                """, log: generalLog, type: .debug, fileLine())
                // DEBUG: Comment out the following line to disable stopping at this breakpoint:
                raise(SIGINT)
                // DEBUG: Uncomment the following line to disable WebView process termination:
//                return
            #endif

            if case .sessionRestored = self?.recreateWebView(destinationURL: destinationURL) {
                onSessionRestored?()
            }
        }
    }

    private var rulesCompiledCondition: RunLoop.ResumeCondition? = RunLoop.ResumeCondition()
    private let rulesCompilationMonitor = RulesCompilationMonitor.shared

    static func loadFromStoryboard(model: Tab) -> TabViewController {
        let storyboard = UIStoryboard(name: "Tab", bundle: nil)
        guard let controller = storyboard.instantiateViewController(withIdentifier: "TabViewController") as? TabViewController else {
            fatalError("Failed to instantiate controller as TabViewController")
        }
        controller.tabModel = model
        return controller
    }
    
    private var isAutofillEnabled: Bool {
        let context = LAContext()
        var error: NSError?
        let canAuthenticate = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)

        return appSettings.autofillCredentialsEnabled && featureFlagger.isFeatureOn(.autofill) && canAuthenticate
    }

    private var userContentController: UserContentController {
        (webView.configuration.userContentController as? UserContentController)!
    }

    required init?(coder aDecoder: NSCoder) {
        tabModel = Tab(link: nil)
        super.init(coder: aDecoder)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        preserveLoginsWorker = PreserveLoginsWorker(controller: self)
        initAttributionLogic()
        applyTheme(ThemeManager.shared.currentTheme)
        addTextSizeObserver()
        addDuckDuckGoEmailSignOutObserver()
        registerForDownloadsNotifications()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        woShownRecently = false // don't fire if the user goes somewhere else first
        resetNavigationBar()
        delegate?.tabDidRequestShowingMenuHighlighter(tab: self)
        tabModel.viewed = true
    }

    override func buildActivities() -> [UIActivity] {
        var activities: [UIActivity] = [SaveBookmarkActivity(controller: self)]

        activities.append(SaveBookmarkActivity(controller: self, isFavorite: true))
        activities.append(FindInPageActivity(controller: self))

        return activities
    }

    func initAttributionLogic() {
        adClickAttributionLogic.delegate = self
        adClickAttributionDetection.delegate = adClickAttributionLogic
    }
    
    func updateTabModel() {
        if let url = url {
            tabModel.link = Link(title: title, url: url)
        } else {
            tabModel.link = nil
        }
    }

    @objc func onApplicationWillResignActive() {
        shouldReloadOnError = true
    }

    func applyInheritedAttribution(_ attribution: AdClickAttributionLogic.State?) {
        adClickAttributionLogic.applyInheritedAttribution(state: attribution)
    }

    // The `consumeCookies` is legacy behaviour from the previous Fireproofing implementation. Cookies no longer need to be consumed after invocations
    // of the Fire button, but the app still does so in the event that previously persisted cookies have not yet been consumed.
    func attachWebView(configuration: WKWebViewConfiguration,
                       andLoadRequest request: URLRequest?,
                       consumeCookies: Bool,
                       loadingInitiatedByParentTab: Bool = false) {
        instrumentation.willPrepareWebView()

        let userContentController = UserContentController()
        configuration.userContentController = userContentController
        userContentController.delegate = self

        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        webView.allowsLinkPreview = true
        webView.allowsBackForwardNavigationGestures = true

        addObservers()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webViewContainer.addSubview(webView)

        updateContentMode()

        instrumentation.didPrepareWebView()

        if consumeCookies {
            consumeCookiesThenLoadRequest(request)
        } else if let url = request?.url {
            var loadingStopped = false
            linkProtection.getCleanURL(from: url, onStartExtracting: { [weak self] in
                if loadingInitiatedByParentTab {
                    // stop parent-initiated URL loading only if canonical URL extraction process has started
                    loadingStopped = true
                    self?.webView.stopLoading()
                }
                showProgressIndicator()
            }, onFinishExtracting: {}, completion: { [weak self] cleanURL in
                // restart the cleaned-up URL loading here if:
                //   link protection provided an updated URL
                //   OR if loading was stopped for a popup loaded by its parent
                //   OR for any other navigation which is not a popup loaded by its parent
                // the check is here to let an (about:blank) popup which has its loading
                // initiated by its parent to keep its active request, otherwise we would
                // break a js-initiated popup request such as printing from a popup
                guard url != cleanURL || loadingStopped || !loadingInitiatedByParentTab else { return }
                self?.load(urlRequest: .userInitiated(cleanURL))
            })
        }
    }

    private enum WebViewRecreationResult {
        case sessionRestored
        case navigationPerformed
    }
    private func recreateWebView(destinationURL: URL?) -> WebViewRecreationResult {
        var sessionStateData: Any?
        if #available(iOS 15.0, *) {
            sessionStateData = self.webView.interactionState
        }
        let configuration = self.webView.configuration

        self.removeObservers()
        self.webView.removeFromSuperview()
        self.webView = nil

        if #available(iOS 15.0, *),
           let sessionStateData = sessionStateData {

            self.attachWebView(configuration: configuration, andLoadRequest: nil, consumeCookies: false)
            self.webView.interactionState = sessionStateData

            return .sessionRestored
        } else {
            self.attachWebView(configuration: configuration,
                               andLoadRequest: destinationURL.map(URLRequest.userInitiated),
                               consumeCookies: false)
            return .navigationPerformed
        }
    }

    private func addObservers() {
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.hasOnlySecureContent), options: .new, context: nil)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.url), options: .new, context: nil)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.canGoBack), options: .new, context: nil)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.canGoForward), options: .new, context: nil)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.title), options: .new, context: nil)
    }

    private func consumeCookiesThenLoadRequest(_ request: URLRequest?) {
        webView.configuration.websiteDataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { _ in
            WebCacheManager.shared.consumeCookies { [weak self] in
                guard let strongSelf = self else { return }
                
                if let request = request {
                    strongSelf.load(urlRequest: request)
                }
                
                if request != nil {
                    strongSelf.delegate?.tabLoadingStateDidChange(tab: strongSelf)
                    strongSelf.onWebpageDidStartLoading(httpsForced: false)
                }
            }
        }
    }
    
    public func executeBookmarklet(url: URL) {
        if let js = url.toDecodedBookmarklet() {
            webView.evaluateJavaScript(js)
        }
    }

    public func load(url: URL) {
        webView.stopLoading()
        dismissJSAlertIfNeeded()

        load(url: url, didUpgradeURL: false)
    }

    public func load(backForwardListItem: WKBackForwardListItem) {
        webView.stopLoading()
        let destinationURL = backForwardListItem.url
        let itemOffset = webView.backForwardList.index(of: backForwardListItem)

        scheduleNavigationExpectation(destinationURL: destinationURL,
                                      onSessionRestored: { [weak self] in
            guard let self = self,
                  let item = itemOffset.flatMap(self.webView.backForwardList.item(at:))
            else {
                self?.load(url: destinationURL)
                return
            }
            self.load(backForwardListItem: item)
        })
        dismissJSAlertIfNeeded()

        updateContentMode()
        webView.go(to: backForwardListItem)
    }
    
    private func load(url: URL, didUpgradeURL: Bool) {
        if !didUpgradeURL {
            lastUpgradedURL = nil
        }
        
        if !url.isBookmarklet() {
            self.url = url
        }
        
        lastError = nil
        updateContentMode()
        linkProtection.getCleanURL(from: url,
                                   onStartExtracting: { showProgressIndicator() },
                                   onFinishExtracting: { },
                                   completion: { [weak self] url in
            self?.load(urlRequest: .userInitiated(url))
        })
    }
    
    func prepareForDataClearing() {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        delegate = nil
        
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }
    
    private func load(urlRequest: URLRequest) {
        loadViewIfNeeded()
        
        if let url = urlRequest.url, !shouldReissueSearch(for: url) {
            requeryLogic.onNewNavigation(url: url)
        }

        if #available(iOS 15.0, *) {
            assert(urlRequest.attribution == .user, "WebView requests should be user attributed")
        }

        scheduleNavigationExpectation(destinationURL: urlRequest.url, onSessionRestored: { [weak self] in
            self?.load(urlRequest: urlRequest)
        })
        dismissJSAlertIfNeeded()

        webView.stopLoading()
        Swift.print(urlRequest.url)
        webView.load(urlRequest)
        //if (appSettings.da)
    }
    
    // swiftlint:disable block_based_kvo
    open override func observeValue(forKeyPath keyPath: String?,
                                    of object: Any?,
                                    change: [NSKeyValueChangeKey: Any]?,
                                    context: UnsafeMutableRawPointer?) {
        // swiftlint:enable block_based_kvo

        guard let keyPath = keyPath else { return }
        
        switch keyPath {
            
        case #keyPath(WKWebView.estimatedProgress):
            progressWorker.progressDidChange(webView.estimatedProgress)
            
        case #keyPath(WKWebView.hasOnlySecureContent):
            hasOnlySecureContentChanged(hasOnlySecureContent: webView.hasOnlySecureContent)
            
        case #keyPath(WKWebView.url):
            webViewUrlHasChanged()
            
        case #keyPath(WKWebView.canGoBack):
            delegate?.tabLoadingStateDidChange(tab: self)
            
        case #keyPath(WKWebView.canGoForward):
            delegate?.tabLoadingStateDidChange(tab: self)

        case #keyPath(WKWebView.title):
            title = webView.title

        default:
            os_log("Unhandled keyPath %s", log: generalLog, type: .debug, keyPath)
        }
    }
    
    func webViewUrlHasChanged() {
        if url == nil {
            url = webView.url
        } else if let currentHost = url?.host, let newHost = webView.url?.host, currentHost == newHost {
            url = webView.url
        }
    }
    
    func hasOnlySecureContentChanged(hasOnlySecureContent: Bool) {
        guard webView.url?.host == siteRating?.url.host else { return }
        siteRating?.hasOnlySecureContent = hasOnlySecureContent
        updateSiteRating()
    }
    
    func enableFireproofingForDomain(_ domain: String) {
        PreserveLoginsAlert.showConfirmFireproofWebsite(usingController: self, forDomain: domain) { [weak self] in
            Pixel.fire(pixel: .browsingMenuFireproof)
            self?.preserveLoginsWorker?.handleUserEnablingFireproofing(forDomain: domain)
        }
    }
    
    func disableFireproofingForDomain(_ domain: String) {
        preserveLoginsWorker?.handleUserDisablingFireproofing(forDomain: domain)
    }
    
    private func checkForReloadOnError() {
        guard shouldReloadOnError else { return }
        shouldReloadOnError = false
        reload()
    }
    
    private func shouldReissueDDGStaticNavigation(for url: URL) -> Bool {
        guard appUrls.isDuckDuckGoStatic(url: url) else { return false }
        return  !appUrls.hasCorrectSearchHeaderParams(url: url)
    }
    
    private func reissueNavigationWithSearchHeaderParams(for url: URL) {
        load(url: appUrls.applySearchHeaderParams(for: url))
    }
    
    private func shouldReissueSearch(for url: URL) -> Bool {
        guard appUrls.isDuckDuckGoSearch(url: url) else { return false }
        return !appUrls.hasCorrectMobileStatsParams(url: url) || !appUrls.hasCorrectSearchHeaderParams(url: url)
    }
    
    private func reissueSearchWithRequiredParams(for url: URL) {
        let mobileSearch = appUrls.applyStatsParams(for: url)
        reissueNavigationWithSearchHeaderParams(for: mobileSearch)
    }
    
    private func showProgressIndicator() {
        progressWorker.didStartLoading()
    }
    
    private func hideProgressIndicator() {
        progressWorker.didFinishLoading()
    }

    public func reload() {
        dismissJSAlertIfNeeded()
        updateContentMode()
        guard webView.url != nil else { return }
        scheduleNavigationExpectation(destinationURL: webView.url)
        webView.reload()
    }

    func updateContentMode() {
        webView.configuration.defaultWebpagePreferences.preferredContentMode = tabModel.isDesktop ? .desktop : .mobile
    }

    func goBack() {
        // TODO: DR integration
        scheduleNavigationExpectation(destinationURL: webView.backForwardList.backItem?.url,
                                      onSessionRestored: { [weak self] in
            self?.goBack()
        })
        dismissJSAlertIfNeeded()

        if isError {
            hideErrorMessage()
            url = webView.url
            onWebpageDidStartLoading(httpsForced: false)
            onWebpageDidFinishLoading()
        } else if webView.canGoBack {
            webView.goBack()
            chromeDelegate?.omniBar.resignFirstResponder()
        } else if openingTab != nil {
            delegate?.tabDidRequestClose(self)
        }
    }

    func goForward() {
        // TODO DR integration
        scheduleNavigationExpectation(destinationURL: webView.backForwardList.forwardItem?.url,
                                      onSessionRestored: { [weak self] in
            self?.goForward()
        })
        dismissJSAlertIfNeeded()

        if webView.goForward() != nil {
            chromeDelegate?.omniBar.resignFirstResponder()
        }
    }
    
    private func showError(message: String) {
        webView.isHidden = true
        error.isHidden = false
        errorMessage.text = message
        error.layoutIfNeeded()
    }
    
    private func hideErrorMessage() {
        error.isHidden = true
        webView.isHidden = false
    }

    private func isDuckDuckGoUrl() -> Bool {
        guard let url = url else { return false }
        return appUrls.isDuckDuckGo(url: url)
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {

        guard let chromeDelegate = chromeDelegate else { return }

        if let controller = segue.destination as? PrivacyProtectionController {
            controller.popoverPresentationController?.delegate = controller

            if let siteRatingView = chromeDelegate.omniBar.siteRatingContainer.siteRatingView {
                controller.popoverPresentationController?.sourceView = siteRatingView
                controller.popoverPresentationController?.sourceRect = siteRatingView.bounds
            }

            controller.privacyProtectionDelegate = self
            privacyController = controller
            controller.omniDelegate = chromeDelegate.omniBar.omniDelegate
            controller.omniBarText = chromeDelegate.omniBar.textField.text
            controller.siteRating = siteRating
            controller.errorText = isError ? errorText : nil
        }
        
        if let controller = segue.destination as? FullscreenDaxDialogViewController {
            controller.spec = sender as? DaxDialogs.BrowsingSpec
            controller.woShown = woShownRecently
            controller.delegate = self
            
            if controller.spec?.highlightAddressBar ?? false {
                chromeDelegate.omniBar.cancelAllAnimations()
            }
        }
    }

    private var jsAlertController: JSAlertController!
    @IBSegueAction
    func createJSAlertController(coder: NSCoder, sender: Any?, segueIdentifier: String?) -> JSAlertController? {
        self.jsAlertController = JSAlertController(coder: coder)!
        return self.jsAlertController
    }

    private func addTextSizeObserver() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(onTextSizeChange),
                                               name: AppUserDefaults.Notifications.textSizeChange,
                                               object: nil)
    }

    private func addDuckDuckGoEmailSignOutObserver() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(onDuckDuckGoEmailSignOut),
                                               name: .emailDidSignOut,
                                               object: nil)
    }

    @objc func onTextSizeChange() {
        webView.adjustTextSize(appSettings.textSize)
    }

    @objc func onDuckDuckGoEmailSignOut(_ notification: Notification) {
        guard let url = webView.url else { return }
        if AppUrls().isDuckDuckGoEmailProtection(url: url) {
            webView.evaluateJavaScript("window.postMessage({ emailProtectionSignedOut: true }, window.origin);")
        }
    }

    private func resetNavigationBar() {
        chromeDelegate?.setNavigationBarHidden(false)
    }

    @IBAction func onBottomOfScreenTapped(_ sender: UITapGestureRecognizer) {
        showBars(animated: false)
    }

    private func showBars(animated: Bool = true) {
        chromeDelegate?.setBarsHidden(false, animated: animated)
    }

    func showPrivacyDashboard() {
        Pixel.fire(pixel: .privacyDashboardOpened)
        performSegue(withIdentifier: "PrivacyProtection", sender: self)
    }
    
    private var didGoBackForward: Bool = false

    private func resetSiteRating() {
        if let url = url {
            if didGoBackForward, let siteRating = urlToSiteRating[url] {
                self.siteRating = siteRating
                didGoBackForward = false
            } else {
                siteRating = makeSiteRating(url: url)
            }
        } else {
            siteRating = nil
        }
        onSiteRatingChanged()
    }
    
    private func makeSiteRating(url: URL) -> SiteRating {
        let entityMapping = EntityMapping()
        let privacyPractices = PrivacyPractices(tld: storageCache.tld,
                                                termsOfServiceStore: storageCache.termsOfServiceStore,
                                                entityMapping: entityMapping)
        
        let siteRating = SiteRating(url: url,
                                    httpsForced: httpsForced,
                                    entityMapping: entityMapping,
                                    privacyPractices: privacyPractices)
        urlToSiteRating[url] = siteRating
        
        return siteRating
    }

    private func updateSiteRating() {
        if isError {
            siteRating = nil
        }
        onSiteRatingChanged()
    }

    private func onSiteRatingChanged() {
        delegate?.tab(self, didChangeSiteRating: siteRating)
        privacyController?.updateSiteRating(siteRating)
    }
    
    func didLaunchBrowsingMenu() {
        Pixel.fire(pixel: .browsingMenuOpened)
        DaxDialogs.shared.resumeRegularFlow()
    }

    private func openExternally(url: URL) {
        self.url = webView.url
        delegate?.tabLoadingStateDidChange(tab: self)
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened {
                ActionMessageView.present(message: UserText.failedToOpenExternally)
            }

            // just showing a blank tab at this point, so close it
            if self.webView.url == nil {
                self.delegate?.tabDidRequestClose(self)
            }
        }
    }
    
    func presentOpenInExternalAppAlert(url: URL) {
        let title = UserText.customUrlSchemeTitle
        let message = UserText.customUrlSchemeMessage
        let open = UserText.customUrlSchemeOpen
        let dontOpen = UserText.customUrlSchemeDontOpen
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.overrideUserInterfaceStyle()
        alert.addAction(UIAlertAction(title: dontOpen, style: .cancel, handler: { _ in
            if self.webView.url == nil {
                self.delegate?.tabDidRequestClose(self)
            } else {
                self.url = self.webView.url
            }
        }))
        alert.addAction(UIAlertAction(title: open, style: .destructive, handler: { _ in
            self.openExternally(url: url)
        }))
        delegate?.tab(self, didRequestPresentingAlert: alert)
    }

    func dismiss() {
        progressWorker.progressBar = nil
        chromeDelegate?.omniBar.cancelAllAnimations()
        cancelTrackerNetworksAnimation()
        willMove(toParent: nil)
        removeFromParent()
        view.removeFromSuperview()
    }

    private func removeObservers() {
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.hasOnlySecureContent))
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.url))
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.canGoForward))
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.canGoBack))
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.title))
    }
        
    public func getCurrentWebsiteInfo() -> BrokenSiteInfo {
        let blockedTrackerDomains = siteRating?.trackersBlocked.compactMap { $0.domain } ?? []
        
        return BrokenSiteInfo(url: url,
                              httpsUpgrade: httpsForced,
                              blockedTrackerDomains: blockedTrackerDomains,
                              installedSurrogates: siteRating?.installedSurrogates.map { $0 } ?? [],
                              isDesktop: tabModel.isDesktop,
                              tdsETag: ContentBlocking.shared.contentBlockingManager.currentMainRules?.etag ?? "",
                              ampUrl: linkProtection.lastAMPURLString,
                              urlParametersRemoved: linkProtection.urlParametersRemoved)
    }
    
    public func print() {
        let printFormatter = webView.viewPrintFormatter()
        
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.jobName = Bundle.main.infoDictionary!["CFBundleName"] as? String ?? "DuckDuckGo"
        printInfo.outputType = .general
        
        let printController = UIPrintInteractionController.shared
        printController.printInfo = printInfo
        printController.printFormatter = printFormatter
        printController.present(animated: true, completionHandler: nil)
    }
    
    func onCopyAction(forUrl url: URL) {
        let copyText: String
        if appUrls.isDuckDuckGo(url: url) {
            let cleanURL = appUrls.removingInternalSearchParameters(fromUrl: url)
            copyText = cleanURL.absoluteString
        } else {
            copyText = url.absoluteString
        }
        
        onCopyAction(for: copyText)
    }
    
    func onCopyAction(for text: String) {
        UIPasteboard.general.string = text
    }
    
    deinit {
        temporaryDownloadForPreviewedFile?.cancel()
        removeObservers()
        RulesCompilationMonitor.shared.tabWillClose(self)
    }

}

// MARK: - LoginFormDetectionDelegate
extension TabViewController: LoginFormDetectionDelegate {
    
    func loginFormDetectionUserScriptDetectedLoginForm(_ script: LoginFormDetectionUserScript) {
        detectedLoginURL = webView.url
    }
    
}

// MARK: - WKNavigationDelegate
extension TabViewController: WKNavigationDelegate {
    
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
            performBasicHTTPAuthentication(protectionSpace: challenge.protectionSpace, completionHandler: completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
            guard let serverTrust = challenge.protectionSpace.serverTrust else { return }
            ServerTrustCache.shared.put(serverTrust: serverTrust, forDomain: challenge.protectionSpace.host)
        }
    }
    
    func performBasicHTTPAuthentication(protectionSpace: URLProtectionSpace,
                                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let isHttps = protectionSpace.protocol == "https"
        let alert = BasicAuthenticationAlert(host: protectionSpace.host,
                                             isEncrypted: isHttps,
                                             logInCompletion: { (login, password) in
            completionHandler(.useCredential, URLCredential(user: login, password: password, persistence: .forSession))
        }, cancelCompletion: {
            completionHandler(.rejectProtectionSpace, nil)
        })
        
        delegate?.tab(self, didRequestPresentingAlert: alert)
    }
    
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url {
            instrumentation.willLoad(url: url)
        }

        url = webView.url
        let tld = storageCache.tld
        let httpsForced = tld.domain(lastUpgradedURL?.host) == tld.domain(webView.url?.host)
        onWebpageDidStartLoading(httpsForced: httpsForced)
    }
    
    private func onWebpageDidStartLoading(httpsForced: Bool) {
        os_log("webpageLoading started", log: generalLog, type: .debug)

        // Only fire when on the same page that the without trackers Dax Dialog was shown
        self.fireWoFollowUp = false

        self.httpsForced = httpsForced
        delegate?.showBars()

        resetSiteRating()
        
        tabModel.link = link
        delegate?.tabLoadingStateDidChange(tab: self)

        trackerNetworksDetectedOnPage.removeAll()
        pageHasTrackers = false
        NetworkLeaderboard.shared.incrementPagesLoaded()
        
        appRatingPrompt.registerUsage()
        
        if let scene = self.view.window?.windowScene, appRatingPrompt.shouldPrompt() {
            SKStoreReviewController.requestReview(in: scene)
            appRatingPrompt.shown()
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        navigationExpectationTimer = nil

        let mimeType = MIMEType(from: navigationResponse.response.mimeType)

        let httpResponse = navigationResponse.response as? HTTPURLResponse
        let isSuccessfulResponse = (httpResponse?.validateStatusCode(statusCode: 200..<300) == nil)

        let didMarkAsInternal = featureFlaggerInternalUserDecider.markUserAsInternalIfNeeded(forUrl: webView.url, response: httpResponse)
        if didMarkAsInternal {
            NotificationCenter.default.post(Notification(name: AppUserDefaults.Notifications.didVerifyInternalUser))
        }

        if navigationResponse.canShowMIMEType && !FilePreviewHelper.canAutoPreviewMIMEType(mimeType) {
            url = webView.url
            if navigationResponse.isForMainFrame, let decision = setupOrClearTemporaryDownload(for: navigationResponse.response) {
                decisionHandler(decision)
            } else {
                if navigationResponse.isForMainFrame && isSuccessfulResponse {
                    adClickAttributionDetection.on2XXResponse(url: url)
                }
                adClickAttributionLogic.onProvisionalNavigation {
                    decisionHandler(.allow)
                }
            }
        } else if isSuccessfulResponse {
            if FilePreviewHelper.canAutoPreviewMIMEType(mimeType) {
                let download = self.startDownload(with: navigationResponse, decisionHandler: decisionHandler)
                mostRecentAutoPreviewDownloadID = download?.id
                Pixel.fire(pixel: .downloadStarted,
                           withAdditionalParameters: [PixelParameters.canAutoPreviewMIMEType: "1"])
            } else if #available(iOS 14.5, *),
                      let url = navigationResponse.response.url,
                      case .blob = SchemeHandler.schemeType(for: url) {
                decisionHandler(.download)

            } else if let downloadMetadata = AppDependencyProvider.shared.downloadManager
                .downloadMetaData(for: navigationResponse.response) {
                if view.window == nil {
                    decisionHandler(.cancel)
                } else {
                    self.presentSaveToDownloadsAlert(with: downloadMetadata) {
                        self.startDownload(with: navigationResponse, decisionHandler: decisionHandler)
                    } cancelHandler: {
                        decisionHandler(.cancel)
                    }
                }
            } else {
                Pixel.fire(pixel: .unhandledDownload)
                decisionHandler(.cancel)
            }

        } else {
            // MIME type should trigger download but response has no 2xx status code
            decisionHandler(.allow)
        }
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationExpectationTimer = nil
        lastError = nil
        cancelTrackerNetworksAnimation()
        shouldReloadOnError = false
        hideErrorMessage()
        showProgressIndicator()
        chromeDelegate?.omniBar.startLoadingAnimation(for: webView.url)
        linkProtection.cancelOngoingExtraction()
        linkProtection.setMainFrameUrl(webView.url)
        referrerTrimming.onBeginNavigation(to: webView.url)
        adClickAttributionDetection.onStartNavigation(url: webView.url)
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        adClickAttributionDetection.onDidFinishNavigation(url: webView.url)
        adClickAttributionLogic.onDidFinishNavigation(host: webView.url?.host)
        hideProgressIndicator()
        onWebpageDidFinishLoading()
        instrumentation.didLoadURL()
        checkLoginDetectionAfterNavigation()
        
        // definitely finished with any potential login cycle by this point, so don't try and handle it any more
        detectedLoginURL = nil
        updatePreview()
        linkProtection.setMainFrameUrl(nil)
        referrerTrimming.onFinishNavigation()
    }
    
    func preparePreview(completion: @escaping (UIImage?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let webView = self?.webView else { completion(nil); return }
            UIGraphicsBeginImageContextWithOptions(webView.bounds.size, false, UIScreen.main.scale)
            webView.drawHierarchy(in: webView.bounds, afterScreenUpdates: true)
            self?.jsAlertController.view.drawHierarchy(in: self!.jsAlertController.view.bounds,
                                                       afterScreenUpdates: false)
            let image = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            completion(image)
        }
    }
    
    private func updatePreview() {
        preparePreview { image in
            if let image = image {
                self.delegate?.tab(self, didUpdatePreview: image)
            }
        }
    }
    
    private func onWebpageDidFinishLoading() {
        os_log("webpageLoading finished", log: generalLog, type: .debug)
        
        siteRating?.finishedLoading = true
        updateSiteRating()
        tabModel.link = link
        delegate?.tabLoadingStateDidChange(tab: self)

        showDaxDialogOrStartTrackerNetworksAnimationIfNeeded()
    }

    func showDaxDialogOrStartTrackerNetworksAnimationIfNeeded() {
        guard !isLinkPreview else { return }

        if DaxDialogs.shared.isAddFavoriteFlow {
            delegate?.tabDidRequestShowingMenuHighlighter(tab: self)
            return
        }

        guard let siteRating = self.siteRating,
              !isShowingFullScreenDaxDialog else {

            scheduleTrackerNetworksAnimation(collapsing: true)
            return
        }
        
        if let url = link?.url, AppUrls().isDuckDuckGoEmailProtection(url: url) {
            scheduleTrackerNetworksAnimation(collapsing: true)
            return
        }
        
        guard let spec = DaxDialogs.shared.nextBrowsingMessage(siteRating: siteRating) else {
            
            if DaxDialogs.shared.shouldShowFireButtonPulse {
                delegate?.tabDidRequestFireButtonPulse(tab: self)
            }
            
            scheduleTrackerNetworksAnimation(collapsing: true)
            return
        }
        
        isShowingFullScreenDaxDialog = true
        scheduleTrackerNetworksAnimation(collapsing: !spec.highlightAddressBar)
        let daxDialogSourceURL = self.url
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // https://app.asana.com/0/414709148257752/1201620790053163/f
            if self?.url != daxDialogSourceURL {
                DaxDialogs.shared.overrideShownFlagFor(spec, flag: false)
                self?.isShowingFullScreenDaxDialog = false
                return
            }

            self?.chromeDelegate?.omniBar.resignFirstResponder()
            self?.chromeDelegate?.setBarsHidden(false, animated: true)
            self?.performSegue(withIdentifier: "DaxDialog", sender: spec)

            if spec == DaxDialogs.BrowsingSpec.withoutTrackers {
                self?.woShownRecently = true
                self?.fireWoFollowUp = true
            }
        }
    }
    
    private func scheduleTrackerNetworksAnimation(collapsing: Bool) {
        let trackersWorkItem = DispatchWorkItem {
            guard let siteRating = self.siteRating else { return }
            self.delegate?.tab(self, didRequestPresentingTrackerAnimation: siteRating, isCollapsing: collapsing)
        }
        trackersInfoWorkItem = trackersWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.trackerNetworksAnimationDelay,
                                      execute: trackersWorkItem)
    }
    
    private func cancelTrackerNetworksAnimation() {
        trackersInfoWorkItem?.cancel()
        trackersInfoWorkItem = nil
    }
    
    private func checkLoginDetectionAfterNavigation() {
        if preserveLoginsWorker?.handleLoginDetection(detectedURL: detectedLoginURL, currentURL: url) ?? false {
            detectedLoginURL = nil
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        adClickAttributionDetection.onDidFailNavigation()
        hideProgressIndicator()
        webpageDidFailToLoad()
        checkForReloadOnError()
        scheduleTrackerNetworksAnimation(collapsing: true)
        linkProtection.setMainFrameUrl(nil)
        referrerTrimming.onFailedNavigation()
    }

    private func webpageDidFailToLoad() {
        os_log("webpageLoading failed", log: generalLog, type: .debug)
        if isError {
            showBars(animated: true)
        }
        siteRating?.finishedLoading = true
        updateSiteRating()
        self.delegate?.tabLoadingStateDidChange(tab: self)
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        adClickAttributionDetection.onDidFailNavigation()
        hideProgressIndicator()
        linkProtection.setMainFrameUrl(nil)
        referrerTrimming.onFailedNavigation()
        lastError = error
        let error = error as NSError

        // Ignore Frame Load Interrupted that will be caused when a download starts
        if error.code == 102 && error.domain == "WebKitErrorDomain" {
            return
        }
        
        if let url = url,
           let domain = url.host,
           error.code == Constants.frameLoadInterruptedErrorCode {
            // prevent loops where a site keeps redirecting to itself (e.g. bbc)
            failingUrls.insert(domain)

            // Reset the URL, e.g if opened externally
            self.url = webView.url
        }

        // wait before showing errors in case they recover automatically
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showErrorNow()
        }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        self.url = url
        self.siteRating = makeSiteRating(url: url)
        updateSiteRating()
        checkLoginDetectionAfterNavigation()
    }
    
    private func requestForDoNotSell(basedOn incomingRequest: URLRequest) -> URLRequest? {
        /*
         For now, the GPC header is only applied to sites known to be honoring GPC (nytimes.com, washingtonpost.com),
         while the DOM signal is available to all websites.
         This is done to avoid an issue with back navigation when adding the header (e.g. with 't.co').
         */
        guard let url = incomingRequest.url, appUrls.isGPCEnabled(url: url) else { return nil }
        
        var request = incomingRequest
        // Add Do Not sell header if needed
        let config = ContentBlocking.shared.privacyConfigurationManager.privacyConfig
        let domain = incomingRequest.url?.host
        let urlAllowed = config.isFeature(.gpc, enabledForDomain: domain)
        
        if appSettings.sendDoNotSell && urlAllowed {
            if let headers = request.allHTTPHeaderFields,
               headers.firstIndex(where: { $0.key == Constants.secGPCHeader }) == nil {
                request.addValue("1", forHTTPHeaderField: Constants.secGPCHeader)

                if #available(iOS 15.0, *) {
                    request.attribution = .user
                }

                return request
            }
        } else {
            // Check if DN$ header is still there and remove it
            if let headers = request.allHTTPHeaderFields, headers.firstIndex(where: { $0.key == Constants.secGPCHeader }) != nil {
                request.setValue(nil, forHTTPHeaderField: Constants.secGPCHeader)

                if #available(iOS 15.0, *) {
                    request.attribution = .user
                }

                return request
            }
        }
        return nil
    }
    // swiftlint:disable function_body_length
    // swiftlint:disable cyclomatic_complexity

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        navigationExpectationTimer = nil

        if let url = navigationAction.request.url,
           !appUrls.isDuckDuckGoSearch(url: url),
           true == shouldWaitUntilContentBlockingIsLoaded({ [weak self, webView /* decision handler must be called */] in
               guard let self = self else {
                   decisionHandler(.cancel)
                   return
               }
               self.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
           }) {
            // will wait for Content Blocking to load and re-call on completion
            return
        }

        didGoBackForward = (navigationAction.navigationType == .backForward)

        // This check needs to happen before GPC checks. Otherwise the navigation type may be rewritten to `.other`
        // which would skip link rewrites.
        if navigationAction.navigationType != .backForward {
            let didRewriteLink = linkProtection.requestTrackingLinkRewrite(initiatingURL: webView.url,
                                                                           navigationAction: navigationAction,
                                                                           onStartExtracting: { showProgressIndicator() },
                                                                           onFinishExtracting: { },
                                                                           onLinkRewrite: { [weak self] newURL, navigationAction in
                guard let self = self else { return }
                if self.isNewTargetBlankRequest(navigationAction: navigationAction) {
                    self.delegate?.tab(self,
                                       didRequestNewTabForUrl: newURL,
                                       openedByPage: true,
                                       inheritingAttribution: self.adClickAttributionLogic.state)
                } else {
                    self.load(url: newURL)
                }
            },
                                                                           policyDecisionHandler: decisionHandler)

            if didRewriteLink {
                return
            }
        }

        if navigationAction.isTargetingMainFrame(),
           !(navigationAction.request.url?.isCustomURLScheme() ?? false),
           navigationAction.navigationType != .backForward,
           let newRequest = referrerTrimming.trimReferrer(forNavigation: navigationAction,
                                                          originUrl: webView.url ?? navigationAction.sourceFrame.webView?.url) {
            decisionHandler(.cancel)
            load(urlRequest: newRequest)
            return
        }

        if navigationAction.isTargetingMainFrame(),
           !(navigationAction.request.url?.isCustomURLScheme() ?? false),
           navigationAction.navigationType != .backForward,
           let request = requestForDoNotSell(basedOn: navigationAction.request) {

            decisionHandler(.cancel)
            load(urlRequest: request)
            return
        }

        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let modifierFlags = delegate?.tabWillRequestNewTab(self) {

            if modifierFlags.contains(.command) {
                if modifierFlags.contains(.shift) {
                    decisionHandler(.cancel)
                    delegate?.tab(self,
                                  didRequestNewTabForUrl: url,
                                  openedByPage: false,
                                  inheritingAttribution: adClickAttributionLogic.state)
                    return
                } else {
                    decisionHandler(.cancel)
                    delegate?.tab(self, didRequestNewBackgroundTabForUrl: url, inheritingAttribution: adClickAttributionLogic.state)
                    return
                }
            }
        }

        decidePolicyFor(navigationAction: navigationAction) { [weak self] decision in
            if let self = self,
               let url = navigationAction.request.url,
               decision != .cancel,
               navigationAction.isTargetingMainFrame() {
                if self.appUrls.isDuckDuckGoSearch(url: url) {
                    StatisticsLoader.shared.refreshSearchRetentionAtb()
                }

                self.delegate?.closeFindInPage(tab: self)
            }
            decisionHandler(decision)
        }
    }
    // swiftlint:enable function_body_length
    // swiftlint:enable cyclomatic_complexity

    private func shouldWaitUntilContentBlockingIsLoaded(_ completion: @Sendable @escaping @MainActor () -> Void) -> Bool {
        // Ensure Content Blocking Assets (WKContentRuleList&UserScripts) are installed
        if userContentController.contentBlockingAssetsInstalled {
            RulesCompilationMonitor.shared.reportNavigationDidNotWaitForRules()
            return false
        }

        Task {
            RulesCompilationMonitor.shared.tabWillWaitForRulesCompilation(self)
            showProgressIndicator()
            await userContentController.awaitContentBlockingAssetsInstalled()
            RulesCompilationMonitor.shared.reportTabFinishedWaitingForRules(self)

            await MainActor.run(body: completion)
        }
        return true
    }

    private func decidePolicyFor(navigationAction: WKNavigationAction, completion: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowPolicy = determineAllowPolicy()

        let tld = storageCache.tld

        if navigationAction.isTargetingMainFrame()
            && tld.domain(navigationAction.request.mainDocumentURL?.host) != tld.domain(lastUpgradedURL?.host) {
            lastUpgradedURL = nil
        }

        guard navigationAction.request.mainDocumentURL != nil else {
            completion(allowPolicy)
            return
        }

        guard let url = navigationAction.request.url else {
            completion(allowPolicy)
            return
        }
        
        if navigationAction.isTargetingMainFrame(), navigationAction.navigationType == .backForward {
            adClickAttributionLogic.onBackForwardNavigation(mainFrameURL: webView.url)
        }

        let schemeType = SchemeHandler.schemeType(for: url)
        self.blobDownloadTargetFrame = nil
        switch schemeType {
        case .navigational:
            performNavigationFor(url: url,
                                 navigationAction: navigationAction,
                                 allowPolicy: allowPolicy,
                                 completion: completion)

        case .external(let action):
            performExternalNavigationFor(url: url, action: action)
            completion(.cancel)

        case .blob:
            performBlobNavigation(navigationAction, completion: completion)

        case .unknown:
            if navigationAction.navigationType == .linkActivated {
                openExternally(url: url)
            } else {
                presentOpenInExternalAppAlert(url: url)
            }
            completion(.cancel)
        }
    }

    private func performNavigationFor(url: URL,
                                      navigationAction: WKNavigationAction,
                                      allowPolicy: WKNavigationActionPolicy,
                                      completion: @escaping (WKNavigationActionPolicy) -> Void) {

        if shouldReissueSearch(for: url) {
            reissueSearchWithRequiredParams(for: url)
            completion(.cancel)
            return
        }

        if shouldReissueDDGStaticNavigation(for: url) {
            reissueNavigationWithSearchHeaderParams(for: url)
            completion(.cancel)
            return
        }

        if isNewTargetBlankRequest(navigationAction: navigationAction) {
            delegate?.tab(self, didRequestNewTabForUrl: url, openedByPage: true, inheritingAttribution: adClickAttributionLogic.state)
            completion(.cancel)
            return
        }

        if allowPolicy != WKNavigationActionPolicy.cancel {
            userAgentManager.update(webView: webView, isDesktop: tabModel.isDesktop, url: url)
        }

        if !ContentBlocking.shared.privacyConfigurationManager.privacyConfig.isProtected(domain: url.host) {
            completion(allowPolicy)
            return
        }

        if shouldUpgradeToHttps(url: url, navigationAction: navigationAction) {
            upgradeToHttps(url: url, allowPolicy: allowPolicy, completion: completion)
        } else {
            completion(allowPolicy)
        }
    }

    private func upgradeToHttps(url: URL,
                                allowPolicy: WKNavigationActionPolicy,
                                completion: @escaping (WKNavigationActionPolicy) -> Void) {
        Task {
            let result = await PrivacyFeatures.httpsUpgrade.upgrade(url: url)
            switch result {
            case let .success(upgradedUrl):
                if lastUpgradedURL != upgradedUrl {
                    NetworkLeaderboard.shared.incrementHttpsUpgrades()
                    lastUpgradedURL = upgradedUrl
                    load(url: upgradedUrl, didUpgradeURL: true)
                    completion(.cancel)
                } else {
                    completion(allowPolicy)
                }
            case .failure:
                completion(allowPolicy)
            }
        }
    }

    @MainActor
    private func prepareForContentBlocking() async {
        // Ensure Content Blocking Assets (WKContentRuleList&UserScripts) are installed
        if !userContentController.contentBlockingAssetsInstalled {
            RulesCompilationMonitor.shared.tabWillWaitForRulesCompilation(self)
            showProgressIndicator()
            await userContentController.awaitContentBlockingAssetsInstalled()
            RulesCompilationMonitor.shared.reportTabFinishedWaitingForRules(self)
        } else {
            RulesCompilationMonitor.shared.reportNavigationDidNotWaitForRules()
        }
    }

    private func shouldUpgradeToHttps(url: URL, navigationAction: WKNavigationAction) -> Bool {
        return !failingUrls.contains(url.host ?? "") && navigationAction.isTargetingMainFrame()
    }

    private func performExternalNavigationFor(url: URL, action: SchemeHandler.Action) {
        switch action {
        case .open:
            openExternally(url: url)
        case .askForConfirmation:
            presentOpenInExternalAppAlert(url: url)
        case .cancel:
            break
        }
    }
    
    private func isNewTargetBlankRequest(navigationAction: WKNavigationAction) -> Bool {
        return navigationAction.navigationType == .linkActivated && navigationAction.targetFrame == nil
    }

    private func determineAllowPolicy() -> WKNavigationActionPolicy {
        let allowWithoutUniversalLinks = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
        return AppUserDefaults().allowUniversalLinks ? .allow : allowWithoutUniversalLinks
    }
    
    private func showErrorNow() {
        guard let error = lastError as NSError? else { return }
        hideProgressIndicator()
        ViewHighlighter.hideAll()

        if !(error.failedUrl?.isCustomURLScheme() ?? false) {
            url = error.failedUrl
            showError(message: error.localizedDescription)
        }

        webpageDidFailToLoad()
        checkForReloadOnError()
    }
    
    private func showLoginDetails(with account: SecureVaultModels.WebsiteAccount) {
        if let navController = SettingsViewController.loadFromStoryboard() as? UINavigationController,
           let settingsController = navController.topViewController as? SettingsViewController {
            settingsController.loadViewIfNeeded()
            
            settingsController.showAutofillAccountDetails(account, animated: false)
            self.present(navController, animated: true)
        }
    }
    
    @objc private func dismissLoginDetails() {
        dismiss(animated: true)
    }
}

// MARK: - Downloads
extension TabViewController {

    private func performBlobNavigation(_ navigationAction: WKNavigationAction,
                                       completion: @escaping (WKNavigationActionPolicy) -> Void) {
        guard #available(iOS 14.5, *) else {
            Pixel.fire(pixel: .downloadAttemptToOpenBLOBviaJS)
            self.legacySetupBlobDownload(for: navigationAction) {
                completion(.allow)
            }
            return
        }

        self.blobDownloadTargetFrame = navigationAction.targetFrame
        completion(.allow)
    }

    @discardableResult
    private func startDownload(with navigationResponse: WKNavigationResponse,
                               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) -> Download? {
        let downloadManager = AppDependencyProvider.shared.downloadManager
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let url = navigationResponse.response.url!

        if case .blob = SchemeHandler.schemeType(for: url) {
            if #available(iOS 14.5, *) {
                decisionHandler(.download)

                return nil

            // [iOS<14.5 legacy] reuse temporary download for blob: initiated by WKNavigationAction
            } else if let download = self.temporaryDownloadForPreviewedFile,
                      download.temporary,
                      download.url == navigationResponse.response.url {
                self.temporaryDownloadForPreviewedFile = nil
                download.temporary = FilePreviewHelper.canAutoPreviewMIMEType(download.mimeType)
                downloadManager.startDownload(download)

                decisionHandler(.cancel)

                return download
            }
        } else if let download = downloadManager.makeDownload(navigationResponse: navigationResponse, cookieStore: cookieStore) {
            downloadManager.startDownload(download)
            decisionHandler(.cancel)

            return download
        }

        decisionHandler(.cancel)
        return nil
    }

    /**
     Some files might be previewed by webkit but in order to share them
     we need to download them first.
     This method stores the temporary download or clears it if necessary
     
     - Returns: Navigation policy or nil if it is not a download
     */
    private func setupOrClearTemporaryDownload(for response: URLResponse) -> WKNavigationResponsePolicy? {
        let downloadManager = AppDependencyProvider.shared.downloadManager
        guard let url = response.url,
              let downloadMetaData = downloadManager.downloadMetaData(for: response),
              !downloadMetaData.mimeType.isHTML
        else {
            temporaryDownloadForPreviewedFile?.cancel()
            temporaryDownloadForPreviewedFile = nil
            return nil
        }
        guard SchemeHandler.schemeType(for: url) != .blob else {
            // suggestedFilename is empty for blob: downloads unless handled via completion(.download)
            // WKNavigationResponse._downloadAttribute private API could be used instead of it :(
            if #available(iOS 14.5, *),
               // if temporary download not setup yet, preview otherwise
               self.temporaryDownloadForPreviewedFile?.url != url {
                // calls webView:navigationAction:didBecomeDownload:
                return .download
            } else {
                self.blobDownloadTargetFrame = nil
                return .allow
            }
        }

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        temporaryDownloadForPreviewedFile = downloadManager.makeDownload(response: response,
                                                                         cookieStore: cookieStore,
                                                                         temporary: true)
        return .allow
    }

    @available(iOS 14.5, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let delegate = InlineWKDownloadDelegate()
        // temporary delegate held strongly in callbacks
        // after destination decision WKDownload delegate will be set
        // to a WKDownloadSession and passed to Download Manager
        delegate.decideDestinationCallback = { [weak self] _, response, suggestedFilename, callback in
            withExtendedLifetime(delegate) {
                let downloadManager = AppDependencyProvider.shared.downloadManager
                guard let self = self,
                      let downloadMetadata = downloadManager.downloadMetaData(for: navigationResponse.response,
                                                                              suggestedFilename: suggestedFilename)
                else {
                    callback(nil)
                    return
                }

                let isTemporary = navigationResponse.canShowMIMEType
                    || FilePreviewHelper.canAutoPreviewMIMEType(downloadMetadata.mimeType)
                if isTemporary {
                    // restart blob request loading for preview that was interrupted by .download callback
                    if navigationResponse.canShowMIMEType {
                        self.webView.load(navigationResponse.response.url!, in: self.blobDownloadTargetFrame)
                    }
                    callback(self.transfer(download,
                                           to: downloadManager,
                                           with: navigationResponse.response,
                                           suggestedFilename: suggestedFilename,
                                           isTemporary: isTemporary))

                } else {
                    self.presentSaveToDownloadsAlert(with: downloadMetadata) {
                        callback(self.transfer(download,
                                               to: downloadManager,
                                               with: navigationResponse.response,
                                               suggestedFilename: suggestedFilename,
                                               isTemporary: isTemporary))
                    } cancelHandler: {
                        callback(nil)
                    }

                    self.temporaryDownloadForPreviewedFile = nil
                }

                delegate.decideDestinationCallback = nil
                delegate.downloadDidFailCallback = nil
                self.blobDownloadTargetFrame = nil
            }
        }
        delegate.downloadDidFailCallback = { _, _, _ in
            withExtendedLifetime(delegate) {
                delegate.decideDestinationCallback = nil
                delegate.downloadDidFailCallback = nil
            }
        }
        download.delegate = delegate
    }

    @available(iOS 14.5, *)
    private func transfer(_ download: WKDownload,
                          to downloadManager: DownloadManager,
                          with response: URLResponse,
                          suggestedFilename: String,
                          isTemporary: Bool) -> URL? {

        let downloadSession = WKDownloadSession(download)
        let download = downloadManager.makeDownload(response: response,
                                                    suggestedFilename: suggestedFilename,
                                                    downloadSession: downloadSession,
                                                    cookieStore: nil,
                                                    temporary: isTemporary)

        self.temporaryDownloadForPreviewedFile = isTemporary ? download : nil
        if let download = download {
            downloadManager.startDownload(download)
        }

        return downloadSession.localURL
    }

    private func presentSaveToDownloadsAlert(with downloadMetadata: DownloadMetadata,
                                             saveToDownloadsHandler: @escaping () -> Void,
                                             cancelHandler: @escaping (() -> Void)) {
        let alert = SaveToDownloadsAlert.makeAlert(downloadMetadata: downloadMetadata) {
            Pixel.fire(pixel: .downloadStarted,
                       withAdditionalParameters: [PixelParameters.canAutoPreviewMIMEType: "0"])

            if downloadMetadata.mimeType != .octetStream {
                let mimeType = downloadMetadata.mimeTypeSource
                Pixel.fire(pixel: .downloadStartedDueToUnhandledMIMEType,
                           withAdditionalParameters: [PixelParameters.mimeType: mimeType])
            }

            saveToDownloadsHandler()
        } cancelHandler: {
            cancelHandler()
        }
        DispatchQueue.main.async {
            self.present(alert, animated: true)
        }
    }

    private func legacySetupBlobDownload(for navigationAction: WKNavigationAction, completion: @escaping () -> Void) {
        let url = navigationAction.request.url!
        let legacyBlobDownloadScript = """
            let blob = await fetch(url).then(r => r.blob())
            let data = await new Promise((resolve, reject) => {
              const fileReader = new FileReader();
              fileReader.onerror = (e) => reject(fileReader.error);
              fileReader.onloadend = (e) => {
                resolve(e.target.result.split(",")[1])
              };
              fileReader.readAsDataURL(blob);
            })
            return {
                mimeType: blob.type,
                size: blob.size,
                data: data
            }
        """
        webView.callAsyncJavaScript(legacyBlobDownloadScript,
                                    arguments: ["url": url.absoluteString],
                                    in: navigationAction.sourceFrame,
                                    in: .page) { [weak self] result in
            guard let self = self,
                  let dict = try? result.get() as? [String: Any],
                  let mimeType = dict["mimeType"] as? String,
                  let size = dict["size"] as? Int,
                  let data = dict["data"] as? String
            else {
                completion()
                return
            }

            let downloadManager = AppDependencyProvider.shared.downloadManager
            let downloadSession = Base64DownloadSession(base64: data)
            let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: size, textEncodingName: nil)
            self.temporaryDownloadForPreviewedFile = downloadManager.makeDownload(response: response,
                                                                                  downloadSession: downloadSession,
                                                                                  cookieStore: nil,
                                                                                  temporary: true)
            completion()
        }
    }

    private func registerForDownloadsNotifications() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(downloadDidStart),
                                               name: .downloadStarted,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector:
                                                #selector(downloadDidFinish),
                                               name: .downloadFinished,
                                               object: nil)
    }

    @objc private func downloadDidStart(_ notification: Notification) {
        guard let download = notification.userInfo?[DownloadManager.UserInfoKeys.download] as? Download,
              !download.temporary
        else { return }

        let attributedMessage = DownloadActionMessageViewHelper.makeDownloadStartedMessage(for: download)

        DispatchQueue.main.async {
            ActionMessageView.present(message: attributedMessage, numberOfLines: 2, actionTitle: UserText.actionGenericShow, onAction: {
                Pixel.fire(pixel: .downloadsListOpened,
                           withAdditionalParameters: [PixelParameters.originatedFromMenu: "0"])
                self.delegate?.tabDidRequestDownloads(tab: self)
            })
        }
    }

    @objc private func downloadDidFinish(_ notification: Notification) {
        if let error = notification.userInfo?[DownloadManager.UserInfoKeys.error] as? Error {
            let nserror = error as NSError
            let downloadWasCancelled = nserror.domain == "NSURLErrorDomain" && nserror.code == -999

            if !downloadWasCancelled {
                ActionMessageView.present(message: UserText.messageDownloadFailed)
            }

            return
        }

        guard let download = notification.userInfo?[DownloadManager.UserInfoKeys.download] as? Download else { return }

        DispatchQueue.main.async {
            if !download.temporary {
                let attributedMessage = DownloadActionMessageViewHelper.makeDownloadFinishedMessage(for: download)
                ActionMessageView.present(message: attributedMessage, numberOfLines: 2, actionTitle: UserText.actionGenericShow, onAction: {
                    Pixel.fire(pixel: .downloadsListOpened,
                               withAdditionalParameters: [PixelParameters.originatedFromMenu: "0"])
                    self.delegate?.tabDidRequestDownloads(tab: self)
                })
            } else {
                self.previewDownloadedFileIfNecessary(download)
            }
        }
    }

    private func previewDownloadedFileIfNecessary(_ download: Download) {
        guard let delegate = self.delegate,
              delegate.tabCheckIfItsBeingCurrentlyPresented(self),
              FilePreviewHelper.canAutoPreviewMIMEType(download.mimeType),
              let fileHandler = FilePreviewHelper.fileHandlerForDownload(download, viewController: self)
        else { return }

        if mostRecentAutoPreviewDownloadID == download.id {
            fileHandler.preview()
        } else {
            Pixel.fire(pixel: .downloadTriedToPresentPreviewWithoutTab)
        }
    }

}

// MARK: - PrivacyProtectionDelegate
extension TabViewController: PrivacyProtectionDelegate {

    func omniBarTextTapped() {
        chromeDelegate?.omniBar.becomeFirstResponder()
    }

}

// MARK: - WKUIDelegate
extension TabViewController: WKUIDelegate {

    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        return delegate?.tab(self,
                             didRequestNewWebViewWithConfiguration: configuration,
                             for: navigationAction,
                             inheritingAttribution: adClickAttributionLogic.state)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if openedByPage {
            delegate?.tabDidRequestClose(self)
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Pixel.fire(pixel: .webKitDidTerminate)
        delegate?.tabContentProcessDidTerminate(tab: self)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {

        // when we‘re in a navigation expectation state and a new alert arrives
        // we won‘t display it and navigation stack will hang, so just terminate web process
        guard navigationExpectationTimer == nil,
              canDisplayJavaScriptAlert
        else {
            completionHandler()
            return
        }

        let alert = WebJSAlert(domain: frame.request.url?.host
                               // in case the web view is navigating to another host
                               ?? webView.backForwardList.currentItem?.url.host
                               ?? self.url?.absoluteString
                               ?? "",
                               message: message,
                               alertType: .alert(handler: completionHandler))
        self.present(alert)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {

        // when we‘re in a navigation expectation state and a new alert arrives
        // we won‘t display it and navigation stack will hang, so just terminate web process
        guard navigationExpectationTimer == nil,
              canDisplayJavaScriptAlert
        else {
            completionHandler(false)
            return
        }

        let alert = WebJSAlert(domain: frame.request.url?.host
                               // in case the web view is navigating to another host
                               ?? webView.backForwardList.currentItem?.url.host
                               ?? self.url?.absoluteString
                               ?? "",
                               message: message,
                               alertType: .confirm(handler: completionHandler))
        self.present(alert)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {

        // when we‘re in a navigation expectation state and a new alert arrives
        // we won‘t display it and navigation stack will hang, so just terminate web process
        guard navigationExpectationTimer == nil,
              canDisplayJavaScriptAlert
        else {
            completionHandler(nil)
            return
        }

        let alert = WebJSAlert(domain: frame.request.url?.host
                               // in case the web view is navigating to another host
                               ?? webView.backForwardList.currentItem?.url.host
                               ?? self.url?.absoluteString
                               ?? "",
                               message: prompt,
                               alertType: .text(handler: completionHandler,
                                                defaultText: defaultText))
        self.present(alert)
    }
}

// MARK: - UIPopoverPresentationControllerDelegate
extension TabViewController: UIPopoverPresentationControllerDelegate {

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }
}

// MARK: - UIGestureRecognizerDelegate
extension TabViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if isShowBarsTap(gestureRecognizer) {
            return true
        }
        return false
    }

    private func isShowBarsTap(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let y = gestureRecognizer.location(in: webView).y
        return gestureRecognizer == showBarsTapGestureRecogniser && chromeDelegate?.isToolbarHidden == true && isBottom(yPosition: y)
    }

    private func isBottom(yPosition y: CGFloat) -> Bool {
        guard let chromeDelegate = chromeDelegate else { return false }
        return y > (view.frame.size.height - chromeDelegate.toolbarHeight)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer == showBarsTapGestureRecogniser else {
            return false
        }

        if gestureRecognizer == showBarsTapGestureRecogniser,
            otherRecognizer is UITapGestureRecognizer {
            return true
        }

        return false
    }

    func requestFindInPage() {
        guard findInPage == nil else { return }
        findInPage = FindInPage(webView: webView)
        delegate?.tabDidRequestFindInPage(tab: self)
    }

    func refresh() {
        let url: URL?
        if isError || webView.url == nil {
            url = URL(string: chromeDelegate?.omniBar.textField.text ?? "")
        } else {
            url = webView.url
        }

        requeryLogic.onRefresh()
        if isError || webView.url == nil, let url = url {
            load(url: url)
        } else {
            reload()
        }
    }

}

// MARK: - UserContentControllerDelegate
extension TabViewController: UserContentControllerDelegate {

    private var userScripts: UserScripts? {
        userContentController.contentBlockingAssets?.userScripts as? UserScripts
    }
    private var findInPageScript: FindInPageUserScript? {
        userScripts?.findInPageScript
    }
    private var contentBlockerUserScript: ContentBlockerRulesUserScript? {
        userScripts?.contentBlockerUserScript
    }
    private var autofillUserScript: AutofillUserScript? {
        userScripts?.autofillUserScript
    }

    func userContentController(_ userContentController: UserContentController,
                               didInstallContentRuleLists contentRuleLists: [String: WKContentRuleList],
                               userScripts: UserScriptsProvider,
                               updateEvent: ContentBlockerRulesManager.UpdateEvent) {
        guard let userScripts = userScripts as? UserScripts else { fatalError("Unexpected UserScripts") }

        userScripts.faviconScript.delegate = self
        userScripts.debugScript.instrumentation = instrumentation
        userScripts.surrogatesScript.delegate = self
        userScripts.contentBlockerUserScript.delegate = self
        userScripts.autofillUserScript.emailDelegate = emailManager
        userScripts.autofillUserScript.vaultDelegate = vaultManager
        userScripts.printingUserScript.delegate = self
        userScripts.textSizeUserScript.textSizeAdjustmentInPercents = appSettings.textSize
        userScripts.loginFormDetectionScript?.delegate = self

        adClickAttributionLogic.onRulesChanged(latestRules: ContentBlocking.shared.contentBlockingManager.currentRules)

        let tdsKey = DefaultContentBlockerRulesListsSource.Constants.trackerDataSetRulesListName
        let notificationsTriggeringReload = [
            PreserveLogins.Notifications.loginDetectionStateChanged,
            AppUserDefaults.Notifications.doNotSellStatusChange
        ]
        if updateEvent.changes[tdsKey]?.contains(.unprotectedSites) == true
            || notificationsTriggeringReload.contains(where: {
                updateEvent.changes[$0.rawValue]?.contains(.notification) == true
            }) {

            navigationExpectationTimer = nil
            reload()
        }
    }

}

// MARK: - ContentBlockerRulesUserScriptDelegate
extension TabViewController: ContentBlockerRulesUserScriptDelegate {
    
    func contentBlockerRulesUserScriptShouldProcessTrackers(_ script: ContentBlockerRulesUserScript) -> Bool {
        return siteRating?.isFor(self.url) ?? false
    }
    
    func contentBlockerRulesUserScriptShouldProcessCTLTrackers(_ script: ContentBlockerRulesUserScript) -> Bool {
        return false
    }

    func contentBlockerRulesUserScript(_ script: ContentBlockerRulesUserScript,
                                       detectedTracker tracker: DetectedRequest) {
        userScriptDetectedTracker(tracker)
    }
    
    func contentBlockerRulesUserScript(_ script: ContentBlockerRulesUserScript,
                                       detectedThirdPartyRequest request: DetectedRequest) {
        siteRating?.thirdPartyRequestDetected(request)
    }

    fileprivate func userScriptDetectedTracker(_ tracker: DetectedRequest) {
        adClickAttributionLogic.onRequestDetected(request: tracker)
        
        if tracker.isBlocked && fireWoFollowUp {
            fireWoFollowUp = false
            Pixel.fire(pixel: .daxDialogsWithoutTrackersFollowUp)
        }

        siteRating?.trackerDetected(tracker)
        onSiteRatingChanged()

        if !pageHasTrackers {
            NetworkLeaderboard.shared.incrementPagesWithTrackers()
            pageHasTrackers = true
        }

        if let networkName = tracker.ownerName {
            if !trackerNetworksDetectedOnPage.contains(networkName) {
                trackerNetworksDetectedOnPage.insert(networkName)
                NetworkLeaderboard.shared.incrementDetectionCount(forNetworkNamed: networkName)
            }
            NetworkLeaderboard.shared.incrementTrackersCount(forNetworkNamed: networkName)
        }
    }
}

// MARK: - SurrogatesUserScriptDelegate
extension TabViewController: SurrogatesUserScriptDelegate {

    func surrogatesUserScriptShouldProcessTrackers(_ script: SurrogatesUserScript) -> Bool {
        return siteRating?.isFor(self.url) ?? false
    }

    func surrogatesUserScript(_ script: SurrogatesUserScript,
                              detectedTracker tracker: DetectedRequest,
                              withSurrogate host: String) {
        if siteRating?.url.absoluteString == tracker.pageUrl {
            siteRating?.surrogateInstalled(host)
        }
        userScriptDetectedTracker(tracker)
    }

}

// MARK: - FaviconUserScriptDelegate
extension TabViewController: FaviconUserScriptDelegate {
    
    func faviconUserScriptDidRequestCurrentHost(_ script: FaviconUserScript) -> String? {
        return webView.url?.host
    }
    
    func faviconUserScript(_ script: FaviconUserScript, didFinishLoadingFavicon image: UIImage) {
        tabModel.didUpdateFavicon()
    }
    
}

// MARK: - PrintingUserScriptDelegate
extension TabViewController: PrintingUserScriptDelegate {

    func printingUserScriptDidRequestPrintController(_ script: PrintingUserScript) {
        let controller = UIPrintInteractionController.shared
        controller.printFormatter = webView.viewPrintFormatter()
        controller.present(animated: true, completionHandler: nil)
    }

}

// MARK: - AdClickAttributionLogicDelegate
extension TabViewController: AdClickAttributionLogicDelegate {

    func attributionLogic(_ logic: AdClickAttributionLogic,
                          didRequestRuleApplication rules: ContentBlockerRulesManager.Rules?,
                          forVendor vendor: String?) {
        let attributedTempListName = AdClickAttributionRulesProvider.Constants.attributedTempRuleListName

        guard ContentBlocking.shared.privacyConfigurationManager.privacyConfig.isEnabled(featureKey: .contentBlocking)
        else {
            userContentController.removeLocalContentRuleList(withIdentifier: attributedTempListName)
            contentBlockerUserScript?.currentAdClickAttributionVendor = nil
            contentBlockerUserScript?.supplementaryTrackerData = []
            return
        }

        contentBlockerUserScript?.currentAdClickAttributionVendor = vendor
        if let rules = rules {

            let globalListName = DefaultContentBlockerRulesListsSource.Constants.trackerDataSetRulesListName
            let globalAttributionListName = AdClickAttributionRulesSplitter.blockingAttributionRuleListName(forListNamed: globalListName)

            if vendor != nil {
                userContentController.installLocalContentRuleList(rules.rulesList, identifier: attributedTempListName)
                try? userContentController.disableGlobalContentRuleList(withIdentifier: globalAttributionListName)
            } else {
                userContentController.removeLocalContentRuleList(withIdentifier: attributedTempListName)
                try? userContentController.enableGlobalContentRuleList(withIdentifier: globalAttributionListName)
            }

            contentBlockerUserScript?.supplementaryTrackerData = [rules.trackerData]
        } else {
            contentBlockerUserScript?.supplementaryTrackerData = []
        }
    }

}

// MARK: - EmailManagerAliasPermissionDelegate
extension TabViewController: EmailManagerAliasPermissionDelegate {

    func emailManager(_ emailManager: EmailManager,
                      didRequestPermissionToProvideAliasWithCompletion completionHandler: @escaping (EmailManagerPermittedAddressType) -> Void) {

        DispatchQueue.main.async {
            let alert = UIAlertController(title: UserText.emailAliasAlertTitle, message: nil, preferredStyle: .actionSheet)
            alert.overrideUserInterfaceStyle()

            var pixelParameters: [String: String] = [:]

            if let cohort = emailManager.cohort {
                pixelParameters[PixelParameters.emailCohort] = cohort
            }

            if let userEmail = emailManager.userEmail {
                let actionTitle = String(format: UserText.emailAliasAlertUseUserAddress, userEmail)
                alert.addAction(title: actionTitle) {
                    pixelParameters[PixelParameters.emailLastUsed] = emailManager.lastUseDate
                    emailManager.updateLastUseDate()

                    Pixel.fire(pixel: .emailUserPressedUseAddress, withAdditionalParameters: pixelParameters, includedParameters: [])

                    completionHandler(.user)
                }
            }

            alert.addAction(title: UserText.emailAliasAlertGeneratePrivateAddress) {
                pixelParameters[PixelParameters.emailLastUsed] = emailManager.lastUseDate
                emailManager.updateLastUseDate()

                Pixel.fire(pixel: .emailUserPressedUseAlias, withAdditionalParameters: pixelParameters, includedParameters: [])

                completionHandler(.generated)
            }

            alert.addAction(title: UserText.emailAliasAlertDecline) {
                Pixel.fire(pixel: .emailTooltipDismissed, withAdditionalParameters: pixelParameters, includedParameters: [])

                completionHandler(.none)
            }

            if UIDevice.current.userInterfaceIdiom == .pad {
                // make sure the completion handler is called if the alert is dismissed by tapping outside the alert
                alert.addAction(title: "", style: .cancel) {
                    Pixel.fire(pixel: .emailTooltipDismissed, withAdditionalParameters: pixelParameters)
                    completionHandler(.none)
                }
            }

            alert.popoverPresentationController?.permittedArrowDirections = []
            alert.popoverPresentationController?.delegate = self
            let bounds = self.view.bounds
            let point = Point(x: Int((bounds.maxX - bounds.minX) / 2.0), y: Int(bounds.maxY))
            self.present(controller: alert, fromView: self.view, atPoint: point)
        }

    }

}

// MARK: - EmailManagerRequestDelegate
extension TabViewController: EmailManagerRequestDelegate {

    // swiftlint:disable function_parameter_count
    func emailManager(_ emailManager: EmailManager,
                      requested url: URL,
                      method: String,
                      headers: [String: String],
                      parameters: [String: String]?,
                      httpBody: Data?,
                      timeoutInterval: TimeInterval,
                      completion: @escaping (Data?, Error?) -> Void) {
        APIRequest.request(url: url,
                           method: APIRequest.HTTPMethod(rawValue: method) ?? .post,
                           parameters: parameters ?? [:],
                           headers: headers,
                           httpBody: httpBody,
                           timeoutInterval: timeoutInterval) { response, error in
            
            completion(response?.data, error)
        }
    }
    // swiftlint:enable function_parameter_count
    
    func emailManagerKeychainAccessFailed(accessType: EmailKeychainAccessType, error: EmailKeychainAccessError) {
        var parameters = [
            PixelParameters.emailKeychainAccessType: accessType.rawValue,
            PixelParameters.emailKeychainError: error.errorDescription
        ]
        
        if case let .keychainLookupFailure(status) = error {
            parameters[PixelParameters.emailKeychainKeychainStatus] = String(status)
            parameters[PixelParameters.emailKeychainKeychainOperation] = "lookup"
        }
        
        if case let .keychainDeleteFailure(status) = error {
            parameters[PixelParameters.emailKeychainKeychainStatus] = String(status)
            parameters[PixelParameters.emailKeychainKeychainOperation] = "delete"
        }
        
        if case let .keychainSaveFailure(status) = error {
            parameters[PixelParameters.emailKeychainKeychainStatus] = String(status)
            parameters[PixelParameters.emailKeychainKeychainOperation] = "save"
        }
        
        Pixel.fire(pixel: .emailAutofillKeychainError, withAdditionalParameters: parameters)
    }

}

// MARK: - Themable
extension TabViewController: Themable {

    func decorate(with theme: Theme) {
        view.backgroundColor = theme.backgroundColor
        error?.backgroundColor = theme.backgroundColor
        errorHeader.textColor = theme.barTintColor
        errorMessage.textColor = theme.barTintColor
        
        switch theme.currentImageSet {
        case .light:
            errorInfoImage?.image = UIImage(named: "ErrorInfoLight")
        case .dark:
            errorInfoImage?.image = UIImage(named: "ErrorInfoDark")
        }
    }
    
}

// MARK: - NSError+failedUrl
extension NSError {

    var failedUrl: URL? {
        return userInfo[NSURLErrorFailingURLErrorKey] as? URL
    }
    
}

extension TabViewController: SecureVaultManagerDelegate {
 
    private func presentSavePasswordModal(with vault: SecureVaultManager, credentials: SecureVaultModels.WebsiteCredentials) {
        guard isAutofillEnabled, let autofillUserScript = autofillUserScript else { return }

        let manager = SaveAutofillLoginManager(credentials: credentials, vaultManager: vault, autofillScript: autofillUserScript)
        manager.prepareData { [weak self] in

            let saveLoginController = SaveLoginViewController(credentialManager: manager, domainLastShownOn: self?.domainSaveLoginPromptLastShownOn)
            self?.domainSaveLoginPromptLastShownOn = self?.url?.host
            saveLoginController.delegate = self
            if #available(iOS 15.0, *) {
                if let presentationController = saveLoginController.presentationController as? UISheetPresentationController {
                    presentationController.detents = [.medium(), .large()]
                }
            }
            self?.present(saveLoginController, animated: true, completion: nil)
        }
    }
    
    func secureVaultInitFailed(_ error: SecureVaultError) {
        SecureVaultErrorReporter.shared.secureVaultInitFailed(error)
    }
    
    func secureVaultManagerIsEnabledStatus(_: SecureVaultManager) -> Bool {
        let isEnabled = featureFlagger.isFeatureOn(.autofill)
        let isBackgrounded = UIApplication.shared.applicationState == .background
        if isEnabled && isBackgrounded {
            Pixel.fire(pixel: .secureVaultIsEnabledCheckedWhenEnabledAndBackgrounded,
                       withAdditionalParameters: [PixelParameters.isBackgrounded: "true"])
        }
        return isEnabled
    }
    
    func secureVaultManager(_ vault: SecureVaultManager, promptUserToStoreAutofillData data: AutofillData) {
        if let credentials = data.credentials, isAutofillEnabled {
            // Add a delay to allow propagation of pointer events to the page
            // see https://app.asana.com/0/1202427674957632/1202532842924584/f
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.presentSavePasswordModal(with: vault, credentials: credentials)
            }
        }
    }
    
    func secureVaultManager(_: SecureVaultManager,
                            promptUserToAutofillCredentialsForDomain domain: String,
                            withAccounts accounts: [SecureVaultModels.WebsiteAccount],
                            withTrigger trigger: AutofillUserScript.GetTriggerType,
                            completionHandler: @escaping (SecureVaultModels.WebsiteAccount?) -> Void) {
  
        if !isAutofillEnabled {
            completionHandler(nil)
            return
        }

        // if user is interacting with the searchBar, don't show the autofill prompt since it will overlay the keyboard
        if let parent = parent as? MainViewController, parent.omniBar.textField.isFirstResponder {
            completionHandler(nil)
            return
        }

        if accounts.count > 0 {
            
            let autofillPromptViewController = AutofillLoginPromptViewController(accounts: accounts, trigger: trigger) { account in
                completionHandler(account)
            }
            
            if #available(iOS 15.0, *) {
                if let presentationController = autofillPromptViewController.presentationController as? UISheetPresentationController {
                    presentationController.detents = accounts.count > 3 ? [.medium(), .large()] : [.medium()]
                }
            }
            self.present(autofillPromptViewController, animated: true, completion: nil)
        } else {
            completionHandler(nil)
        }
    }

    func secureVaultManager(_: SecureVaultManager, didAutofill type: AutofillType, withObjectId objectId: Int64) {
        // No-op, don't need to do anything here
    }
    
    func secureVaultManagerShouldAutomaticallyUpdateCredentialsWithoutUsername(_: SecureVaultManager) -> Bool {
        false
    }
    
    // swiftlint:disable:next identifier_name
    func secureVaultManager(_: SecureVaultManager, didRequestAuthenticationWithCompletionHandler: @escaping (Bool) -> Void) {
        // We don't have auth yet
    }
}

extension TabViewController: SaveLoginViewControllerDelegate {

    private func saveCredentials(_ credentials: SecureVaultModels.WebsiteCredentials, withSuccessMessage message: String) {
        do {
            let credentialID = try SaveAutofillLoginManager.saveCredentials(credentials,
                                                                            with: SecureVaultFactory.default)
            
            let vault = try SecureVaultFactory.default.makeVault(errorReporter: SecureVaultErrorReporter.shared)
            
            if let newCredential = try vault.websiteCredentialsFor(accountId: credentialID) {
                DispatchQueue.main.async {
                    ActionMessageView.present(message: message,
                                              actionTitle: UserText.autofillLoginSaveToastActionButton, onAction: {
                        
                        self.showLoginDetails(with: newCredential.account)
                    })
                }
            }
        } catch {
            os_log("%: failed to store credentials %s", type: .error, #function, error.localizedDescription)
        }
    }
    
    func saveLoginViewController(_ viewController: SaveLoginViewController, didSaveCredentials credentials: SecureVaultModels.WebsiteCredentials) {
        viewController.dismiss(animated: true)
        saveCredentials(credentials, withSuccessMessage: UserText.autofillLoginSavedToastMessage)
    }
    
    func saveLoginViewController(_ viewController: SaveLoginViewController, didUpdateCredentials credentials: SecureVaultModels.WebsiteCredentials) {
        viewController.dismiss(animated: true)
        saveCredentials(credentials, withSuccessMessage: UserText.autofillLoginUpdatedToastMessage)
    }
    
    func saveLoginViewControllerDidCancel(_ viewController: SaveLoginViewController) {
        viewController.dismiss(animated: true)
    }
    
    func saveLoginViewController(_ viewController: SaveLoginViewController,
                                 didRequestPresentConfirmKeepUsingAlertController alertController: UIAlertController) {
        Pixel.fire(pixel: .autofillLoginsFillLoginInlineDisablePromptShown)
        present(alertController, animated: true)
    }
}

extension WKWebView {

    func load(_ url: URL, in frame: WKFrameInfo?) {
        evaluateJavaScript("window.location.href='" + url.absoluteString + "'", in: frame, in: .page)
    }

}

extension UserContentController {

    public convenience init(privacyConfigurationManager: PrivacyConfigurationManaging = ContentBlocking.shared.privacyConfigurationManager) {
        self.init(assetsPublisher: ContentBlocking.shared.contentBlockingUpdating.userContentBlockingAssets,
                  privacyConfigurationManager: privacyConfigurationManager)
    }

}

// swiftlint:enable file_length
