// CatalogTests.swift - the inventory table and the file format it exports to.
//
// Two things are worth testing here and they are different. The table is data,
// so the tests are structural: ids parse, ids are unique, provenance matches
// the engine that will use it, and families stay grouped. The file format is a
// codec, so the test is a round trip: what comes back has to equal what went
// in, field for field and under every line ending, or the checked-in copy in
// docs/ is not the inventory.

import Foundation
import Testing

@testable import SpeechCore

@Suite("Catalog table")
struct CatalogTableTests {
    @Test("every id is unique")
    func idsAreUnique() {
        var seen: Set<String> = []
        for row in Catalog.rows {
            #expect(seen.insert(row.id).inserted, "duplicate catalog id '\(row.id)'")
        }
    }

    /// A catalog id becomes a directory name. `EngineSpec.parse` is the gate
    /// that keeps it from becoming a path traversal, and every row has to pass
    /// through it, because stage 3 is exactly the change that lets ids arrive
    /// from somewhere other than argv.
    @Test("every id parses into an engine spec")
    func idsParse() throws {
        let root = URL(fileURLWithPath: "/tmp/speech-catalog-test", isDirectory: true)
        for row in Catalog.rows {
            let spec = try EngineSpec.parse(catalogID: row.id, modelsDirectory: root)
            #expect(spec.engine == row.engine)
            #expect(spec.catalogID == row.id)
        }
    }

