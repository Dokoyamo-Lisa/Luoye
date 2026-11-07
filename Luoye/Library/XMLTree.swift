import Foundation

/// 把一小段 XML 读成一棵树，方便按名字查找。元素名去掉前缀，如 `dc:title` 记作 `title`。
final class XMLTree {
    let name: String
    let attributes: [String: String]
    private(set) var children: [XMLTree] = []
    fileprivate(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    static func parse(_ data: Data) -> XMLTree? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.parse()
        return builder.root
    }

    /// 第一个叫这个名字的后代元素。
    func first(_ name: String) -> XMLTree? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }

    /// 所有叫这个名字的后代元素。
    func all(_ name: String) -> [XMLTree] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
    }

    /// 读属性时同样忽略前缀，如 `opf:role` 也能用 `role` 取到。
    func attribute(_ name: String) -> String? {
        attributes[name] ?? attributes.first { $0.key.split(separator: ":").last.map(String.init) == name }?.value
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        private var stack: [XMLTree] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = XMLTree(name: local, attributes: attributes)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            stack.removeLast()
        }
    }
}
