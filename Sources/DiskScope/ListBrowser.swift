import SwiftUI

/// Finder-style list view: sortable columns with a usage bar.
struct ListBrowser: View {
    @EnvironmentObject var model: AppModel
    let current: FileNode

    private var sizeKey: KeyPath<FileNode, Int64> {
        model.showApparentSize ? \FileNode.apparentSize : \FileNode.diskSize
    }

    private func nodes(_ ids: Set<FileNode.ID>) -> [FileNode] {
        current.children.filter { ids.contains($0.id) }
    }

    var body: some View {
        let rows = model.sortedChildren(of: current)
        let total = Double(max(model.size(of: current), 1))
        Table(rows, selection: $model.listSelection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { node in
                HStack(spacing: 6) {
                    FileIcon(node: node, size: 16)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    if node.errorCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Some items inside couldn't be read")
                    }
                }
            }
            .width(min: 180, ideal: 320)

            TableColumn("Size", value: sizeKey) { node in
                Text(Format.bytes(model.size(of: node)))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 85, max: 120)

            TableColumn("Usage", value: sizeKey) { node in
                UsageBar(fraction: Double(model.size(of: node)) / total)
            }
            .width(min: 90, ideal: 160, max: 260)

            TableColumn("Items", value: \.itemCount) { node in
                Text(node.isDirectory ? Format.count(node.itemCount) : "--")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70, max: 100)

            TableColumn("Date Modified", value: \.modified) { node in
                Text(node.modified == .distantPast ? "--" :
                        node.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 150, max: 200)

            TableColumn("Kind") { node in
                Text(IconCache.kind(of: node)).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 110, max: 180)
        }
        .contextMenu(forSelectionType: FileNode.ID.self) { ids in
            let picked = nodes(ids)
            if !picked.isEmpty { ItemMenu(nodes: picked) }
        } primaryAction: { ids in
            if let n = nodes(ids).first { model.open(n) }
        }
        .onKeyPress(.return) {
            guard let n = nodes(model.listSelection).first else { return .ignored }
            model.open(n)
            return .handled
        }
        .onDeleteCommand { model.requestTrash(nodes(model.listSelection)) }
    }
}

/// Search results across the scan, biggest first.
struct SearchResultsView: View {
    @EnvironmentObject var model: AppModel

    private func nodes(_ ids: Set<FileNode.ID>) -> [FileNode] {
        model.searchResults.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Search:").foregroundStyle(.secondary)
                Picker("Scope", selection: $model.searchWholeScan) {
                    Text(model.root.map(PathBar.rootTitle) ?? "Scan").tag(true)
                    Text("“\(model.current?.name ?? "")”").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if model.searching {
                    ProgressView().controlSize(.small)
                } else if model.searchMatchCount > model.searchResults.count {
                    Text("Showing the \(Format.count(model.searchResults.count)) largest of \(Format.count(model.searchMatchCount)) matches")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(Format.count(model.searchMatchCount)) matches").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            Table(model.searchResults, selection: $model.searchSelection) {
                TableColumn("Name") { node in
                    HStack(spacing: 6) {
                        FileIcon(node: node, size: 16)
                        Text(node.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 160, ideal: 260)
                TableColumn("Size") { node in
                    Text(Format.bytes(model.size(of: node)))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 85, max: 120)
                TableColumn("Where") { node in
                    Text((node.path as NSString).deletingLastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .width(min: 160, ideal: 360)
            }
            .contextMenu(forSelectionType: FileNode.ID.self) { ids in
                let picked = nodes(ids)
                if picked.count == 1, let n = picked.first {
                    Button("Show in DiskScope") { model.reveal(inBrowser: n) }
                }
                if !picked.isEmpty { ItemMenu(nodes: picked) }
            } primaryAction: { ids in
                if let n = nodes(ids).first { model.reveal(inBrowser: n) }
            }
            .onDeleteCommand { model.requestTrash(nodes(model.searchSelection)) }
            .overlay {
                if !model.searching && model.searchResults.isEmpty {
                    Text("No Results").font(.title3).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