    /// Callers group by family, and a scattered family would make a grouped
    /// listing show the same heading twice.
    @Test("rows of a family are contiguous")
    func familiesAreContiguous() {
        var order: [CatalogFamily] = []
        for row in Catalog.rows where order.last != row.family {
            #expect(!order.contains(row.family),
                    "family '\(row.family.rawValue)' appears in two blocks")
            order.append(row.family)
        }
        #expect(order == Catalog.families)
    }

    @Test("family lookup returns every row of that family")
    func familyLookup() {
        var counted = 0
        for family in Catalog.families {
            let rows = Catalog.rows(family: family)
            #expect(!rows.isEmpty)
            #expect(rows.allSatisfy { $0.family == family })
            counted += rows.count
        }
        #expect(counted == Catalog.rows.count)
        #expect(Catalog.row(id: "ggml.nonexistent") == nil)
    }

    /// The order is computed, not chosen, so that nobody can read a ranking
    /// into it. Deciding between these rows needs measurements from the machine
    /// it will run on, which is Speech.app's job, not this table's.
    @Test("the order is mechanical")
    func orderIsMechanical() {
        // Asserted against the documented key rather than against `ordered`
        // itself: `rows` is built by `ordered`, so comparing the two only
        // proves the sort is idempotent and would still pass if the rule in
        // docs/catalog.md and the rule in the code drifted apart.
        // Negating the size turns "largest first" into an ascending field, and
        // an absent size becomes 1, which sorts after every real one.
        func key(_ row: CatalogRow) -> (String, String, Int64, String) {
            (row.family.rawValue, row.engine, -(row.sizeBytes ?? -1), row.id)
        }
        let keys = Catalog.rows.map(key)
        #expect(keys.elementsEqual(keys.sorted { $0 < $1 }, by: ==),
                "families alphabetically, then engine, then largest build first")
        #expect(Catalog.families == Catalog.families.sorted { $0.rawValue < $1.rawValue })
        // And it is stable: sorting an already-sorted array changes nothing, so
        // two runs of `catalog --tsv` cannot differ.
        #expect(Catalog.ordered(Catalog.rows) == Catalog.rows)
        #expect(Catalog.ordered(Catalog.ordered(Catalog.rows)) == Catalog.rows)
    }

    /// Lookup is case-sensitive on purpose: `models download` would install to
    /// one directory while `catalog` described another.
    @Test("lookup does not fold case")
    func lookupIsExact() {
        #expect(Catalog.row(id: "apple.transcriber") != nil)
        #expect(Catalog.row(id: "Apple.Transcriber") == nil)
    }

    @Test("provenance matches the engine the id names")
    func provenance() {
        for row in Catalog.rows {
            switch row.engine {
            case "apple":
                #expect(row.source == nil, "\(row.id) should have no repository")
                #expect(row.file == nil)
                #expect(row.sizeBytes == nil, "\(row.id) is installed by the OS")
            case "ggml":
                // A ggml row is one GGUF inside one repository. Without both,
                // the download client has nothing to fetch.
                #expect(row.file != nil, "\(row.id) needs a GGUF file name")
                #expect(row.source?.hasSuffix("-gguf") == true, "\(row.id): repo name")
                #expect(row.sizeBytes != nil, "\(row.id) needs a download size")
            case "fluid":
                // A fluid row downloads a subset of a repository directory, so
                // it names no single file.
                #expect(row.file == nil, "\(row.id) is a directory download")
                #expect(row.source?.hasPrefix("FluidInference/") == true, "\(row.id): repo name")
            default:
                Issue.record("unknown engine prefix in '\(row.id)'")
            }
        }
    }

    /// The GGUF file name is what the download client asks the server for, and
    /// the naming rule is the one GGMLCatalog encodes: `<stem>-<QUANT>.gguf`
    /// inside `handy-computer/<stem>-gguf`. A typo here is a 404 halfway
    /// through a chooser.
    @Test("a ggml file name agrees with its repository and precision")
    func ggmlFileNames() throws {
        for row in Catalog.rows where row.engine == "ggml" {
            let source = try #require(row.source)
            let file = try #require(row.file)
            #expect(source.hasPrefix("handy-computer/"), "\(row.id): repo organization")
            let stem = String(source.dropFirst("handy-computer/".count).dropLast("-gguf".count))
            #expect(file == "\(stem)-\(row.precision.uppercased()).gguf", "\(row.id)")
        }
    }

    @Test("labels are present, plain and unique")
    func labels() {
        var labels: Set<String> = []
        for row in Catalog.rows {
            #expect(!row.label.isEmpty)
            #expect(labels.insert(row.label).inserted, "duplicate label '\(row.label)'")
            // Appendix C of the plan: no double quotes or backslashes, so that
            // a label survives every downstream quoting scheme unescaped.
            #expect(!row.label.contains("\""), "\(row.id): label has a double quote")
            #expect(!row.label.contains("\\"), "\(row.id): label has a backslash")
        }
    }

    /// The house style, checked mechanically because prose drifts.
    @Test("labels are ASCII")
    func ascii() {
        for row in Catalog.rows {
            #expect(row.label.allSatisfy { $0.isASCII }, "\(row.id): label")
            // Ids are padded by UTF-16 length when the listing is aligned, so a
            // non-ASCII id would misalign or truncate.
            #expect(row.id.allSatisfy { $0.isASCII }, "\(row.id): id")
        }
    }

    /// This table is an inventory. A label that scores a row would be the first
    /// step back toward the CLI having an opinion about which model to use,
    /// which is Speech.app's decision and depends on a machine this program
    /// cannot measure for.
    @Test("no label makes a claim about quality")
    func labelsAreNotEvaluative() {
        let evaluative = [
            "best", "worst", "fastest", "slowest", "recommended", "better", "beats",
            "wer", "accurate", "prefer",
        ]
        for row in Catalog.rows {
            let label = row.label.lowercased()
            for word in evaluative {
                #expect(!label.contains(word), "\(row.id): label claims '\(word)'")
            }
        }
    }

    @Test("the CTC spotter is the only helper row")
    func helpers() {
        let helpers = Catalog.rows.filter { $0.role == .helper }.map(\.id)
        #expect(helpers == ["fluid.parakeet-ctc-110m"])
    }
}

@Suite("Catalog file format")
struct CatalogFileTests {
    static func capabilities(
        languages: [String] = ["en"], live: Bool = false, minimumMacOS: String = "15.0"
    ) -> EngineCapabilities {
        EngineCapabilities(
            batch: true, live: live, wordTimestamps: true, segmentTimestamps: true,
            vocabulary: false, diarization: false, languageID: false, languageHint: true,
            languages: languages, minimumMacOS: minimumMacOS)
    }

