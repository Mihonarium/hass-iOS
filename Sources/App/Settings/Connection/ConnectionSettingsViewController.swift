import Alamofire
import Eureka
import HAKit
import MBProgressHUD
import PromiseKit
import Shared
import UIKit
import Version

class ConnectionSettingsViewController: HAFormViewController, RowControllerType {
    public var onDismissCallback: ((UIViewController) -> Void)?

    let server: Server

    private lazy var shareButton = UIBarButtonItem(
        image: UIImage(systemName: "square.and.arrow.up"),
        style: .plain,
        target: self,
        action: #selector(shareServer)
    )

    private enum AdditionalHeadersRowTag: String {
        case additionalHeaders
    }

    private enum AdditionalHeadersParsingError: LocalizedError {
        case invalidFormat

        var errorDescription: String? {
            L10n.Settings.ConnectionSection.AdditionalHeaders.validationError
        }
    }

    init(server: Server) {
        self.server = server

        super.init()
    }

    private var tokens: [HACancellable] = []

    deinit {
        tokens.forEach { $0.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = server.info.name

        tokens.append(server.observe { [weak self] info in
            if let row = self?.form.rowBy(tag: AdditionalHeadersRowTag.additionalHeaders.rawValue) as? TextAreaRow {
                row.value = Self.formattedAdditionalHeaders(for: info.connection.httpAdditionalHeaders)
                row.updateCell()
            }

            self?.form.allRows.forEach { $0.updateCell() }
            self?.title = info.name
        })

        let connection = Current.api(for: server)?.connection

        addActivateButton()
        addInvitationButtonToNavBar()

        form
            +++ Section(header: L10n.Settings.StatusSection.header, footer: "") {
                $0.tag = "status"
            }

            <<< LabelRow("connectionPath") {
                $0.title = L10n.Settings.ConnectionSection.connectingVia
                $0.displayValueFor = { [server] _ in server.info.connection.activeURLType.description }
            }

            <<< LabelRow("version") {
                $0.title = L10n.Settings.StatusSection.VersionRow.title
                $0.displayValueFor = { [server] _ in server.info.version.description }
            }

            <<< with(WebSocketStatusRow()) {
                $0.connection = connection
            }

            <<< LabelRow { row in
                row.title = L10n.SettingsDetails.Notifications.LocalPush.title
                let manager = Current.notificationManager.localPushManager

                let updateValue = { [weak row, server] in
                    guard let row else { return }
                    switch manager.status(for: server) {
                    case .disabled:
                        row.value = L10n.SettingsDetails.Notifications.LocalPush.Status.disabled
                    case .unsupported:
                        row.value = L10n.SettingsDetails.Notifications.LocalPush.Status.unsupported
                    case let .allowed(state):
                        switch state {
                        case .unavailable:
                            row.value = L10n.SettingsDetails.Notifications.LocalPush.Status.unavailable
                        case .establishing:
                            row.value = L10n.SettingsDetails.Notifications.LocalPush.Status.establishing
                        case let .available(received: received):
                            let formatted = NumberFormatter.localizedString(
                                from: NSNumber(value: received),
                                number: .decimal
                            )
                            row.value = L10n.SettingsDetails.Notifications.LocalPush.Status.available(formatted)
                        }
                    }

                    row.updateCell()
                }

                let cancel = manager.addObserver(for: server) { _ in
                    updateValue()
                }
                after(life: self).done(cancel.cancel)
                updateValue()
            }

            <<< LabelRow { row in
                row.title = L10n.Settings.ConnectionSection.loggedInAs

                if let connection {
                    tokens.append(connection.caches.user.subscribe { _, user in
                        row.value = user.name
                        row.updateCell()
                    })
                }
            }

            +++ Section(L10n.Settings.ConnectionSection.details)

            <<< TextRow("locationName") {
                $0.title = L10n.Settings.StatusSection.LocationNameRow.title
                $0.placeholder = server.info.remoteName
                $0.value = server.info.setting(for: .localName)

                var timer: Timer?

                $0.onChange { [server] row in
                    if let timer, timer.isValid {
                        timer.fireDate = Current.date().addingTimeInterval(1.0)
                    } else {
                        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false, block: { _ in
                            server.info.setSetting(value: row.value, for: .localName)
                        })
                    }
                }
            }

            <<< TextRow {
                $0.title = L10n.SettingsDetails.General.DeviceName.title
                $0.placeholder = Current.device.deviceName()
                $0.value = server.info.setting(for: .overrideDeviceName)
                $0.onChange { [server] row in
                    server.info.setSetting(value: row.value, for: .overrideDeviceName)
                }
            }

            <<< ButtonRowWithPresent<ConnectionURLViewController> { row in
                row.cellStyle = .value1
                row.title = L10n.Settings.ConnectionSection.InternalBaseUrl.title
                row.displayValueFor = { [server] _ in
                    if server.info.connection.internalSSIDs?.isEmpty ?? true,
                       server.info.connection.internalHardwareAddresses?.isEmpty ?? true,
                       !server.info.connection.alwaysFallbackToInternalURL,
                       !ConnectionInfo.shouldFallbackToInternalURL {
                        return "‼️ \(L10n.Settings.ConnectionSection.InternalBaseUrl.RequiresSetup.title)"
                    } else {
                        return server.info.connection.address(for: .internal)?.absoluteString ?? "—"
                    }
                }
                row.presentationMode = .show(controllerProvider: .callback(builder: { [server] in
                    ConnectionURLViewController(server: server, urlType: .internal, row: row)
                }), onDismiss: { [navigationController] _ in
                    navigationController?.popViewController(animated: true)
                })

                row.evaluateHidden()
            }

            <<< ButtonRowWithPresent<ConnectionURLViewController> { row in
                row.cellStyle = .value1
                row.title = L10n.Settings.ConnectionSection.ExternalBaseUrl.title
                row.displayValueFor = { [server] _ in
                    if server.info.connection.useCloud, server.info.connection.canUseCloud {
                        return L10n.Settings.ConnectionSection.HomeAssistantCloud.title
                    } else {
                        return server.info.connection.address(for: .external)?.absoluteString ?? "—"
                    }
                }
                row.presentationMode = .show(controllerProvider: .callback(builder: { [server] in
                    ConnectionURLViewController(server: server, urlType: .external, row: row)
                }), onDismiss: { [navigationController] _ in
                    navigationController?.popViewController(animated: true)
                })
            }

            +++ Section(
                header: L10n.Settings.ConnectionSection.AdditionalHeaders.header,
                footer: L10n.Settings.ConnectionSection.AdditionalHeaders.footer
            )

            <<< TextAreaRow(AdditionalHeadersRowTag.additionalHeaders.rawValue) { row in
                row.placeholder = L10n.Settings.ConnectionSection.AdditionalHeaders.placeholder
                row.value = Self.formattedAdditionalHeaders(for: server.info.connection.httpAdditionalHeaders)
                row.textAreaHeight = .dynamic(initialTextViewHeight: 88)
                row.add(rule: RuleClosure<String> { value in
                    guard let value, value.contains(where: { !$0.isWhitespace && !$0.isNewline }) else {
                        return nil
                    }

                    do {
                        _ = try Self.parseAdditionalHeaders(from: value)
                        return nil
                    } catch {
                        return ValidationError(msg: error.localizedDescription)
                    }
                })
                row.validationOptions = .validatesOnChange
            }.cellSetup { cell, _ in
                cell.textView.autocapitalizationType = .none
                cell.textView.autocorrectionType = .no
                cell.textView.spellCheckingType = .no
            }.onChange { [weak self, server] row in
                self?.handleAdditionalHeadersChange(row: row, for: server)
            }

            +++ Section(L10n.SettingsDetails.Privacy.title)

            <<< PushRow<ServerLocationPrivacy> {
                $0.title = L10n.Settings.ConnectionSection.LocationSendType.title
                $0.selectorTitle = $0.title
                $0.value = server.info.setting(for: .locationPrivacy)
                $0.options = ServerLocationPrivacy.allCases
                $0.displayValueFor = { $0?.localizedDescription }
                $0.onPresent { [server] _, to in
                    to.enableDeselection = false
                    if server.info.version <= .updateLocationGPSOptional {
                        to.sectionKeyForValue = { _ in
                            // so we get asked for section titles
                            "section"
                        }
                        to.selectableRowSetup = { row in
                            row.disabled = true
                        }
                        to.sectionHeaderTitleForKey = { _ in
                            nil
                        }
                        to.sectionFooterTitleForKey = { _ in
                            Version.updateLocationGPSOptional.coreRequiredString
                        }
                    }
                }
                $0.onChange { [server] row in
                    server.info.setSetting(value: row.value, for: .locationPrivacy)
                    HomeAssistantAPI.manuallyUpdate(
                        applicationState: UIApplication.shared.applicationState,
                        type: .programmatic
                    ).cauterize()
                }
            }

            <<< PushRow<ServerSensorPrivacy> {
                $0.title = L10n.Settings.ConnectionSection.SensorSendType.title
                $0.selectorTitle = $0.title
                $0.value = server.info.setting(for: .sensorPrivacy)
                $0.options = ServerSensorPrivacy.allCases
                $0.displayValueFor = { $0?.localizedDescription }
                $0.onPresent { _, to in
                    to.enableDeselection = false
                }
                $0.onChange { [server] row in
                    server.info.setSetting(value: row.value, for: .sensorPrivacy)
                    Current.api(for: server)?.registerSensors().cauterize()
                }
            }

            +++ Section()

            <<< ButtonRow {
                $0.title = L10n.Settings.ConnectionSection.DeleteServer.title
                $0.onCellSelection { [navigationController, server, view] cell, _ in
                    let alert = UIAlertController(
                        title: L10n.Settings.ConnectionSection.DeleteServer.title,
                        message: L10n.Settings.ConnectionSection.DeleteServer.message,
                        preferredStyle: .actionSheet
                    )

                    with(alert.popoverPresentationController) {
                        $0?.sourceView = cell
                        $0?.sourceRect = cell.bounds
                    }

                    alert
                        .addAction(UIAlertAction(
                            title: L10n.Settings.ConnectionSection.DeleteServer.title,
                            style: .destructive,
                            handler: { _ in
                                let hud = MBProgressHUD.showAdded(to: view!, animated: true)
                                hud.label.text = L10n.Settings.ConnectionSection.DeleteServer.progress
                                hud.show(animated: true)

                                let waitAtLeast = after(seconds: 3.0)

                                firstly {
                                    race(
                                        when(resolved: Current.apis.map { $0.tokenManager.revokeToken() }).asVoid(),
                                        after(seconds: 10.0)
                                    )
                                }.then {
                                    waitAtLeast
                                }.get {
                                    Current.api(for: server)?.connection.disconnect()
                                    Current.servers.remove(identifier: server.identifier)
                                }.ensure {
                                    hud.hide(animated: true)
                                }.done {
                                    Current.onboardingObservation.needed(.logout)
                                    navigationController?.popViewController(animated: true)
                                }.cauterize()
                            }
                        ))

                    alert.addAction(UIAlertAction(title: L10n.cancelLabel, style: .cancel, handler: nil))
                    cell.formViewController()?.present(alert, animated: true, completion: nil)
                }
                $0.cellUpdate { cell, _ in
                    cell.textLabel?.textColor = .systemRed
                }
            }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Detect when your view controller is popped and invoke the callback
        if !isMovingToParent {
            onDismissCallback?(self)
        }
    }

