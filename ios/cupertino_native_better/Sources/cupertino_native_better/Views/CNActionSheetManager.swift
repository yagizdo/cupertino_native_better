import Flutter
import UIKit

/// Presents a native `UIAlertController` in `.actionSheet` style on request
/// from Dart over the `cn_action_sheet` channel.
///
/// There is no platform view here: an action sheet is a modal presentation, so
/// it is presented on the top view controller rather than embedded in the
/// Flutter view hierarchy. That also means it is unaffected by the iOS hybrid
/// composition bleed that forces `ModalHideMixin` to tear down inline CN
/// widgets behind Flutter-drawn modals — this sheet is real UIKit, above
/// everything.
///
/// Liquid Glass is deliberately absent from this file. On iOS 26 the system
/// applies the new appearance to alerts and action sheets with no opt-in, so
/// the correct amount of glass code is none.
///
/// Modelled on `CNNativeTabBarManager`: a singleton owning its own method
/// channel, wired up from `CupertinoNativePlugin.register`.
final class CNActionSheetManager: NSObject {

    static let shared = CNActionSheetManager()

    private var channel: FlutterMethodChannel?

    /// The result of the sheet currently on screen. Nil whenever no sheet is
    /// pending. Cleared by `send(_:)` so a tap followed by a dismissal callback
    /// cannot deliver two results down one `FlutterResult` — the engine treats
    /// a double send as a hard error.
    private var pendingResult: FlutterResult?

    func setup(messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "cn_action_sheet", binaryMessenger: messenger)
        channel = ch
        ch.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "show":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "invalid_args", message: "Expected a map", details: nil))
                return
            }
            show(config: Config(args: args), result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Presentation

    private func show(config: Config, result: @escaping FlutterResult) {
        guard let presenter = topPresenter() else {
            result(FlutterError(code: "no_presenter",
                                message: "No view controller available to present on",
                                details: nil))
            return
        }

        // A sheet already on screen means the previous caller is still waiting.
        // Answer it with nil before taking ownership of `pendingResult`.
        send(nil)
        pendingResult = result

        let alert = UIAlertController(title: config.title,
                                      message: config.message,
                                      preferredStyle: .actionSheet)

        for (index, entry) in config.actions.enumerated() {
            let action = UIAlertAction(
                title: entry.label,
                style: entry.destructive ? .destructive : .default
            ) { [weak self] _ in
                self?.send(index)
            }
            action.isEnabled = entry.enabled
            alert.addAction(action)
        }

        if let cancelLabel = config.cancelLabel {
            alert.addAction(UIAlertAction(title: cancelLabel, style: .cancel) { [weak self] _ in
                self?.send(nil)
            })
        }

        applyAnchor(config.anchorRect, to: alert, presenter: presenter)

        // Catches a dismissal that fires no action handler — tapping outside an
        // anchored popover, or a swipe-down.
        alert.presentationController?.delegate = self

        presenter.present(alert, animated: true)
    }

    /// Anchors the sheet per the iOS 26 rules.
    ///
    /// WWDC25: "ActionSheets on iPad are anchored to their source views.
    /// Starting in iOS 26, they behave the same on iPhone, appearing directly
    /// over the originating view." Assigning a source view is also what applies
    /// the new transitions, so `anchorRect` matters on every device — it is not
    /// an iPad-only escape hatch.
    ///
    /// Omitting the source is supported: the system centres the sheet and adds
    /// a cancel button. The one case that needs a synthetic source is a
    /// regular-width layout before iOS 26, where UIKit raises
    /// `NSInternalInconsistencyException` without one.
    private func applyAnchor(_ anchorRect: CGRect?,
                             to alert: UIAlertController,
                             presenter: UIViewController) {
        guard let popover = alert.popoverPresentationController else { return }

        // The rect arrives in Flutter's logical pixels, which are UIKit points,
        // measured against the Flutter view. Anchor to that view when it can be
        // found so the coordinates line up.
        let sourceView = findFlutterVC(keyWindow()?.rootViewController)?.view ?? presenter.view

        if let rect = anchorRect, let sourceView {
            popover.sourceView = sourceView
            popover.sourceRect = rect
        } else if presenter.traitCollection.horizontalSizeClass == .regular, let sourceView {
            popover.sourceView = sourceView
            popover.sourceRect = CGRect(x: sourceView.bounds.midX,
                                        y: sourceView.bounds.maxY,
                                        width: 0,
                                        height: 0)
            popover.permittedArrowDirections = []
        }
        // Compact width with no anchor: left untouched on purpose. iOS 26
        // centres it with a cancel button; earlier iOS slides it up from the
        // bottom.
    }

    /// Delivers `value` to the waiting Dart call exactly once.
    private func send(_ value: Int?) {
        guard let result = pendingResult else { return }
        pendingResult = nil
        result(value)
    }

    // MARK: - View controller lookup

    // Duplicated from `CNNativeTabBarManager`, where both helpers are private.
    // Ten lines of copy beats changing a shipped file to share them.

    private func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = (scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene)
            ?? (scenes.first as? UIWindowScene)
        return windowScene?.windows.first(where: { $0.isKeyWindow }) ?? windowScene?.windows.first
    }

    private func topPresenter() -> UIViewController? {
        guard var vc = keyWindow()?.rootViewController else { return nil }
        while let presented = vc.presentedViewController { vc = presented }
        return vc
    }

    private func findFlutterVC(_ vc: UIViewController?) -> UIViewController? {
        guard let vc else { return nil }
        if vc is FlutterViewController { return vc }
        for child in vc.children {
            if let found = findFlutterVC(child) { return found }
        }
        return nil
    }

    // MARK: - Payload

    /// Mirrors `debugBuildActionSheetPayload` in `lib/components/action_sheet.dart`.
    private struct Config {
        struct Action {
            let label: String
            let destructive: Bool
            let enabled: Bool
        }

        let title: String?
        let message: String?
        let cancelLabel: String?
        let actions: [Action]
        let anchorRect: CGRect?

        init(args: [String: Any]) {
            title = args["title"] as? String
            message = args["message"] as? String
            cancelLabel = args["cancelLabel"] as? String

            let raw = args["actions"] as? [[String: Any]] ?? []
            actions = raw.map { entry in
                Action(label: entry["label"] as? String ?? "",
                       destructive: entry["destructive"] as? Bool ?? false,
                       enabled: entry["enabled"] as? Bool ?? true)
            }

            if let rect = args["anchorRect"] as? [String: Any],
               let x = rect["x"] as? Double,
               let y = rect["y"] as? Double,
               let width = rect["width"] as? Double,
               let height = rect["height"] as? Double {
                anchorRect = CGRect(x: x, y: y, width: width, height: height)
            } else {
                anchorRect = nil
            }
        }
    }
}

// MARK: - Dismissal without a selection

extension CNActionSheetManager: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        send(nil)
    }
}
