/// How an empty result describes itself.
///
/// "No finished sessions since 2026-08-30" is ordinary English for *there were
/// some before then*, and a model reads it that way: given an account with
/// nothing in it at all, the coach reported "the last trace of a session is 30
/// August" — a date it had never been given, lifted straight out of the
/// sentence that was meant to say the opposite. It looked like a hallucination
/// and was really a phrasing bug, which is the more dangerous of the two
/// because no amount of prompting fixes it.
///
/// So an empty window says what was searched and admits what was not. The
/// boundary date stays — it is real, and the coach needs it to say how far
/// back it can see — but it is attached to the search rather than to the data.
export function emptyWindow(what: string, from: string): string {
  return `${what} in the window searched (${from} to today). Nothing before ${from} was looked at, so this says nothing about earlier.`;
}
