import Foundation
import Darwin

enum PrivacyRules {
    /// A match, with what stands around it for the rules that ask.
    fileprivate struct Hit {
        let text: NSString
        let match: NSTextCheckingResult
        let range: NSRange
        var value: String { text.substring(with: range) }
        func group(_ index: Int) -> String? {
            let found = match.range(at: index)
            return found.location == NSNotFound ? nil : text.substring(with: found)
        }
        var before: Character? { range.location > 0 ? text.substring(with: NSRange(location: range.location - 1, length: 1)).first : nil }
        /// To the line's end, never the whole rest of a text: a long tool result has thousands of hits.
        var restOfLine: String {
            let start = NSMaxRange(range), window = NSRange(location: start, length: min(512, text.length - start))
            let end = text.rangeOfCharacter(from: .newlines, options: [], range: window)
            return text.substring(with: NSRange(location: start, length: (end.location == NSNotFound ? NSMaxRange(window) : end.location) - start))
        }
        var lead: String { text.substring(with: NSRange(location: max(0, range.location - 16), length: min(16, range.location))) }
    }
    private struct Rule {
        let category: PrivacyCategory
        let expression: NSRegularExpression
        let group: Int
        let accepts: (Hit) -> Bool
        /// One of these is in any text the rule can match, in lower case:
        /// a text with none of them is not searched. `digit` stands for any digit.
        let markers: [String]
        /// Searched only on the lines that hold a marker and `=` or `:`: a name-then-value rule cannot
        /// match elsewhere, and its pattern is costly to try at every word of a long tool result.
        let byLine: Bool
        init(_ category: PrivacyCategory, on markers: [String], byLine: Bool = false, _ pattern: String, group: Int = 0, at accepts: @escaping (Hit) -> Bool) {
            self.category = category; expression = try! NSRegularExpression(pattern: pattern)
            self.group = group; self.accepts = accepts; self.markers = markers; self.byLine = byLine
        }
        init(_ category: PrivacyCategory, on markers: [String], _ pattern: String, group: Int = 0, accepts: @escaping (String) -> Bool = { _ in true }) {
            self.init(category, on: markers, pattern, group: group, at: { accepts($0.value) })
        }
        /// `lower` searched as bytes, not as Swift's grapheme-aware `contains`: this runs ~100 times per text.
        func applies(lower: NSString, digits: Bool) -> Bool {
            markers.contains { $0 == digit ? digits : lower.range(of: $0, options: .literal).location != NSNotFound }
        }
    }
    private static let digit = "\u{0}digit"
    private static let anyValue = -1
    private static let credentialField = #"(?:[A-Za-z0-9_.-]*(?i:api[_ -]?key|access[_ -]?key|secret|token|password|passwd|pwd|credential|private[_ -]?key|client[_ -]?key)[A-Za-z0-9_.-]*|[A-Z][A-Z0-9_]*_(?:KEY|PASS)|(?i:pin(?:[_ -]?code)?|pass))"#
    /// A secret's name and what joins it to its value, a quote of JSON inside a string included.
    /// Starts only where a name starts: `\b` let it start inside a long identifier or a base64 run too, and
    /// the name's leading `[A-Za-z0-9_.-]*` then scanned that run again from every one of its characters.
    private static let credentialName = #"(?<![A-Za-z0-9_.-])("# + credentialField + #")\\?["'`]?[ \t]*[:=][ \t]*"#
    private static let shellMarkers = ["ssh", "scp", "sftp", "rsync", "mosh"]
    private static let credentialMarkers = ["key", "secret", "token", "pass", "pwd", "credential", "pin"]
    private static let rules: [Rule] = [
        Rule(.privateKey, on: ["private key"], #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[\s\S]+?-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#),
        Rule(.apiKey, on: ["sk-", "_sk_", "ark-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-", "aiza", "xox", "_live_", "akia", "asia",
                           "hf_", "gsk_", "xai-", "npm_", "pypi-", "dop_v1_", "sg."], #"(?<![A-Za-z0-9_])(?:sk-(?:ant-|proj-|or-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}|[a-z]{2,4}_sk_[A-Za-z0-9_-]{20,}|ark-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|glpat-[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{35}|xox[abposr]-[A-Za-z0-9-]{10,}|(?:sk|rk)_live_[A-Za-z0-9]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|hf_[A-Za-z0-9]{30,}|gsk_[A-Za-z0-9]{40,}|xai-[A-Za-z0-9]{40,}|npm_[A-Za-z0-9]{36}|pypi-[A-Za-z0-9_-]{50,}|dop_v1_[a-f0-9]{64}|SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43})(?![A-Za-z0-9_])"#),
        Rule(.token, on: ["eyj"], #"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"#),
        // a header, on its line or quoted in a command: curl -H "Authorization: Bearer …" (not only a header on a line of its own)
        Rule(.secret, on: ["authorization", "cookie"], #"(?i)(?:^|["'\s])(?:authorization|proxy-authorization|cookie|set-cookie)\\?["']?[ \t]*:[ \t]*\\?["']?([^\r\n"'\\]{8,})"#, group: 1, accepts: headerValue),
        // one pass for a secret's name and its value as JSON in a string, in quotes, in single quotes or bare
        Rule(.secret, on: credentialMarkers, byLine: true, credentialName
             + #"(?:\\"([^"\\\r\n]{1,512})|"((?:\\.|[^"\\\r\n]){1,512})"|'((?:\\.|[^'\\\r\n]){1,512})'|([^\s"',;}{\\]+))"#,
             group: anyValue, at: credential),
        Rule(.password, on: ["\u{5BC6}\u{7801}", "\u{5BC6}\u{78BC}", "\u{53E3}\u{4EE4}", "\u{5BC6}\u{94A5}", "\u{5BC6}\u{9470}"], #"(?:\u5BC6\u7801|\u5BC6\u78BC|\u53E3\u4EE4|\u5BC6\u94A5|\u5BC6\u9470)[ \t]*((?:[:=\uFF1A]|\u662F|\u4E3A|\u70BA)[ \t]*)?["']?([^\s"',;}{\u3002\uFF0C]+)"#, group: 2, at: namedInWords),
        Rule(.password, on: ["://"], #"[A-Za-z][A-Za-z0-9+.-]*://[^\s:@/?#"'<>]*:([^\s@/?#"'<>]{3,})@"#, group: 1, accepts: notVariable),
        Rule(.email, on: ["@"], #"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}(?![A-Za-z0-9_-])"#, accepts: realEmail),
        Rule(.identityCard, on: [digit], #"(?<![A-Za-z0-9])[1-9][0-9]{5}(?:18|19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![A-Za-z0-9])"#, accepts: chineseID),
        // not a run of digits inside a UUID, a hash or a longer word
        Rule(.bankCard, on: [digit], #"(?<![A-Za-z0-9_-])[3-6][0-9](?:[ -]?[0-9]){11,17}(?![A-Za-z0-9_-])"#, accepts: luhn),
        Rule(.ssn, on: ["-"], #"(?<![0-9])[0-9]{3}-[0-9]{2}-[0-9]{4}(?![0-9])"#, accepts: ssn),
        Rule(.ssn, on: ["ssn", "social"], #"(?i)\b(?:ssn|social security(?: number)?)[ \t]*[:=#]?[ \t]*([0-9]{9})(?![0-9])"#, group: 1, accepts: ssn),
        Rule(.passport, on: ["passport", "\u{62A4}\u{7167}", "\u{8B77}\u{7167}"], #"(?:(?i:\bpassport(?:[ \t]*(?:no\.?|number|num|#))?)|\u62A4\u7167(?:\u53F7\u7801|\u53F7)?|\u8B77\u7167(?:\u865F\u78BC|\u865F)?)["']?[ \t]*(?:[:=#\uFF1A][ \t]*)?(?:(?i:is|was)[ \t]+)?["']?([A-Z0-9]{6,9})(?![A-Z0-9])"#, group: 1, accepts: passportOK),
        Rule(.iban, on: [digit], #"(?<![A-Z0-9])[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]){11,30}(?![A-Z0-9])"#, accepts: iban),
        Rule(.birthday, on: ["birth", "dob", "born", "\u{751F}\u{65E5}", "\u{51FA}\u{751F}"], #"(?i)(?:\b(?:date of birth|birth[_ -]?date|birthday|dob|born)|\u751F\u65E5|\u51FA\u751F\u65E5\u671F|\u51FA\u751F\u5E74\u6708\u65E5)[ \t]*[:=\uFF1A]?[ \t]*(?:is |on )?["']?([0-9]{4}[-/.\u5E74][0-9]{1,2}[-/.\u6708][0-9]{1,2}\u65E5?|[0-9]{1,2}[-/.][0-9]{1,2}[-/.][0-9]{4}|[A-Za-z]{3,9} [0-9]{1,2},? [0-9]{4})"#, group: 1),
        Rule(.mac, on: [":", "-"], #"(?i)(?<![0-9a-f:])[0-9a-f]{2}(?::[0-9a-f]{2}){5}(?![0-9a-f:])|(?<![0-9a-f-])[0-9a-f]{2}(?:-[0-9a-f]{2}){5}(?![0-9a-f-])"#, accepts: macOK),
        Rule(.serial, on: ["serial", "s/n", "\u{5E8F}\u{5217}"], #"(?i)(?:\bserial(?:[_ -]?(?:number|no))?|\bs/n|\u5E8F\u5217\u53F7|\u5E8F\u5217\u865F)[ \t]*[:=#\uFF1A][ \t]*["']?([A-Za-z0-9][A-Za-z0-9-]{3,63})"#, group: 1, accepts: serialOK),
        Rule(.username, on: ["users", "home", "documents and settings"], #"(?:(?<![A-Za-z0-9_.~/\\-])|(?<=file://))(?:/(?:Users|home)/|[A-Za-z]:[\\/]+(?:Users|users|Documents and Settings)[\\/]+)([^\\/\s"'<>|,;(){}\[\]:*?`$%]+?)(?=\.?(?:[\\/\s"'<>|,;(){}\[\]:*?`$%]|$))"#, group: 1, accepts: homeUser),
        Rule(.username, on: ["user", "login", "logname"], #"(?im)^[ \t]*["']?(?:user[ \t_-]?name|login[ \t_-]?name|user|login|logname)["']?[ \t]*[:=][ \t]*["']?([A-Za-z0-9_.-]+)["']?[ \t]*[,;]?[ \t]*$"#, group: 1, accepts: userOK),
        Rule(.hostname, on: ["name"], #"(?im)^[ \t]*["']?(?:host[ \t_-]?name|computer[ \t_-]?name|machine[ \t_-]?name)["']?[ \t]*[:=][ \t]*["']?([A-Za-z0-9][A-Za-z0-9.-]+)["']?[ \t]*[,;]?[ \t]*$"#, group: 1, accepts: hostOK),
        Rule(.username, on: shellMarkers, #"(?i)\b(?:ssh|scp|sftp|rsync|mosh)\b[^\n@]{0,64}?\s([A-Za-z_][A-Za-z0-9_.-]*)@"#, group: 1, accepts: userOK),
        Rule(.hostname, on: shellMarkers, #"(?i)\b(?:ssh|scp|sftp|rsync|mosh)\b[^\n@]{0,64}?\s[A-Za-z_][A-Za-z0-9_.-]*@([A-Za-z0-9][A-Za-z0-9.-]*)"#, group: 1, accepts: hostOK),
        Rule(.username, on: ["@"], #"(?m)(?:^|\[)([A-Za-z_][A-Za-z0-9_.-]*)@[A-Za-z0-9][A-Za-z0-9.-]*(?::[~/]|\s+[~/$#])"#, group: 1, accepts: userOK),
        Rule(.hostname, on: ["@"], #"(?m)(?:^|\[)[A-Za-z_][A-Za-z0-9_.-]*@([A-Za-z0-9][A-Za-z0-9.-]*)(?::[~/]|\s+[~/$#])"#, group: 1, accepts: hostOK),
        Rule(.ip, on: [digit], #"(?<![A-Za-z0-9_.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![A-Za-z0-9_.])"#, at: ipv4),
        Rule(.ip, on: ["::", "2"], #"(?i)(?<![A-Za-z0-9_:])[0-9a-f]{1,4}(?::[0-9a-f]{0,4}){2,7}(?![A-Za-z0-9_:])"#, accepts: publicIP),
        Rule(.bucket, on: ["://"], #"(?i)\b(?:s3a?|s3n|gs|oss|cosn?|obs|r2|ks3|bos|tos|az|azure|wasbs?|abfss?)://([A-Za-z0-9][A-Za-z0-9._-]*)"#, group: 1, accepts: bucketOK),
        Rule(.bucket, on: ["amazonaws", "googleapis", "aliyuncs", "myqcloud", "core.windows.net", "cloudflarestorage"], #"(?i)(?<![A-Za-z0-9.-])([A-Za-z0-9][A-Za-z0-9.-]*)\.(?:s3(?:[.-][A-Za-z0-9-]+)?\.amazonaws\.com|storage\.googleapis\.com|oss-[A-Za-z0-9-]+\.aliyuncs\.com|cos\.[A-Za-z0-9-]+\.myqcloud\.com|(?:blob|dfs)\.core\.windows\.net|r2\.cloudflarestorage\.com)"#, group: 1, accepts: bucketOK),
        Rule(.phone, on: [digit], #"(?<![A-Za-z0-9])(?:\+?86[ -]?)?1[3-9][0-9]{9}(?![A-Za-z0-9])"#, at: phoneAt),
        Rule(.phone, on: ["+"], #"(?<![A-Za-z0-9])\+[1-9](?:[0-9 ()-]{6,23}[0-9])(?![A-Za-z0-9])"#, accepts: phone),
        Rule(.phone, on: [digit], #"(?<![A-Za-z0-9])(?:\([2-9][0-9]{2}\)|[2-9][0-9]{2})[ .-]?[2-9][0-9]{2}[ .-][0-9]{4}(?![A-Za-z0-9])"#, at: { phone($0.value) && phoneAt($0) }),
        Rule(.phone, on: ["phone", "mobile", "tel", "\u{7535}\u{8BDD}", "\u{624B}\u{673A}", "\u{806F}\u{7D61}"], #"(?i)(?:\b(?:phone|mobile|telephone|tel)|\u7535\u8BDD|\u624B\u673A|\u806F\u7D61\u96FB\u8A71)[ \t]*[:=\uFF1A]?[ \t]*["']?([+0-9][0-9 ()-]{6,22}[0-9])"#, group: 1, accepts: phone),
        Rule(.account, on: ["account", "routing"], #"(?i)\b(?:account[_ -]?(?:number|no)|routing[_ -]?number|bank[_ -]?account)[ \t]*[:=][ \t]*["']?([A-Za-z0-9-]{4,40})"#, group: 1, accepts: { $0.contains(where: \.isNumber) })
    ]

    static func spans(in text: String) -> [PrivacySpan] {
        let string = text as NSString, range = NSRange(location: 0, length: string.length)
        let lower = text.lowercased() as NSString, digits = string.rangeOfCharacter(from: .decimalDigits).location != NSNotFound
        // Where a name-then-value rule can match: around each of its marker words, made once for all of them.
        var windows: [NSRange]?
        func markerWindows() -> [NSRange] {
            if let windows { return windows }
            var found: [NSRange] = []
            for marker in credentialMarkers {
                var rest = range
                while rest.length > 0 {
                    let at = string.range(of: marker, options: [.caseInsensitive, .literal], range: rest)
                    if at.location == NSNotFound { break }
                    let start = max(0, at.location - 80), end = min(string.length, NSMaxRange(at) + 600)
                    found.append(NSRange(location: start, length: end - start))
                    rest = NSRange(location: NSMaxRange(at), length: string.length - NSMaxRange(at))
                }
            }
            var merged: [NSRange] = []
            for window in found.sorted(by: { $0.location < $1.location }) {
                if let last = merged.last, window.location <= NSMaxRange(last) {
                    merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(window)) - last.location)
                } else { merged.append(window) }
            }
            windows = merged
            return merged
        }
        return rules.filter { $0.applies(lower: lower, digits: digits) }.flatMap { rule -> [PrivacySpan] in
            let searched = rule.byLine ? markerWindows() : [range]
            var seen = Set<Int>()
            return searched.flatMap { window in
                // bounds that see past the window, so \b and look-behinds read the text around it
                rule.expression.matches(in: text, options: rule.byLine ? [.withTransparentBounds] : [], range: window).compactMap { match in
                    // anyValue: the value is whichever of the alternatives after the name took part
                    let found = rule.group == Self.anyValue
                        ? (2..<match.numberOfRanges).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound } ?? NSRange(location: NSNotFound, length: 0)
                        : match.range(at: rule.group)
                    guard found.location != NSNotFound, found.length > 0, seen.insert(found.location).inserted,
                          rule.accepts(Hit(text: string, match: match, range: found)) else { return nil }
                    return PrivacySpan(start: found.location, end: found.location + found.length, category: rule.category)
                }
            }
        }
    }

    static func fieldCategory(_ key: String) -> PrivacyCategory? {
        let spelling = key
        let key = key.lowercased().filter { $0.isASCII && $0.isLetter }
        if key.hasSuffix("tokens") || key.hasSuffix("tokencount") { return nil }
        if ["authorization", "proxyauthorization", "cookie", "setcookie"].contains(key) { return .secret }
        if key.contains("password") || key.contains("passwd") || ["pwd", "pin", "pincode", "pass"].contains(key) || spelling.lowercased().hasSuffix("_pass") { return .password }
        if key.contains("secret") || key.contains("token") || key.contains("credential") ||
            ["apikey", "privatekey", "accesskey", "clientkey"].contains(key) || spelling.hasSuffix("_KEY") { return .secret }
        if ["email", "emailaddress"].contains(key) { return .email }
        if ["phone", "phonenumber", "mobile", "telephone"].contains(key) { return .phone }
        if ["ssn", "socialsecuritynumber"].contains(key) { return .ssn }
        if ["passport", "passportnumber"].contains(key) { return .passport }
        if ["birthday", "birthdate", "dateofbirth", "dob"].contains(key) { return .birthday }
        if ["username", "loginname"].contains(key) { return .username }
        if ["hostname", "machinename", "computername"].contains(key) { return .hostname }
        if ["iban", "bankaccount", "accountnumber", "routingnumber"].contains(key) { return .account }
        if ["creditcard", "cardnumber", "bankcard"].contains(key) { return .bankCard }
        if ["serialnumber", "serialno"].contains(key) { return .serial }
        if key == "macaddress" { return .mac }
        return nil
    }

    // MARK: What a value has to be
    //
    // A name says where a value may be; the value says whether it is one. These checks go further
    // where a real secret would otherwise pass: a password of letters alone, and a header in a command.

    private static func has(_ value: String, _ test: (Character) -> Bool) -> Bool { value.contains(where: test) }
    private static func asciiDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    private static func asciiLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
    private static func squeezed(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
    private static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }

    /// Not what stands in for a value: ${PASS}, <password>, ****.
    static func notVariable(_ value: String) -> Bool {
        guard let first = value.first, !"$%{<[*".contains(first) else { return false }
        return !value.allSatisfy { "*xX.".contains($0) }
    }
    private static let noValues: Set<String> = ["true", "false", "null", "nil", "none", "undefined", "string", "str", "int", "bool", "any", "object",
        "password", "passwd", "secret", "token", "changeme", "example", "placeholder", "your_password", "yourpassword", "your-password", "default", "required", "optional"]
    private static func identifier(_ value: String) -> Bool { matches(value, #"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*$"#) }
    /// Lower-case words, as a package, a tool or a setting is named, or the upper-case name of a constant.
    private static func wordsOnly(_ value: String) -> Bool {
        matches(value, #"^_*[a-z]+(?:[-._][a-z]+)*_*/?$"#) || matches(value, #"^[A-Z]+(?:_[A-Z0-9]+)+$"#)
    }
    /// Where a value is kept or what version it is, not the value: ~/.ssh/id_ed25519, tokenizer.json, 0.15.0-rc1.
    private static func pointsElsewhere(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("./") || value.hasPrefix("../") || value.contains("://")
            || matches(value, #"(?i)\.(?:json|ya?ml|toml|ini|txt|pem|key|env|db|lock|swift|py|js|ts|go)$"#)
            || matches(value, #"^[v^~>=<]*[0-9]+(?:\.[0-9]+)+[-A-Za-z0-9.+]*$"#)
    }

    /// The value after a secret's name. Secrets in code are strings, so what is not quoted has to read as a
    /// config's value, not as code.
    private static func credential(_ hit: Hit) -> Bool {
        let value = hit.value, name = hit.group(1) ?? ""
        let spelled = name.lowercased()
        if spelled.contains("tokeniz") || spelled.hasSuffix("tokens") || spelled.hasSuffix("tokencount") || spelled.hasSuffix("_count") { return false }
        guard notVariable(value), !pointsElsewhere(value), !noValues.contains(value.lowercased()), squeezed(value) != squeezed(name) else { return false }
        let quoted = hit.before.map { "\"'`".contains($0) } ?? false
        let digit = has(value, asciiDigit), letter = has(value, asciiLetter)
        if value.hasPrefix("process.env") || value.hasPrefix("os.") || value.hasPrefix("env.") { return false }
        if !quoted {
            let rest = hit.restOfLine.drop { $0 == " " || $0 == "\t" }
            if value.contains("(") || value.contains(")") || rest.hasPrefix("(") { return false }
            // a.b.c after = is a read in code, not a config's value
            if identifier(value), value.contains(".") { return false }
            if identifier(value), let next = rest.first, ";,)}]|?&<>".contains(next), hit.lead.trimmingCharacters(in: .whitespaces).hasSuffix(":") { return false }
        }
        if spelled.contains("pass") || spelled.contains("pwd") || spelled.hasPrefix("pin") {
            guard value.count >= 4 else { return false }
            if quoted { return !wordsOnly(value) || !value.contains(where: { "_-.".contains($0) }) }
            if digit { return true }
            // no digit and no quotes: a config's line, or code's name for something
            // joined with no spaces, password=value; code spaces it, or goes on: f(password=pw), a.b
            let next = hit.restOfLine.first
            let config = hit.lead.hasSuffix("=") && !value.contains(".") && next != "," && next != ")"
            let yaml = hit.restOfLine.allSatisfy(\.isWhitespace) && hit.lead.trimmingCharacters(in: .whitespaces).hasSuffix(":") && value.first?.isUppercase == false
            return config || yaml
        }
        if value.contains(where: \.isWhitespace) {
            // words in quotes are a message, but for an env var's or a secret's own value
            return quoted && value.count >= 8 && (name == name.uppercased() || spelled.contains("secret"))
        }
        if value.count >= 8 && digit && letter { return true }
        // an opaque key of letters alone (a digit is not required)
        return quoted && value.count >= 20 && !wordsOnly(value)
    }

    /// An Authorization or Cookie header's value: `Bearer $TOKEN` is a command's words.
    private static func headerValue(_ value: String) -> Bool {
        let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count == 2, ["bearer", "basic", "token", "digest"].contains(words[0].lowercased()) {
            return words[1].count >= 8 && notVariable(words[1]) && has(words[1]) { !$0.isLetter }
        }
        guard notVariable(value), !value.contains("("), !identifier(value.trimmingCharacters(in: CharacterSet(charactersIn: ",; "))) else { return false }
        return has(value, asciiDigit) || value.contains("=")
    }

    /// The value after a Chinese word for password or key (\u5BC6\u7801, \u5BC6\u94A5) in a sentence: with what joins them, or a value that can only be one.
    /// A length or count after the word ("key is 32 \u4F4D", bits, bytes, times, durations) says nothing secret.
    private static func namedInWords(_ hit: Hit) -> Bool {
        let value = hit.value
        guard notVariable(value), value.count >= 4 else { return false }
        if matches(hit.restOfLine, #"^[ \t]*(?:\u4F4D|\u6BD4\u7279|\u5B57\u8282|\u4E2A|\u6B21|\u79D2|\u6BEB\u79D2|\u5206\u949F|\u5C0F\u65F6|\u5929|\u5E74|bit|byte|ms)"#) { return false }
        return hit.group(1) != nil || (value.allSatisfy(\.isASCII) && has(value, asciiDigit))
    }

    /// A value the local model called a secret: words
    /// and names in code are one only where they are given to a secret's name.
    static func modelSecret(_ value: String, at start: Int, in text: NSString) -> Bool {
        guard value.utf8.count >= 8, notVariable(value), !pointsElsewhere(value) else { return false }
        guard wordsOnly(value) || (identifier(value) && !has(value, asciiDigit)) else { return true }
        let before = text.substring(with: NSRange(location: max(0, start - 64), length: min(64, start)))
        return matches(before, #"(?i)(?:secret|token|key|pass|pwd|credential|\u5BC6\u7801|\u5BC6\u78BC|\u5BC6\u94A5|\u4EE4\u724C)[A-Za-z0-9_.-]*["'`]?[ \t]*(?:=|:|\uFF1A|\bis|\bwas|\u662F|\u4E3A|\u70BA)[ \t]*["'`]?$"#)
    }

    /// What a field of this kind holds, by its name.
    static func fieldValue(_ value: String, category: PrivacyCategory) -> Bool {
        switch category {
        case .password: return value.count >= 4 && notVariable(value) && !noValues.contains(value.lowercased())
        case .secret, .apiKey, .token, .privateKey: return value.utf8.count >= 8 && notVariable(value) && !noValues.contains(value.lowercased())
        case .email: return value.contains("@")
        case .phone: return value.filter(\.isNumber).count >= 7
        case .username: return userOK(value)
        case .hostname: return hostOK(value)
        default: return true
        }
    }

    private static func realEmail(_ value: String) -> Bool {
        guard let at = value.lastIndex(of: "@") else { return false }
        let user = value[..<at].lowercased(), host = value[value.index(after: at)...].lowercased()
        if user == "git" || user.contains("noreply") || host.hasPrefix("noreply") { return false }
        if matches(host, #"\.(?:png|jpe?g|gif|svg|webp|ico|js|ts|css)$"#) { return false }
        return !["example.com", "example.org", "example.net", "localhost"].contains(host)
            && ![".example.com", ".example.org", ".example.net", ".test", ".invalid", ".example"].contains { host.hasSuffix($0) }
    }
    private static func passportOK(_ value: String) -> Bool {
        value.filter(\.isNumber).count >= 5 && Set(value).count > 1
    }
    private static func serialOK(_ value: String) -> Bool {
        value.count >= 6 && has(value, asciiDigit) && Set(value).count > 1
    }
    private static func macOK(_ value: String) -> Bool {
        let plain = value.lowercased().replacingOccurrences(of: "-", with: ":")
        return plain != "ff:ff:ff:ff:ff:ff" && plain != "00:00:00:00:00:00" && has(plain) { "abcdef".contains($0) }
    }
    private static let notNames: Set<String> = ["shared", "public", "guest", "default", "default user", "all users", "user", "username", "user_name",
        "yourname", "your-name", "your_name", "yourusername", "you", "me", "name", "example", "foo", "bar", "someone", "john", "jdoe",
        "runner", "node", "vscode", "codespace", "linuxbrew"]
    private static let notUsers: Set<String> = ["git", "root", "ec2-user", "ubuntu", "admin", "postgres", "www-data", "nobody", "centos", "debian",
        "fedora", "azureuser", "opc", "core", "vagrant", "docker", "str", "string", "int", "bool", "any", "none", "null", "nil", "true", "false",
        "undefined", "hi", "hello", "hey", "yes", "no", "ok", "okay", "thanks", "continue", "go", "stop", "help", "test",
        "done", "why", "what", "how", "sure", "please", "retry", "next", "again", "good", "fix", "required", "optional", "unknown", "anonymous", "current"]
    private static func homeUser(_ value: String) -> Bool { !value.hasPrefix(".") && !notNames.contains(value.lowercased()) }
    private static func userOK(_ value: String) -> Bool {
        let plain = value.lowercased()
        return value.count >= 2 && !notUsers.contains(plain) && !notNames.contains(plain)
    }
    private static func hostOK(_ value: String) -> Bool {
        let plain = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard plain.count >= 2, !["localhost", "github.com", "gitlab.com", "bitbucket.org"].contains(plain) else { return false }
        if plain.hasPrefix("process.") || plain.hasPrefix("os.") || plain.hasPrefix("env.") { return false }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, plain, &v4) == 1 || inet_pton(AF_INET6, plain, &v6) == 1 { return false } // an address is the IP rules'
        return !["example.com", "example.org", "example.net"].contains(plain)
            && ![".example.com", ".example", ".test", ".invalid", ".localhost"].contains { plain.hasSuffix($0) }
    }
    private static let notBuckets: Set<String> = ["bucket", "my-bucket", "mybucket", "bucket-name", "bucketname", "my-bucket-name", "your-bucket",
        "your-bucket-name", "yourbucket", "example-bucket", "examplebucket", "amzn-s3-demo-bucket", "doc-example-bucket", "s3", "www", "storage",
        "container", "mycontainer", "my-container", "mystorageaccount", "account", "upload", "download", "batch", "b", "v1", "v2", "api"]
    private static func bucketOK(_ value: String) -> Bool { !notBuckets.contains(value.lowercased()) }

    /// A dotted quad that is a public address, not a version.
    private static func ipv4(_ hit: Hit) -> Bool {
        guard publicIP(hit.value) else { return false }
        if let before = hit.before, "_-=~^".contains(before) { return false }
        let start = hit.range.location
        if hit.before == "/", start >= 2 {
            let earlier = hit.text.substring(with: NSRange(location: start - 2, length: 1))
            if earlier.first.map({ $0.isLetter || $0.isNumber || "._-".contains($0) }) == true { return false }
        }
        return !matches(hit.lead, #"(?i)(?:^|[^a-z0-9_])(?:version|ver|release|build|rev|\u7248\u672C)[ \t:="']*$"#)
    }
    private static func bytes(_ address: String) -> [UInt8]? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        if inet_pton(AF_INET6, address, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
    private static func inside(_ address: [UInt8], _ prefix: (bytes: [UInt8], bits: Int)) -> Bool {
        guard address.count == prefix.bytes.count else { return false }
        for bit in 0..<prefix.bits where (address[bit / 8] ^ prefix.bytes[bit / 8]) & (0x80 >> UInt8(bit % 8)) != 0 { return false }
        return true
    }
    /// Addresses that are no one's in particular: private, shared, loopback, link-local, documentation,
    /// benchmarking, reserved.
    private static let notPublic: [(bytes: [UInt8], bits: Int)] = [
        ("0.0.0.0", 8), ("10.0.0.0", 8), ("100.64.0.0", 10), ("127.0.0.0", 8), ("169.254.0.0", 16), ("172.16.0.0", 12), ("192.0.0.0", 24),
        ("192.0.2.0", 24), ("192.168.0.0", 16), ("198.18.0.0", 15), ("198.51.100.0", 24), ("203.0.113.0", 24), ("224.0.0.0", 4), ("240.0.0.0", 4),
        ("2001:db8::", 32)
    ].map { (bytes($0.0)!, $0.1) }
    private static let resolvers: Set<String> = ["8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1", "9.9.9.9", "149.112.112.112", "208.67.222.222", "208.67.220.220",
        "114.114.114.114", "223.5.5.5", "223.6.6.6", "119.29.29.29", "180.76.76.76", "2001:4860:4860::8888", "2001:4860:4860::8844",
        "2606:4700:4700::1111", "2606:4700:4700::1001"]
    private static func publicIP(_ value: String) -> Bool {
        guard let address = bytes(value), !resolvers.contains(value.lowercased()) else { return false }
        if address.count == 16, address[0] & 0xe0 != 0x20 { return false } // global unicast only
        return !notPublic.contains { inside(address, $0) }
    }

    private static let phoneWords = ["phone", "mobile", "tel", "cell", "contact", "whatsapp", "\u{7535}\u{8BDD}", "\u{624B}\u{673A}", "\u{806F}\u{7D61}", "\u{8054}\u{7CFB}"]
    private static let idWords = ["id", "no", "no.", "number", "order", "uid", "\u{8BA2}\u{5355}", "\u{5355}\u{53F7}", "\u{7F16}\u{53F7}", "\u{8D26}\u{53F7}"]
    /// A run of digits in a phone's shape is one where nothing says it is another number:
    /// a field's or an assignment's name has to be a phone's, a call's argument is code's
    /// (assertEquals(13800138000, x)), and an order's, an id's or a #'s number is not a phone.
    private static func phoneAt(_ hit: Hit) -> Bool {
        if madeUp(hit.value) { return false }
        if hit.value.filter(\.isNumber).count > 11 { return true } // +86, 86
        if let before = hit.before, "#_-.".contains(before) { return false } // #12, a hash's or a name's piece
        if let after = hit.restOfLine.first, "_-".contains(after) { return false }
        let lead = hit.text.substring(with: NSRange(location: max(0, hit.range.location - 40), length: min(40, hit.range.location))).lowercased()
        var trimmed = Substring(lead)
        while let last = trimmed.last, " \t\"'\u{201C}\u{300C}".contains(last) { trimmed = trimmed.dropLast() }
        func named(_ s: Substring) -> Bool { phoneWords.contains { s.contains($0) } }
        func trailingName(_ s: Substring) -> Substring {
            var s = s
            while let last = s.last, " \t\"'".contains(last) { s = s.dropLast() }
            let count = s.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }.count
            return s.suffix(count)
        }
        if let last = trimmed.last, ":=\u{FF1A}".contains(last) { return named(trailingName(trimmed.dropLast())) }
        if let last = trimmed.last, last == "(" || last == "," {
            let name = trailingName(trimmed.dropLast())
            if last == "(", !name.isEmpty { return named(name) } // a call's argument
        }
        for copula in ["\u{662F}", "\u{4E3A}", "\u{70BA}"] where trimmed.hasSuffix(copula) { trimmed = trimmed.dropLast() }
        while let last = trimmed.last, last == " " || last == "\t" { trimmed = trimmed.dropLast() }
        for word in idWords where trimmed.hasSuffix(word) {
            let rest = trimmed.dropLast(word.count)
            if word.first!.isASCII, let c = rest.last, c.isLetter || c.isNumber || c == "_" { continue } // "recorder", not "order"
            if ["no", "no.", "number"].contains(word), named(trailingName(rest)) { return true } // phone no.
            return false
        }
        return true
    }
    /// A number no one has: the documentation's own (13800138000), or one whose last eight digits are
    /// one or two digits over (13800000000, 13888888888), or a run (12345678). Masking it only tells the
    /// model a placeholder is a phone where the text shows an example of one.
    private static let exampleNumbers: Set<String> = ["13800138000", "8613800138000", "2125551212"]
    private static func madeUp(_ value: String) -> Bool {
        let digits = value.filter { $0.isASCII && $0.isNumber }
        if exampleNumbers.contains(String(digits)) { return true }
        let tail = Array(digits.suffix(8)).compactMap(\.wholeNumberValue)
        guard tail.count >= 7 else { return false }
        if Set(tail).count <= 2 { return true }
        let steps = zip(tail, tail.dropFirst()).map { ($1 - $0 + 10) % 10 } // 8901 runs on as 89, 90, 01
        return steps.allSatisfy { $0 == 1 } || steps.allSatisfy { $0 == 9 }
    }
    private static func phone(_ value: String) -> Bool { (7...15).contains(value.filter(\.isNumber).count) && !madeUp(value) }
    private static func ssn(_ value: String) -> Bool {
        let n = value.filter(\.isNumber)
        return n.count == 9 && !n.hasPrefix("000") && !n.hasPrefix("666") && !n.hasPrefix("9") && n.dropFirst(3).prefix(2) != "00" && !n.hasSuffix("0000")
    }
    private static func luhn(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        return digits.reversed().enumerated().reduce(0) { sum, pair in
            let number = pair.offset % 2 == 1 ? pair.element * 2 : pair.element
            return sum + (number > 9 ? number - 9 : number)
        } % 10 == 0
    }
    private static func chineseID(_ value: String) -> Bool {
        let chars = Array(value.uppercased()), weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        guard chars.count == 18 else { return false }
        let checksum = zip(chars.prefix(17), weights).reduce(0) { $0 + ($1.0.wholeNumberValue ?? 0) * $1.1 }
        return Array("10X98765432")[checksum % 11] == chars[17]
    }
    private static func iban(_ value: String) -> Bool {
        let value = value.replacingOccurrences(of: " ", with: "")
        guard (15...34).contains(value.count) else { return false }
        var remainder = 0
        for scalar in (value.dropFirst(4) + value.prefix(4)).unicodeScalars {
            if (48...57).contains(scalar.value) { remainder = (remainder * 10 + Int(scalar.value) - 48) % 97 }
            else if (65...90).contains(scalar.value) { remainder = (remainder * 100 + Int(scalar.value) - 55) % 97 }
            else { return false }
        }
        return remainder == 1
    }
}
