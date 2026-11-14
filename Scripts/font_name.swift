import Foundation
import CoreText
let url = URL(fileURLWithPath: CommandLine.arguments[1])
if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
    for descriptor in descriptors { print(CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) ?? "unknown") }
}