    static func sample() -> [CatalogFileRow] {
        [
            CatalogFileRow(
                row: Catalog.rows[0], capabilities: capabilities(languages: ["en", "de"])),
            // An "any language" row, a live row and an unknown size all round
            // trip through placeholders rather than through empty fields.
            CatalogFileRow(
                row: CatalogRow(
                    id: "ggml.example@q8_0", family: .whisper, source: "handy-computer/example-gguf",
                    file: "example-Q8_0.gguf", parametersM: 42, precision: "q8_0",
                    label: "Example"),
                capabilities: capabilities(languages: [], live: true, minimumMacOS: "26.0")),
        ]
    }

    @Test("a catalog round trips through the file format")
    func roundTrip() throws {
        let rows = Self.sample()
        let text = try CatalogFile.text(rows, generator: "test")
        #expect(try CatalogFile.parse(text) == rows)
    }

    @Test("the whole real catalog round trips")
    func roundTripEverything() throws {
        let rows = Catalog.rows.map {
            CatalogFileRow(row: $0, capabilities: Self.capabilities(languages: ["en", "pl"]))
        }
        let text = try CatalogFile.text(rows, generator: "test")
        #expect(try CatalogFile.parse(text) == rows)
    }

    /// An empty `languages` list means "any language" to `EngineCapabilities`,
    /// and an empty field would be indistinguishable from a missing one, so it
    /// is written as `*` and has to come back as the empty list.
    @Test("any-language and empty flag lists survive the trip")
    func placeholders() throws {
        let rows = Self.sample()
        let text = try CatalogFile.text(rows, generator: "test")
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("ggml.example") })
        #expect(line.contains("\t*\t"))
        let parsed = try CatalogFile.parse(text)
        #expect(parsed[1].languages.isEmpty)
        #expect(parsed[1].modes == ["batch", "live"])
        #expect(parsed[1].row.sizeBytes == nil)
        #expect(parsed[1].row.source == "handy-computer/example-gguf")
    }

    @Test("a row with no flags at all writes and reads back")
    func noFlags() throws {
        let bare = EngineCapabilities(
            batch: false, live: false, wordTimestamps: false, segmentTimestamps: false,
            vocabulary: false, diarization: false, languageID: false, languageHint: false,
            languages: ["en"], minimumMacOS: "15.0")
        let rows = [
            CatalogFileRow(
                row: CatalogRow(
                    id: "fluid.helper", family: .parakeet, role: .helper,
                    source: "FluidInference/helper", precision: "int8", label: "Helper"),
                capabilities: bare)
        ]
        let parsed = try CatalogFile.parse(try CatalogFile.text(rows, generator: "test"))
        #expect(parsed == rows)
        #expect(parsed[0].modes.isEmpty)
        #expect(parsed[0].features.isEmpty)
        #expect(parsed[0].row.role == .helper)
    }

    /// The writer refuses rather than escaping. Every field is a literal in this
    /// repository, so a tab in one is a mistake, and a file that parses back
    /// into different data than went in is the failure this exists to prevent.
    @Test("a field with a tab or newline is refused")
    func refusesSeparators() throws {
        for bad in ["two\tfields", "two\nlines"] {
            let rows = [
                CatalogFileRow(
                    row: CatalogRow(
                        id: "ggml.bad@q8_0", family: .whisper, precision: "q8_0", label: bad),
                    capabilities: Self.capabilities())
            ]
            #expect(throws: SpeechError.self) {
                _ = try CatalogFile.text(rows, generator: "test")
            }
        }
    }

    @Test("comments and blank lines are skipped")
    func comments() throws {
        let text = try CatalogFile.text(Self.sample(), generator: "test")
        let noisy = "# a comment\n\n   \n" + text + "\n\n"
        #expect(try CatalogFile.parse(noisy) == Self.sample())
    }

    @Test("a malformed line names what is wrong with it")
    func malformed() throws {
        let good = try CatalogFile.text(Self.sample(), generator: "test")
        let row = try #require(good.split(separator: "\n").last.map(String.init))

        // Too few columns.
        #expect(throws: SpeechError.self) { _ = try CatalogFile.parse("a\tb\tc") }
        // An unknown family, an unknown role, and an id whose prefix disagrees
        // with the engine column: each is a hand edit that would otherwise
        // produce a plausible-looking row nobody can run.
        for (find, replace) in [
            ("\twhisper\t", "\tvoxtral\t"),
            ("\ttranscriber\t", "\tornament\t"),
            ("ggml.example@q8_0", "fluid.example@q8_0"),
            ("\t42\t", "\tmany\t"),
        ] {
            let broken = row.replacingOccurrences(of: find, with: replace)
            #expect(broken != row, "the test's own substitution '\(find)' did nothing")
            #expect(throws: SpeechError.self) { _ = try CatalogFile.parse(broken) }
        }
    }

    /// Swift makes "\r\n" one Character, so `split(separator: "\n")` never
    /// matches it: a CRLF file used to come back as a single line that began
    /// with '#', which the parser discarded as a comment and returned zero rows
    /// with no error at all. A checkout with `core.autocrlf` would have done
    /// it.
    @Test("a file with any line ending parses to the same rows")
    func lineEndings() throws {
        let unix = try CatalogFile.text(Self.sample(), generator: "test")
        let expected = try CatalogFile.parse(unix)
        #expect(expected.count == Self.sample().count)
        let windows = unix.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try CatalogFile.parse(windows) == expected, "CRLF")
        let classicMac = unix.replacingOccurrences(of: "\n", with: "\r")
        #expect(try CatalogFile.parse(classicMac) == expected, "CR")
        #expect(try CatalogFile.parse("\u{FEFF}" + unix) == expected, "byte order mark")
    }

    /// The writer refuses anything the parser could not hand back, because a
    /// round trip that returns different data is worse than one that fails.
    @Test("the writer refuses fields the parser would reinterpret")
    func refusesAmbiguousFields() {
        func attempt(_ change: (inout CatalogRow) -> Void) -> Bool {
            var row = CatalogRow(
                id: "ggml.example@q8_0", family: .whisper, source: "handy-computer/example-gguf",
                file: "example-Q8_0.gguf", parametersM: 42, precision: "q8_0",
                label: "Example")
            change(&row)
            let entry = CatalogFileRow(row: row, capabilities: Self.capabilities())
            return (try? CatalogFile.text([entry], generator: "test")) == nil
        }
        // An id starting with '#' would be skipped as a comment and vanish.
        #expect(attempt { $0.id = "#ggml.example@q8_0" })
        // A real value spelled like a placeholder comes back as the
        // placeholder's meaning rather than as itself.
        #expect(attempt { $0.source = "-" })
        #expect(attempt { $0.file = "*" })
    }

    @Test("a list element that would not survive the split is refused")
    func refusesAmbiguousLists() {
        func attempt(_ languages: [String]) -> Bool {
            let entry = CatalogFileRow(
                row: Catalog.rows[0], languages: languages, modes: ["batch"],
                features: ["seg_ts"], minimumMacOS: "15.0")
            return (try? CatalogFile.text([entry], generator: "test")) == nil
        }
        #expect(attempt(["en", ""]), "an empty element would be dropped")
        #expect(attempt(["en", "de,fr"]), "a comma would silently become two entries")
        #expect(attempt(["en", "*"]), "a reserved placeholder inside a list")
        #expect(!attempt(["en", "de"]), "the test's own control")
    }

    /// The generator string lands in a comment, and a newline in it would end
    /// that comment and begin a line the parser reads as data.
    @Test("a generator string with a newline is refused")
    func refusesGeneratorNewline() {
        #expect(throws: SpeechError.self) {
            _ = try CatalogFile.text(Self.sample(), generator: "test\nggml.injected@q8_0")
        }
    }

    /// "+42" and "007" both parse and both write back differently than they
    /// were read, so a hand-edited file would not survive this program.
    @Test("a number that is not written plainly is refused")
    func refusesLooseNumbers() throws {
        let text = try CatalogFile.text(Self.sample(), generator: "test")
        let row = try #require(text.split(separator: "\n").last.map(String.init))
        for bad in ["\t+42\t", "\t042\t", "\t-42\t"] {
            let broken = row.replacingOccurrences(of: "\t42\t", with: bad)
            #expect(broken != row)
            #expect(throws: SpeechError.self) { _ = try CatalogFile.parse(broken) }
        }
    }

    /// A catalog id becomes a directory under the model store, and a file is
    /// the first place one can arrive from outside argv.
    @Test("an id with a traversal component is refused")
    func refusesTraversal() throws {
        let text = try CatalogFile.text(Self.sample(), generator: "test")
        let row = try #require(text.split(separator: "\n").last.map(String.init))
        for bad in ["ggml.../../../Documents", "ggml./etc/passwd"] {
            let broken = row.replacingOccurrences(of: "ggml.example@q8_0", with: bad)
            #expect(throws: SpeechError.self) { _ = try CatalogFile.parse(broken) }
        }
    }

    @Test("a duplicate id is refused")
    func duplicates() throws {
        let text = try CatalogFile.text(Self.sample(), generator: "test")
        let row = try #require(text.split(separator: "\n").last.map(String.init))
        #expect(throws: SpeechError.self) { _ = try CatalogFile.parse(text + row + "\n") }
    }
}

