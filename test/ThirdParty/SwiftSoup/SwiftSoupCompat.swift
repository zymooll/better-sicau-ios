// The package normally qualifies these references with its module name. Since
// the sources are vendored into the application target, use a global alias.
@usableFromInline
typealias SwiftSoupElement = Element
typealias SwiftSoupTag = Tag

func swiftSoupParseXML(_ html: String, _ baseURI: String, _ parser: Parser) throws -> Document {
    try parse(html, baseURI, parser)
}