    private func handleAdditionalHeadersChange(row: TextAreaRow, for server: Server) {
        _ = row.validate()

        let trimmed = row.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmed.isEmpty {
            server.update { info in
                info.connection.httpAdditionalHeaders = nil
            }
            return
        }

        do {
            let parsed = try Self.parseAdditionalHeaders(from: trimmed)
            let sanitized = parsed.isEmpty ? nil : parsed

            if sanitized == server.info.connection.httpAdditionalHeaders {
                return
            }

            server.update { info in
                info.connection.httpAdditionalHeaders = sanitized
            }
        } catch {
            // validation handles displaying feedback; leave value unchanged
        }
    }

    private static func formattedAdditionalHeaders(for headers: [String: String]?) -> String? {
        guard let headers, !headers.isEmpty else {
            return nil
        }

        return headers
            .sorted { lhs, rhs in
                lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private static func parseAdditionalHeaders(from text: String) throws -> [String: String] {
        var headers: [String: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !line.isEmpty else {
                continue
            }

            guard let separator = line.firstIndex(of: ":") else {
                throw AdditionalHeadersParsingError.invalidFormat
            }

            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)

            guard !name.isEmpty, !value.isEmpty else {
                throw AdditionalHeadersParsingError.invalidFormat
            }

            headers[String(name)] = String(value)
        }

        return headers
    }

    private func addInvitationButtonToNavBar() {
        navigationItem.rightBarButtonItem = shareButton
    }

    @objc private func shareServer() {
        guard let invitationServerURL = server.info.connection.invitationURL() else {
            Current.Log.error("Invitation button failed, no invitation URL found for server \(server.identifier)")
            return
        }

        guard let invitationURL = AppConstants.invitationURL(serverURL: invitationServerURL) else {
            Current.Log
                .error("Invitation button failed, could not create invitation URL for server \(server.identifier)")
            return
        }

        let activityVC = UIActivityViewController(activityItems: [invitationURL], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(
                x: view.bounds.midX,
                y: view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        present(activityVC, animated: true, completion: nil)
    }

    private func addActivateButton() {
        if Current.servers.all.count > 1 {
            form +++ Section {
                _ in
            } <<< ButtonRow {
                $0.title = L10n.Settings.ConnectionSection.activateServer
                $0.onCellSelection { [weak self] _, _ in
                    self?.activateServerTapped()
                }
            }
        }
    }

    @objc private func activateServerTapped() {
        if Current.isCatalyst, Current.settingsStore.macNativeFeaturesOnly {
            if let url = server.info.connection.activeURL() {
                UIApplication.shared.open(url)
            }
        } else {
            Current.sceneManager.webViewWindowControllerPromise.done {
                $0.open(server: self.server)
            }
        }
    }
}
