/**
 * Minimal text extraction for PDFs written by _shared/pdf.ts (tests only):
 * inflates every FlateDecode stream, reads the hex strings shown with Tj
 * (how pdf-lib draws standard-font text) and decodes them as WinAnsi.
 * Returns the text runs in drawing order, one array per content stream.
 */

const WIN_ANSI_HIGH: Readonly<Record<number, string>> = {
  0x80: "€",
  0x82: "‚",
  0x83: "ƒ",
  0x84: "„",
  0x85: "…",
  0x86: "†",
  0x87: "‡",
  0x88: "ˆ",
  0x89: "‰",
  0x8a: "Š",
  0x8b: "‹",
  0x8c: "Œ",
  0x8e: "Ž",
  0x91: "‘",
  0x92: "’",
  0x93: "“",
  0x94: "”",
  0x95: "•",
  0x96: "–",
  0x97: "—",
  0x98: "˜",
  0x99: "™",
  0x9a: "š",
  0x9b: "›",
  0x9c: "œ",
  0x9e: "ž",
  0x9f: "Ÿ",
};

function decodeWinAnsi(hex: string): string {
  let out = "";
  for (let i = 0; i + 1 < hex.length; i += 2) {
    const byte = parseInt(hex.slice(i, i + 2), 16);
    out += WIN_ANSI_HIGH[byte] ?? String.fromCharCode(byte);
  }
  return out;
}

async function inflate(bytes: Uint8Array<ArrayBuffer>): Promise<Uint8Array | null> {
  try {
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate"));
    return new Uint8Array(await new Response(stream).arrayBuffer());
  } catch {
    return null;
  }
}

function indexOf(haystack: Uint8Array, needle: string, from: number): number {
  const codes = [...needle].map((c) => c.charCodeAt(0));
  outer: for (let i = from; i <= haystack.length - codes.length; i++) {
    for (let j = 0; j < codes.length; j++) {
      if (haystack[i + j] !== codes[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/** Text runs per content stream, in drawing order. */
export async function extractPdfText(pdf: Uint8Array): Promise<string[][]> {
  const runs: string[][] = [];
  let cursor = 0;
  while (true) {
    const start = indexOf(pdf, "stream", cursor);
    if (start < 0) break;
    let dataStart = start + "stream".length;
    if (pdf[dataStart] === 0x0d) dataStart++;
    if (pdf[dataStart] === 0x0a) dataStart++;
    const end = indexOf(pdf, "endstream", dataStart);
    if (end < 0) break;
    cursor = end + "endstream".length;
    // "endstream" also contains "stream": skip matches that are the tail of it
    if (
      start >= 3 &&
      String.fromCharCode(pdf[start - 3] ?? 0, pdf[start - 2] ?? 0, pdf[start - 1] ?? 0) === "end"
    ) {
      continue;
    }
    // the EOL before "endstream" is not part of the data
    let dataEnd = end;
    if (pdf[dataEnd - 1] === 0x0a) dataEnd--;
    if (pdf[dataEnd - 1] === 0x0d) dataEnd--;
    const inflated = await inflate(pdf.slice(dataStart, dataEnd));
    if (!inflated) continue;
    const content = new TextDecoder("latin1").decode(inflated);
    const texts = [...content.matchAll(/<([0-9A-Fa-f]*)>\s*Tj/g)].map((m) =>
      decodeWinAnsi(m[1] ?? "")
    );
    if (texts.length) runs.push(texts);
  }
  return runs;
}

/** Every text run of the document joined with newlines (for `includes` checks). */
export async function pdfText(pdf: Uint8Array): Promise<string> {
  return (await extractPdfText(pdf)).map((page) => page.join("\n")).join("\n");
}
