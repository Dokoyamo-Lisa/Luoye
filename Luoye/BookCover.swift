import SwiftUI

/// 书的封面。EPUB 有封面图就用图，否则用书名排一张素净的纸封面。
struct BookCover: View {
    let book: Book

    var body: some View {
        Group {
            if let url = book.coverURL, let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                PlainCover(title: book.title)
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.ink.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: Color.ink.opacity(0.08), radius: 6, y: 3)
    }
}

/// 没有封面图时：淡藕粉的纸面，竖排书名。
private struct PlainCover: View {
    let title: String

    var body: some View {
        // 字号和留白跟着封面宽度走，iPhone 和 iPad 上比例一致。
        GeometryReader { proxy in
            let unit = proxy.size.width / 107
            ZStack(alignment: .topTrailing) {
                Color.paper
                Color.accent.opacity(0.06)

                HStack(alignment: .top, spacing: 10 * unit) {
                    Rectangle()
                        .fill(.tint)
                        .frame(width: max(1, unit), height: 28 * unit)
                        .padding(.top, 2 * unit)
                    VStack(spacing: 2 * unit) {
                        ForEach(Array(title.prefix(8).enumerated()), id: \.offset) { _, character in
                            Text(String(character))
                        }
                    }
                    .font(.serif(14 * unit, medium: true))
                    .foregroundStyle(Color.ink)
                }
                .padding(.top, 14 * unit)
                .padding(.trailing, 14 * unit)
            }
        }
    }
}
