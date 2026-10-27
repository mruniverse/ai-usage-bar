import XCTest
@testable import UsageCore

final class ClaudeUsageParserTests: XCTestCase {
    func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    /// 27/10/2026 15:00 em São Paulo (UTC-3).
    var now: Date { iso("2026-10-27T18:00:00Z") }

    func parse(_ text: String, now: Date? = nil) throws -> [UsageWindow] { try ClaudeUsageParser.parse(text, now: now ?? self.now).windows }
    func assertUnrecognized(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(text), file: file, line: line) {
            guard case ProviderError.unrecognizedFormat = $0 else { return XCTFail("erro inesperado: \($0)", file: file, line: line) }
        }
    }

    // MARK: formato real observado

    func testRealObservedOutput() throws {
        let windows = try parse(realUsageSample)
        XCTAssertEqual(windows.map(\.title), ["Sessão", "Semanal"])
        XCTAssertEqual(windows.map(\.usedPercent), [42, 28])
        XCTAssertEqual(windows[0].reset, iso("2026-10-27T22:10:00Z"))   // 7:10pm -03
        XCTAssertEqual(windows[1].reset, iso("2026-11-02T20:00:00Z"))   // 5pm sem minutos
    }

    func testHourWithoutMinutesAndTwelveHourEdges() throws {
        func reset(_ time: String) throws -> Date? {
            try parse("Current session: 1% used · resets Oct 28 at \(time) (America/Sao_Paulo)")[0].reset
        }
        XCTAssertEqual(try reset("12am"), iso("2026-10-28T03:00:00Z"))      // meia-noite = 00:00
        XCTAssertEqual(try reset("12:30am"), iso("2026-10-28T03:30:00Z"))
        XCTAssertEqual(try reset("12pm"), iso("2026-10-28T15:00:00Z"))      // meio-dia = 12:00
        XCTAssertEqual(try reset("12:05pm"), iso("2026-10-28T15:05:00Z"))
        XCTAssertEqual(try reset("1am"), iso("2026-10-28T04:00:00Z"))
        XCTAssertEqual(try reset("11:59pm"), iso("2026-10-29T02:59:00Z"))
        XCTAssertEqual(try reset("5PM"), iso("2026-10-28T20:00:00Z"))
    }

    func testResetRespectsReportedTimezone() throws {
        let line = { (zone: String) in "Current session: 5% used · resets Oct 28 at 9am (\(zone))" }
        XCTAssertEqual(try parse(line("Asia/Tokyo"))[0].reset, iso("2026-10-28T00:00:00Z"))
        XCTAssertEqual(try parse(line("America/Sao_Paulo"))[0].reset, iso("2026-10-28T12:00:00Z"))
        XCTAssertEqual(try parse(line("UTC"))[0].reset, iso("2026-10-28T09:00:00Z"))
        XCTAssertEqual(try parse(line("America/New_York"))[0].reset, iso("2026-10-28T13:00:00Z"))   // EDT (UTC-4)
    }

    // MARK: ano inferido (reset sempre no futuro)

    func testYearRolloverForwardInSaoPaulo() throws {
        let dec31 = iso("2026-12-31T23:00:00Z")   // 20:00 em SP, 31/12/2026
        let w = try parse("Current week (all models): 10% used · resets Jan 3 at 5pm (America/Sao_Paulo)", now: dec31)
        XCTAssertEqual(w[0].reset, iso("2027-01-03T20:00:00Z"))
    }

    func testYearRolloverUsesYearOfReportedTimezoneNotUTC() throws {
        // Em UTC ainda é 31/12/2026, mas em Tóquio já é 1/1/2027.
        let nowUTC = iso("2026-12-31T23:30:00Z")
        let w = try parse("Current session: 1% used · resets Jan 3 at 5pm (Asia/Tokyo)", now: nowUTC)
        XCTAssertEqual(w[0].reset, iso("2027-01-03T08:00:00Z"))
    }

    func testJustPassedResetAcrossNewYearKeepsPreviousYear() throws {
        // 1/1/2027 00:10 em SP; reset de 31/12 às 11pm passou há menos de 1 dia: continua 2026 (não vira 2027).
        let nowJan1 = iso("2027-01-01T03:10:00Z")
        let w = try parse("Current session: 100% used · resets Dec 31 at 11pm (America/Sao_Paulo)", now: nowJan1)
        XCTAssertEqual(w[0].reset, iso("2027-01-01T02:00:00Z"))
    }

    func testResetPastByMoreThanADayMovesToNextYear() throws {
        let w = try parse("Current session: 1% used · resets Oct 20 at 5pm (America/Sao_Paulo)")
        XCTAssertEqual(w[0].reset, iso("2027-10-20T20:00:00Z"))
        // Passado há menos de 1 dia: permanece no ano corrente (a UI mostra renovação indisponível).
        let recent = try parse("Current session: 1% used · resets Oct 27 at 9am (America/Sao_Paulo)")
        XCTAssertEqual(recent[0].reset, iso("2026-10-27T12:00:00Z"))
    }

    func testLeapDayAndImpossibleDates() throws {
        let now2027 = iso("2027-01-10T12:00:00Z")
        // 29/02 só existe em 2028: o ano candidato 2027 é inválido, 2028 serve.
        XCTAssertEqual(try parse("Current session: 1% used · resets Feb 29 at 5pm (UTC)", now: now2027)[0].reset, iso("2028-02-29T17:00:00Z"))
        XCTAssertNil(try parse("Current session: 1% used · resets Feb 30 at 5pm (UTC)", now: now2027)[0].reset)
    }

    // MARK: reset não parseável → sem reset (não zero)

    func testUnparseableResetYieldsWindowWithoutReset() throws {
        for tail in ["· resets soon", "· resets Oct 27 at 25pm (America/Sao_Paulo)", "· resets Oct 27 at 7:75pm (America/Sao_Paulo)",
                     "· resets Foo 27 at 7pm (America/Sao_Paulo)", "· resets Oct 27 at 7pm (Mars/Olympus)", "· resets Oct 27 at 7pm",
                     "· resets Oct 27 at 0pm (UTC)", "", "· resets"] {
            let w = try parse("Current session: 42% used \(tail)")
            XCTAssertEqual(w.count, 1, tail)
            XCTAssertEqual(w[0].usedPercent, 42, tail)
            XCTAssertNil(w[0].reset, tail)
        }
    }

    // MARK: linhas extras, desconhecidas, tolerância

    func testExtraModelWindowsAreLabeledAndOrdered() throws {
        let text = """
        Current week (Opus): 7% used · resets Nov 2 at 5pm (America/Sao_Paulo)
        Current week (all models): 28% used · resets Nov 2 at 5pm (America/Sao_Paulo)
        Current week (Sonnet): 3% used
        Current session: 42% used · resets Oct 27 at 7:10pm (America/Sao_Paulo)
        """
        let windows = try parse(text)
        XCTAssertEqual(windows.map(\.title), ["Sessão", "Semanal", "Semanal · Opus", "Semanal · Sonnet"])
        XCTAssertEqual(windows.map(\.usedPercent), [42, 28, 7, 3])
        XCTAssertNil(windows[3].reset)
    }

    func testUnknownLinesAreIgnoredAndNeverFail() throws {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        Extra usage: not enabled
        Current session: 42% used · resets Oct 27 at 7:10pm (America/Sao_Paulo)
        Some future line: with: colons and 99% used
        Current week: 5% used
        Current week (): 5% used
        Current month (all models): 5% used
        Current week (all models): 28% used · resets Nov 2 at 5pm (America/Sao_Paulo)
        Tip: run /usage-credits
        """
        XCTAssertEqual(try parse(text).map(\.title), ["Sessão", "Semanal"])
        XCTAssertEqual(try parse(text).map(\.usedPercent), [42, 28])
    }

    func testToleratesCRLFAnsiExtraSpacesCaseAndBoundaryPercents() throws {
        let text = "\u{1B}[1mCURRENT SESSION:\u{1B}[0m   0%   used  ·  resets   Oct 27 at 7:10pm   (America/Sao_Paulo)\r\ncurrent week (All Models): 100% used\r\n"
        let windows = try parse(text)
        XCTAssertEqual(windows.map(\.usedPercent), [0, 100])
        XCTAssertEqual(windows[0].reset, iso("2026-10-27T22:10:00Z"))
    }

    func testDuplicateLineKeepsTheFirst() throws {
        let windows = try parse("Current session: 10% used\nCurrent session: 90% used\n")
        XCTAssertEqual(windows.map(\.usedPercent), [10])
    }

    func testParseIsDeterministic() throws {
        let a = try parse(realUsageSample), b = try parse(realUsageSample)
        XCTAssertEqual(a.map(\.usedPercent), b.map(\.usedPercent))
        XCTAssertEqual(a.map(\.reset), b.map(\.reset))
        XCTAssertEqual(a.map(\.title), b.map(\.title))
    }

    // MARK: percentual inválido e formato não reconhecido (nunca 0%)

    func testInvalidPercentIsUnrecognizedNeverZero() {
        for bad in ["101", "-5", "1000", "abc", "", "42.5", "4 2", "NaN", "٤٢"] {
            assertUnrecognized("Current session: \(bad)% used · resets Oct 27 at 7:10pm (America/Sao_Paulo)")
        }
        assertUnrecognized("Current session: sem percentual · resets Oct 27 at 7:10pm (America/Sao_Paulo)")
        assertUnrecognized("Current session: 42 used")
        // Uma linha ruim invalida tudo, mesmo havendo outra válida: melhor não mostrar do que mostrar errado.
        assertUnrecognized("Current session: 42% used\nCurrent week (all models): 140% used")
    }

    func testEmptyAndForeignLanguageAreUnrecognized() {
        assertUnrecognized("")
        assertUnrecognized("   \n\n  ")
        assertUnrecognized("Você está usando sua assinatura\n\nSessão atual: 42% usado · reinicia 27 de out às 19:10 (America/Sao_Paulo)\nSemana atual (todos os modelos): 28% usado")
        assertUnrecognized("You are currently using your subscription to power your Claude Code usage\n")
        assertUnrecognized("{\"error\":\"boom\"}")
    }

    func testNonSubscriptionAndLoginTextsMapToExistingStates() {
        guard case .disconnected? = ClaudeUsageParser.classifyNonSubscription("Not logged in · Please run /login") else { return XCTFail() }
        guard case .apiKeyAccount? = ClaudeUsageParser.classifyNonSubscription("You are using an API key") else { return XCTFail() }
        XCTAssertNil(ClaudeUsageParser.classifyNonSubscription("totally different"))
    }
}
