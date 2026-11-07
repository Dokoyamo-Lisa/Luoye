import Foundation

/// 把 TXT 的字节转成文字。
/// 先看 BOM；没有 BOM 时，UTF-8 能完整解开就用 UTF-8；否则用 GB18030、Big5、Shift_JIS 各试一遍，
/// 看哪种解出来的「常用字」最多就用哪种（解错的编码通常是一堆生僻字）。
enum TextDecoding {
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if let utf16 = utf16WithoutBOM(data) { return utf16 }
        if let text = String(data: data, encoding: .utf8) { return text }

        // 只拿开头一段打分，大文件也很快。
        let sample = data.prefix(64 * 1024)
        let candidates: [String.Encoding] = [.gb18030, .big5, .shiftJIS]
        let best = candidates
            .compactMap { encoding in decodeLeniently(sample, encoding).map { (encoding, score($0)) } }
            .max { $0.1 < $1.1 }
        return best.flatMap { decodeLeniently(data, $0.0) }
    }

    /// 没有 BOM 的 UTF-16：中文、英文混排时，奇数位或偶数位上会有大量 0 字节。
    private static func utf16WithoutBOM(_ data: Data) -> String? {
        let sample = data.prefix(4096)
        guard sample.count >= 64 else { return nil }
        var evenZero = 0, oddZero = 0
        for (index, byte) in sample.enumerated() where byte == 0 {
            if index.isMultiple(of: 2) { evenZero += 1 } else { oddZero += 1 }
        }
        let threshold = sample.count / 8
        if oddZero > threshold, evenZero < threshold / 4 { return String(data: data, encoding: .utf16LittleEndian) }
        if evenZero > threshold, oddZero < threshold / 4 { return String(data: data, encoding: .utf16BigEndian) }
        return nil
    }

    /// 截断的末尾可能有半个字，失败时去掉最后几个字节再试。
    private static func decodeLeniently(_ data: Data, _ encoding: String.Encoding) -> String? {
        for trim in 0 ... 3 where data.count > trim {
            if let text = String(data: data.dropLast(trim), encoding: encoding) { return text }
        }
        return nil
    }

    /// 常用字、假名和中文标点越多，分越高。
    private static func score(_ text: String) -> Double {
        var good = 0, total = 0
        for scalar in text.unicodeScalars where scalar.value > 0x7F {
            total += 1
            if common.contains(scalar) || (0x3040 ... 0x30FF).contains(scalar.value) { good += 1 }
        }
        return total == 0 ? 0 : Double(good) / Double(total)
    }

    /// 简体、繁体最常用的几百个字，外加中文标点。
    private static let common: Set<Unicode.Scalar> = Set((
        "的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但身些与高意进把法此实回二理美点月明其种声全工己话儿者向情部正名定女问力机给等几很业最间新什打便位因重被走电四第门相次东政海口使教西再平真听世气信北少关并内加化由却代军产入先山五太水万市眼体别处总才场师书比住员九笑性通目华报立马命张活难神数件安表原车白应路期叫死常提感金何更反合放做系计或司利受光王果亲界及今京务制解任至清物台象记边共风战干接它许八特觉望直服毛林题建南度统色字请交爱让认算论百吃义科怎元社术结六功指思非流每青管夫连远资队跟带花快条院变联言权往展该领传近留红治决周保达办运武半候七必城父强步完革深区即求品士转量空甚众技轻程告江语英基派满式李息写呢识极令黄德收脸钱党倒未持取设始版双历越史商千片容研像找友孩站广改议形委早房音火际则首单据导影失拿网香似斯专石若兵弟谁校读志飞观争究包组造落视济喜离虽坐集编宝谈府拉黑且随格尽剑讲布杀微怕母调局根曾准团段终乐切级克精哪官示冷域依微希紧爬養這個們來國說時會麼對發後裡們為與還從現樣學經點見間開當關頭過問長車種東進動應覺讓總機萬條實門場體氣聽戰無話寫錯許認論親邊級傳張變識雖聲書兒義隊幾東電兩區號極樂劍殺語從師邊顯親聖鳳龍華聞戰輕風漢陽陰陣陳運將這邊們!，。！？、；：“”‘’「」『』（）《》…—"
    ).unicodeScalars)
}

private extension String.Encoding {
    static let gb18030 = Self(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    /// 用香港增补字符集版本，覆盖面比普通 Big5 广。
    static let big5 = Self(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
}