@Suite("The checked-in catalog file")
struct CatalogFileOnDiskTests {
    /// docs/models.catalog.tsv is what the applet reads without running the
    /// binary, so it has to agree with the table this binary was built from.
    /// This half of the check needs no engines: it compares the columns this
    /// repository records. test.sh covers the other half by regenerating the
    /// file, which is the only way to check the capability columns against
    /// live engines.
    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SpeechCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("docs/models.catalog.tsv")
    }

    @Test("it parses and carries exactly the inventory's rows, in order")
    func matchesTheTable() throws {
        let text = try String(contentsOf: Self.url, encoding: .utf8)
        let parsed = try CatalogFile.parse(text)
        #expect(parsed.map(\.row) == Catalog.rows)
    }

    /// The writer leaves the final terminator to whoever writes the file, and
    /// the verb's sink supplies exactly one. A second newline crept in once and
    /// only showed up as a one-byte diff in test.sh with no obvious cause.
    @Test("the file ends with exactly one newline")
    func trailingNewline() throws {
        let text = try String(contentsOf: Self.url, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        #expect(!text.hasSuffix("\n\n"))
    }

    /// The inventory's header claims which engine versions produced its
    /// capability columns. FluidAudio has no runtime version to ask, so the
    /// claim is a literal, and a literal that drifts from the manifest is worse
    /// than no claim at all - it attributes an answer to the wrong library.
    @Test("the FluidAudio version claimed in the header is the one pinned")
    func packagePinMatchesLiteral() throws {
        let manifest = Self.url
            .deletingLastPathComponent()  // docs
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Package.swift")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let line = try #require(
            text.split(separator: "\n").first { $0.contains("FluidInference/FluidAudio") },
            "the FluidAudio dependency is gone from Package.swift")
        // `.package(url: "...", exact: "0.15.6"),`
        let pin = try #require(
            line.split(separator: "\"").last(where: { $0.contains(".") }).map(String.init))
        let claimed = try String(contentsOf: Self.url, encoding: .utf8)
            .split(separator: "\n")
            .first { $0.hasPrefix("#   fluidaudio: ") }
            .map { String($0.dropFirst("#   fluidaudio: ".count)) }
        #expect(claimed == pin,
                "the catalog header says FluidAudio \(claimed ?? "nothing") and Package.swift pins \(pin)")
    }

    @Test("every row names a macOS floor and at least one mode")
    func columns() throws {
        let parsed = try CatalogFile.parse(try String(contentsOf: Self.url, encoding: .utf8))
        for entry in parsed {
            #expect(!entry.minimumMacOS.isEmpty)
            if entry.row.role == .transcriber {
                #expect(entry.modes.contains("batch"), "\(entry.row.id) cannot transcribe a file")
            }
        }
    }
}
