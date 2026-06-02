import Foundation

/// The smart-formatting chain (spec: 2026-06-spoken-text-smart-formatting.md).
/// Order is load-bearing — years and ordinals before cardinal merging; digits
/// before currency/units/dates/times; dates before symbols (so date
/// "hyphen"/"dash" separators are consumed by the ISO pattern); punctuation last.
public enum SpokenTextFormatter {
    public static func format(_ text: String) -> String {
        var result = text
        result = YearNormalizer.normalize(result)
        result = OrdinalNormalizer.normalize(result)
        result = NumberNormalizer.normalize(result)
        result = CurrencyNormalizer.normalize(result)
        result = UnitNormalizer.normalize(result)
        result = DateNormalizer.normalize(result)
        result = TimeNormalizer.normalize(result)
        result = PhoneRunNormalizer.normalize(result)
        result = EmailURLNormalizer.normalize(result)
        result = SymbolNormalizer.normalize(result)
        result = PunctuationNormalizer.normalize(result)
        return result
    }
}
