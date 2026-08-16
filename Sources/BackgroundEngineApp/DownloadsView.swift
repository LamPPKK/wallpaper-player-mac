import BackgroundEngineCore
import SwiftUI

struct DownloadsView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        Form {
            Section("Steam Workshop") {
                TextField("Workshop URL or numeric item ID", text: $model.workshopInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.requestWorkshopDownload() }

                HStack {
                    Button("Download with SteamCMD") {
                        model.requestWorkshopDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking || model.workshopInput.isEmpty)

                    if model.workshopDownloadStatus.phase == .downloading
                        || model.workshopDownloadStatus.phase == .installingSteamCMD {
                        Button("Cancel", role: .cancel) {
                            model.cancelWorkshopDownload()
                        }
                    }
                }
            }

            Section("Status") {
                HStack(spacing: 12) {
                    if model.workshopDownloadStatus.phase == .downloading
                        || model.workshopDownloadStatus.phase == .installingSteamCMD {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: statusSymbol)
                            .foregroundStyle(statusColor)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.workshopDownloadStatus.phase.rawValue.humanized)
                            .font(.headline)
                        Text(model.workshopDownloadStatus.message)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Ownership and privacy") {
                Label(
                    "Downloads use anonymous SteamCMD only. Background Engine never asks for or stores a Steam username or password.",
                    systemImage: "hand.raised"
                )
                Label(
                    "Valve may reject anonymous downloads. For owned items, copy the installed project folder from Windows and import it in Library.",
                    systemImage: "shippingbox"
                )
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Install Valve SteamCMD?",
            isPresented: $model.pendingSteamCMDConfirmation,
            titleVisibility: .visible
        ) {
            Button("Install SteamCMD and Download") {
                model.confirmWorkshopDownload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Background Engine will download Valve's SteamCMD runtime into Application Support, then request this item anonymously. It will not bypass ownership or Workshop permissions."
            )
        }
    }

    private var statusSymbol: String {
        switch model.workshopDownloadStatus.phase {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        default: "arrow.down.circle"
        }
    }

    private var statusColor: Color {
        switch model.workshopDownloadStatus.phase {
        case .completed: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

private extension String {
    var humanized: String {
        unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty { result.append(" ") }
            result.append(Character(scalar))
        }.capitalized
    }
}
