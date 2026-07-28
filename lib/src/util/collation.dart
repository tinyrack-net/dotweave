/// Approximates Node's `String.prototype.localeCompare` (ICU root locale)
/// for the ASCII-dominated filename domain this CLI sorts: case-insensitive
/// primary comparison with a lowercase-first tiebreak.
///
/// Divergences from full ICU collation (punctuation weighting, non-ASCII
/// scripts) are recorded in PARITY.md.
int compareLocaleLike(String a, String b) {
  final primary = a.toLowerCase().compareTo(b.toLowerCase());
  if (primary != 0) {
    return primary;
  }
  if (a == b) {
    return 0;
  }
  return -a.compareTo(b);
}
