import QuickLook
import SwiftUI
import UIKit

/// Native QuickLook wrapper with explicit Done button so `.fullScreenCover` never traps the user.
struct QuickLookPreviewItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.close)
        )
        let nav = UINavigationController(rootViewController: controller)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.dismissAction = dismiss
        if context.coordinator.url != url {
            context.coordinator.url = url
            (uiViewController.topViewController as? QLPreviewController)?.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, dismissAction: dismiss)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        var dismissAction: DismissAction

        init(url: URL, dismissAction: DismissAction) {
            self.url = url
            self.dismissAction = dismissAction
        }

        @objc func close() {
            dismissAction()
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
