import SwiftUI

/// Finder-style column (Miller) view. Column i lists the children of `current.ancestry[i]`;
/// a selected file adds a preview column on the right.
struct ColumnBrowser: View {
    @EnvironmentObject var model: AppModel
    let current: FileNode
    @FocusState private var focusedColumn: Int?

    private let columnWidth: CGFloat = 270

    var body: some View {
        let columns = current.ancestry
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { i, node in
                        BrowserColumn(
                            node: node,
                            selectedID: i + 1 < columns.count ? columns[i + 1].id : model.selectedFile?.id,
                            onLeft: { moveLeft(from: i, columns: columns) },
                            onRight: { moveRight(from: i, columns: columns) }
                        )
                        .focused($focusedColumn, equals: i)
                        .frame(width: columnWidth)
                        .id(i)
                        Divider()
                    }
                    if let file = model.selectedFile {
                        FilePreview(node: file)
                            .frame(width: 300)
                            .id("preview")
                        Divider()
                    }
                }
            }
            .onChange(of: columns.count) { scrollToEnd(proxy, columns.count) }
            .onChange(of: model.selectedFile?.id) { scrollToEnd(proxy, columns.count) }
            .onAppear {
                scrollToEnd(proxy, columns.count)
                if focusedColumn == nil { focusedColumn = max(columns.count - 2, 0) }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ count: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            if model.selectedFile != nil { proxy.scrollTo("preview", anchor: .trailing) }
            else { proxy.scrollTo(count - 1, anchor: .trailing) }
        }
    }

    /// ←: go back to the parent column, closing the columns to its right (Finder behaviour).
    private func moveLeft(from i: Int, columns: [FileNode]) {
        guard i > 0 else { return }
        model.navigate(to: columns[i])
        focusedColumn = i - 1
    }

    /// →: step into the selected folder and select its first item.
    private func moveRight(from i: Int, columns: [FileNode]) {
        guard i + 1 < columns.count else { return }
        let folder = columns[i + 1]
        guard let first = model.sortedChildren(of: folder).first else { return }
        model.select(first, in: folder)
        focusedColumn = i + 1
    }
}

private struct BrowserColumn: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode
    let selectedID: FileNode.ID?
    let onLeft: () -> Void
    let onRight: () -> Void

    var body: some View {
        let rows = model.sortedChildren(of: node)
        let total = Double(max(model.size(of: node), 1))
        List(selection: Binding(
            get: { selectedID },
            set: { id in
                guard let id, let picked = rows.first(where: { $0.id == id }) else { return }
                model.select(picked, in: node)
            })
        ) {
            ForEach(rows) { child in
                ColumnRow(node: child, size: model.size(of: child), fraction: Double(model.size(of: child)) / total)
                    .tag(child.id)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if rows.isEmpty {
                Text(node.errorCount > 0 && node.itemCount == 0 ? "Can't read this folder" : "Empty")
                    .font(.callout).foregroundStyle(.tertiary)
            }
        }
        .contextMenu(forSelectionType: FileNode.ID.self) { ids in
            if let picked = rows.first(where: { ids.contains($0.id) }) {
                ItemMenu(nodes: [picked])
            }
        } primaryAction: { ids in
            if let picked = rows.first(where: { ids.contains($0.id) }), !picked.isDirectory { model.open(picked) }
        }
        .onKeyPress(.leftArrow) { onLeft(); return .handled }
        .onKeyPress(.rightArrow) { onRight(); return .handled }
        .onKeyPress(.return) {
            if let id = selectedID, let picked = rows.first(where: { $0.id == id }), !picked.isDirectory {
                model.open(picked); return .handled
            }
            return .ignored
        }
        .onDeleteCommand {
            if let id = selectedID, let picked = rows.first(where: { $0.id == id }) { model.requestTrash([picked]) }
        }
    }
}

private struct ColumnRow: View {
    let node: FileNode
    let size: Int64
    let fraction: Double

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(node: node, size: 16)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if node.errorCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Some items inside couldn't be read")
            }
            Spacer(minLength: 6)
            MiniBar(fraction: fraction)
            Text(Format.bytes(size))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 58, alignment: .trailing)
            Image(systemName: "chevron.forward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(node.isDirectory ? 1 : 0)
        }
        .padding(.vertical, 1)
    }
}

/// Context-menu items shared by every view.
struct ItemMenu: View {
    @EnvironmentObject var model: AppModel
    let nodes: [FileNode]

    var body: some View {
        if nodes.count == 1, let n = nodes.first {
            Button(n.isDirectory ? "Open" : "Open with Default App") { model.open(n, explicit: true) }
        }
        Button("Show in Finder") { model.revealInFinder(nodes) }
        Button("Copy Path") { model.copyPaths(nodes) }
        Divider()
        Button("Move to Trash…") { model.requestTrash(nodes) }
    }
}
