import SwiftUI
import MessageUI

/// SwiftUI wrapper around MFMailComposeViewController. Presents a
/// pre-filled mail composer with recipient, subject, body, and
/// optional file attachment. Used by Send Debug to give the user a
/// one-tap "send to developer" flow without exposing the developer's
/// email outside the app or requiring the user to know it.
///
/// Caller checks `MailComposer.canSend()` before presenting; if false,
/// fall back to UIActivityViewController (which lets the user pick any
/// mail/messaging app, but doesn't pre-fill recipient).
struct MailComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    let attachmentURL: URL?
    let onCompletion: () -> Void

    /// True if the device has a Mail account configured. False on phones
    /// where the user has removed Mail.app or never set up an account
    /// — the share-sheet fallback handles that case.
    static func canSend() -> Bool {
        MFMailComposeViewController.canSendMail()
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(recipients)
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        if let url = attachmentURL, let data = try? Data(contentsOf: url) {
            vc.addAttachmentData(data, mimeType: "application/zip", fileName: url.lastPathComponent)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onCompletion: () -> Void
        init(onCompletion: @escaping () -> Void) {
            self.onCompletion = onCompletion
        }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            controller.dismiss(animated: true) { [onCompletion] in
                onCompletion()
            }
        }
    }
}
