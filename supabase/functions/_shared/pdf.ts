/**
 * PDF layout helpers on pdf-lib (pinned npm:pdf-lib@1.17.1): a top-down
 * writer over US Letter pages with word wrapping, automatic page breaks,
 * right-aligned columns, a diagonal watermark and "Page i of n" footers.
 *
 * Fonts are the standard Helvetica pair (no font files to ship). Standard
 * fonts only cover WinAnsi (Western European) characters: `pdfSafe`
 * transliterates what it can (accents are kept, "ł" -> "l", arrows -> "->")
 * and replaces anything else with "?", because pdf-lib throws on a
 * character the font cannot encode.
 */
import {
  degrees,
  PDFDocument,
  type PDFFont,
  type PDFImage,
  type PDFPage,
  type RGB,
  rgb,
  StandardFonts,
} from "pdf-lib";

export const PAGE_WIDTH = 612; // US Letter, points
export const PAGE_HEIGHT = 792;
export const MARGIN = 48;
export const CONTENT_WIDTH = PAGE_WIDTH - 2 * MARGIN;
const FOOTER_SPACE = 36;
/** Lowest baseline content may use (the footer sits below it). */
const PAGE_BOTTOM = MARGIN + FOOTER_SPACE;
/** Height available to content on a fresh page. */
export const PAGE_CONTENT_HEIGHT = PAGE_HEIGHT - MARGIN - PAGE_BOTTOM;
const ROW_PAD = 4;
const ROW_LINE_GAP = 3;

interface RowLine {
  text: string;
  size: number;
  isMain: boolean;
}

export const COLORS = {
  text: rgb(0.1, 0.12, 0.16),
  muted: rgb(0.42, 0.45, 0.5),
  rule: rgb(0.85, 0.87, 0.9),
  fill: rgb(0.96, 0.97, 0.98),
  watermark: rgb(0.75, 0.2, 0.2),
} as const;

const FALLBACKS: Readonly<Record<string, string>> = {
  "←": "<-",
  "→": "->",
  "↔": "<->",
  "−": "-",
  "‐": "-",
  "‑": "-",
  "‒": "-",
  "―": "-",
  "′": "'",
  "″": '"',
  "⁄": "/",
  "≈": "~",
  "≤": "<=",
  "≥": ">=",
  "≠": "!=",
  " ": " ",
  " ": " ",
  " ": " ",
  " ": " ",
  " ": " ",
  "✓": "v",
  "✔": "v",
  "✗": "x",
  "Ł": "L",
  "ł": "l",
  "Đ": "D",
  "đ": "d",
  "ı": "i",
  "ß": "ss",
};

const ZERO_WIDTH = /[​-‍⁠﻿]/g;

/**
 * `text` restricted to the characters `font` can encode (see the header).
 * Newlines and tabs become spaces; callers split paragraphs first.
 */
export function pdfSafe(text: string, font: PDFFont): string {
  const supported = charsetOf(font);
  let out = "";
  for (const char of text.replace(ZERO_WIDTH, "").replace(/[\t\r\n]+/g, " ")) {
    const code = char.codePointAt(0) ?? 0;
    if (supported.has(code)) {
      out += char;
      continue;
    }
    const fallback = FALLBACKS[char];
    if (fallback !== undefined) {
      out += fallback;
      continue;
    }
    const stripped = char.normalize("NFKD").replace(/[̀-ͯ]/g, "");
    if (stripped !== "" && [...stripped].every((c) => supported.has(c.codePointAt(0) ?? 0))) {
      out += stripped;
      continue;
    }
    if (code < 0x20) continue;
    out += "?";
  }
  return out;
}

const charsets = new WeakMap<PDFFont, Set<number>>();
function charsetOf(font: PDFFont): Set<number> {
  let set = charsets.get(font);
  if (!set) {
    set = new Set(font.getCharacterSet());
    charsets.set(font, set);
  }
  return set;
}

/** Splits `text` into lines no wider than `maxWidth` (words longer than a line are broken). */
export function wrapText(text: string, font: PDFFont, size: number, maxWidth: number): string[] {
  const lines: string[] = [];
  for (const paragraph of text.replace(/\r\n?/g, "\n").split("\n")) {
    const words = pdfSafe(paragraph, font).split(/ +/).filter((w) => w !== "");
    if (words.length === 0) {
      lines.push("");
      continue;
    }
    let line = "";
    for (const word of words) {
      const candidate = line === "" ? word : `${line} ${word}`;
      if (font.widthOfTextAtSize(candidate, size) <= maxWidth) {
        line = candidate;
        continue;
      }
      if (line !== "") lines.push(line);
      // a single word wider than the line: break it by characters
      let rest = word;
      while (font.widthOfTextAtSize(rest, size) > maxWidth && rest.length > 1) {
        let cut = rest.length - 1;
        while (cut > 1 && font.widthOfTextAtSize(rest.slice(0, cut), size) > maxWidth) cut--;
        lines.push(rest.slice(0, cut));
        rest = rest.slice(cut);
      }
      line = rest;
    }
    lines.push(line);
  }
  return lines;
}

export interface TextOptions {
  x?: number;
  size?: number;
  bold?: boolean;
  color?: RGB;
  /** Right edge for right-aligned text (default: the content's right edge). */
  alignRight?: number;
}

export interface Column {
  width: number;
  align?: "left" | "right";
}

export interface WriterOptions {
  title: string;
  subject?: string;
  /** Diagonal mark on every page, e.g. "DRAFT" or "VOID". */
  watermark?: string | null;
  /** Left footer text on every page. */
  footer?: string;
}

/** A top-down page writer. `y` is the baseline cursor, moving down. */
export class PdfWriter {
  readonly doc: PDFDocument;
  readonly regular: PDFFont;
  readonly bold: PDFFont;
  readonly options: WriterOptions;
  page: PDFPage;
  y: number;

  private constructor(
    doc: PDFDocument,
    regular: PDFFont,
    bold: PDFFont,
    options: WriterOptions,
  ) {
    this.doc = doc;
    this.regular = regular;
    this.bold = bold;
    this.options = options;
    this.page = this.#newPage();
    this.y = PAGE_HEIGHT - MARGIN;
  }

  static async create(options: WriterOptions, now: Date = new Date()): Promise<PdfWriter> {
    const doc = await PDFDocument.create();
    doc.setTitle(options.title);
    if (options.subject) doc.setSubject(options.subject);
    doc.setProducer("Detail CRM");
    doc.setCreator("Detail CRM");
    doc.setCreationDate(now);
    doc.setModificationDate(now);
    const regular = await doc.embedFont(StandardFonts.Helvetica);
    const bold = await doc.embedFont(StandardFonts.HelveticaBold);
    return new PdfWriter(doc, regular, bold, options);
  }

  #newPage(): PDFPage {
    return this.doc.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  }

  font(bold = false): PDFFont {
    return bold ? this.bold : this.regular;
  }

  /** Starts a new page when fewer than `height` points remain above the footer. */
  ensure(height: number): void {
    if (this.y - height < PAGE_BOTTOM) this.#breakPage();
  }

  #breakPage(): void {
    this.page = this.#newPage();
    this.y = PAGE_HEIGHT - MARGIN;
  }

  /** Moves the cursor down. */
  space(points: number): void {
    this.y -= points;
  }

  /** Draws one line of text at the cursor (no wrapping, no cursor move). */
  text(value: string, options: TextOptions = {}): void {
    const font = this.font(options.bold);
    const size = options.size ?? 10;
    const safe = pdfSafe(value, font);
    if (safe === "") return;
    const x = options.alignRight !== undefined
      ? options.alignRight - font.widthOfTextAtSize(safe, size)
      : options.x ?? MARGIN;
    this.page.drawText(safe, {
      x,
      y: this.y,
      size,
      font,
      color: options.color ?? COLORS.text,
    });
  }

  /** Wrapped paragraph at the cursor; moves the cursor below it. */
  paragraph(
    value: string,
    options: TextOptions & { width?: number; lineGap?: number } = {},
  ): void {
    const size = options.size ?? 10;
    const lineHeight = size + (options.lineGap ?? 3);
    const lines = wrapText(value, this.font(options.bold), size, options.width ?? CONTENT_WIDTH);
    for (const line of lines) {
      this.ensure(lineHeight);
      this.y -= lineHeight;
      this.text(line, { ...options, size });
    }
  }

  /** A horizontal rule across the content width at the cursor. */
  rule(color: RGB = COLORS.rule, thickness = 0.75): void {
    this.page.drawLine({
      start: { x: MARGIN, y: this.y },
      end: { x: PAGE_WIDTH - MARGIN, y: this.y },
      thickness,
      color,
    });
  }

  /**
   * One table row. Each cell is a list of lines (the first drawn in `bold`
   * when asked, the rest muted and smaller); the row is as tall as its
   * tallest cell. A row that fits on one page is never split across pages;
   * a row taller than a whole page (a very long description) continues its
   * cells at the top of the following page(s), so no line is lost.
   */
  row(
    columns: readonly Column[],
    cells: ReadonlyArray<readonly string[]>,
    options: { size?: number; bold?: boolean; fill?: boolean; firstBold?: boolean } = {},
  ): void {
    const size = options.size ?? 9.5;
    const subSize = size - 1;
    const pad = ROW_PAD;
    const firstBold = options.bold === true || options.firstBold === true;
    const wrapped: RowLine[][] = cells.map((lines, index) => {
      const width = (columns[index]?.width ?? 0) - 2 * pad;
      return lines.flatMap((line, lineIndex) => {
        const isMain = lineIndex === 0;
        const lineSize = isMain ? size : subSize;
        const font = this.font(isMain && firstBold);
        return wrapText(line, font, lineSize, width).map((text) => ({
          text,
          size: lineSize,
          isMain,
        }));
      });
    });
    const cellHeight = (lines: readonly RowLine[]) =>
      lines.reduce((sum, line) => sum + line.size + ROW_LINE_GAP, 0);
    const height = Math.max(0, ...wrapped.map(cellHeight)) + 2 * pad;
    if (height <= PAGE_CONTENT_HEIGHT) {
      this.ensure(height);
      this.#rowBand(columns, wrapped, height, options.fill === true, firstBold);
      return;
    }
    // Taller than a page: start here when at least one line fits, then fill
    // each page's remaining space and carry the rest of every cell over.
    this.ensure(3 * (size + ROW_LINE_GAP) + 2 * pad);
    const pending = wrapped.map((lines) => [...lines]);
    while (pending.some((lines) => lines.length > 0)) {
      const available = this.y - PAGE_BOTTOM - 2 * pad;
      const fresh = this.y === PAGE_HEIGHT - MARGIN;
      const band = pending.map((lines) => {
        let used = 0;
        let count = 0;
        for (const line of lines) {
          if (used + line.size + ROW_LINE_GAP > available) break;
          used += line.size + ROW_LINE_GAP;
          count++;
        }
        // a fresh page always takes at least one line, so the loop progresses
        if (count === 0 && fresh && lines.length > 0) count = 1;
        return lines.splice(0, count);
      });
      if (band.some((lines) => lines.length > 0)) {
        const bandHeight = Math.max(...band.map(cellHeight)) + 2 * pad;
        this.#rowBand(columns, band, bandHeight, options.fill === true, firstBold);
      }
      if (pending.some((lines) => lines.length > 0)) this.#breakPage();
    }
  }

  /** Draws one page's part of a row with its top at the cursor; moves the cursor below it. */
  #rowBand(
    columns: readonly Column[],
    cells: ReadonlyArray<readonly RowLine[]>,
    height: number,
    fill: boolean,
    firstBold: boolean,
  ): void {
    const pad = ROW_PAD;
    if (fill) {
      this.page.drawRectangle({
        x: MARGIN,
        y: this.y - height,
        width: CONTENT_WIDTH,
        height,
        color: COLORS.fill,
      });
    }
    let x = MARGIN;
    const top = this.y;
    for (const [index, column] of columns.entries()) {
      let y = top - pad;
      for (const line of cells[index] ?? []) {
        y -= line.size + ROW_LINE_GAP;
        this.y = y;
        const bold = line.isMain && firstBold;
        const color = line.isMain ? COLORS.text : COLORS.muted;
        if (column.align === "right") {
          this.text(line.text, {
            size: line.size,
            bold,
            alignRight: x + column.width - pad,
            color,
          });
        } else {
          this.text(line.text, { x: x + pad, size: line.size, bold, color });
        }
      }
      x += column.width;
    }
    this.y = top - height;
  }

  /** Label / value pairs right-aligned in a block (totals). */
  totals(
    rows: ReadonlyArray<{ label: string; value: string; bold?: boolean }>,
    width = 240,
  ): void {
    const right = PAGE_WIDTH - MARGIN;
    // keep the block on one page
    this.ensure(rows.reduce((sum, row) => sum + (row.bold ? 11 : 9.5) + 6, 0));
    for (const row of rows) {
      const size = row.bold ? 11 : 9.5;
      this.y -= size + 6;
      this.text(row.label, { x: right - width, size, bold: row.bold });
      this.text(row.value, { alignRight: right, size, bold: row.bold });
    }
  }

  /** Draws an image scaled to fit `maxWidth` x `maxHeight` with its top-left at (x, cursor). */
  image(image: PDFImage, x: number, maxWidth: number, maxHeight: number): number {
    const scale = Math.min(maxWidth / image.width, maxHeight / image.height, 1);
    const width = image.width * scale;
    const height = image.height * scale;
    this.page.drawImage(image, { x, y: this.y - height, width, height });
    return height;
  }

  /** Adds the watermark and page footers, then serializes the document. */
  async finish(): Promise<Uint8Array> {
    const pages = this.doc.getPages();
    for (const [index, page] of pages.entries()) {
      const mark = this.options.watermark ? pdfSafe(this.options.watermark, this.bold) : "";
      if (mark) {
        const size = 96;
        const width = this.bold.widthOfTextAtSize(mark, size);
        const angle = 35;
        const rad = (angle * Math.PI) / 180;
        page.drawText(mark, {
          x: PAGE_WIDTH / 2 - (width / 2) * Math.cos(rad) + (size / 3) * Math.sin(rad),
          y: PAGE_HEIGHT / 2 - (width / 2) * Math.sin(rad) - (size / 3) * Math.cos(rad),
          size,
          font: this.bold,
          color: COLORS.watermark,
          opacity: 0.12,
          rotate: degrees(angle),
        });
      }
      const footer = this.options.footer ? pdfSafe(this.options.footer, this.regular) : "";
      const size = 8;
      if (footer) {
        page.drawText(footer, {
          x: MARGIN,
          y: MARGIN - 16,
          size,
          font: this.regular,
          color: COLORS.muted,
        });
      }
      const label = `Page ${index + 1} of ${pages.length}`;
      page.drawText(label, {
        x: PAGE_WIDTH - MARGIN - this.regular.widthOfTextAtSize(label, size),
        y: MARGIN - 16,
        size,
        font: this.regular,
        color: COLORS.muted,
      });
    }
    return await this.doc.save({ useObjectStreams: false });
  }
}

/** PNG or JPEG by magic bytes (the only formats pdf-lib embeds), else null. */
export function imageKind(bytes: Uint8Array): "png" | "jpeg" | null {
  if (
    bytes.length > 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e &&
    bytes[3] === 0x47
  ) {
    return "png";
  }
  if (bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "jpeg";
  }
  return null;
}

/** Largest logo side we decode (bounds memory: pdf-lib decodes PNGs to raw pixels). */
export const MAX_IMAGE_SIDE = 2000;

let crcTable: Uint32Array | undefined;
function crc32(bytes: Uint8Array, start: number, end: number): number {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  let crc = 0xffffffff;
  for (let i = start; i < end; i++) {
    crc = (crcTable[(crc ^ (bytes[i] ?? 0)) & 0xff] ?? 0) ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

const PNG_CHANNELS: Readonly<Record<number, number>> = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };
const PNG_DEPTHS: Readonly<Record<number, readonly number[]>> = {
  0: [1, 2, 4, 8, 16],
  2: [8, 16],
  3: [1, 2, 4, 8],
  4: [8, 16],
  6: [8, 16],
};

/**
 * Structural PNG check before pdf-lib sees the bytes: pdf-lib's decoder can
 * spin forever on corrupt data, so every chunk CRC, the header, the palette
 * and the full inflated size of the pixel data are verified first.
 * Interlaced images are refused (a logo never needs them).
 */
export async function isSafePng(bytes: Uint8Array): Promise<boolean> {
  if (imageKind(bytes) !== "png" || bytes.length < 8 + 25) return false;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (signature.some((b, i) => bytes[i] !== b)) return false;
  let pos = 8;
  let header: { width: number; height: number; depth: number; color: number } | null = null;
  let palette = false;
  let ended = false;
  const idat: Uint8Array[] = [];
  while (pos + 12 <= bytes.length) {
    const length = view.getUint32(pos);
    const type = String.fromCharCode(...bytes.subarray(pos + 4, pos + 8));
    const dataEnd = pos + 8 + length;
    if (length > bytes.length || dataEnd + 4 > bytes.length) return false;
    if (crc32(bytes, pos + 4, dataEnd) !== view.getUint32(dataEnd)) return false;
    if (header === null && type !== "IHDR") return false;
    if (type === "IHDR") {
      if (header !== null || length !== 13) return false;
      const width = view.getUint32(pos + 8);
      const height = view.getUint32(pos + 12);
      const depth = bytes[pos + 16] ?? 0;
      const color = bytes[pos + 17] ?? 0;
      const interlace = bytes[pos + 20] ?? 0;
      if (width < 1 || height < 1 || width > MAX_IMAGE_SIDE || height > MAX_IMAGE_SIDE) {
        return false;
      }
      if (!PNG_DEPTHS[color]?.includes(depth) || interlace !== 0) return false;
      if ((bytes[pos + 18] ?? 1) !== 0 || (bytes[pos + 19] ?? 1) !== 0) return false;
      header = { width, height, depth, color };
    } else if (type === "PLTE") {
      if (length === 0 || length % 3 !== 0 || length > 768) return false;
      palette = true;
    } else if (type === "IDAT") {
      idat.push(bytes.subarray(pos + 8, dataEnd));
    } else if (type === "IEND") {
      ended = true;
      break;
    }
    pos = dataEnd + 4;
  }
  if (!header || !ended || idat.length === 0) return false;
  if (header.color === 3 && !palette) return false;
  const channels = PNG_CHANNELS[header.color] ?? 0;
  const rowBytes = Math.ceil((header.width * channels * header.depth) / 8);
  const expected = header.height * (1 + rowBytes);
  try {
    const stream = new Blob(idat as Uint8Array<ArrayBuffer>[]).stream()
      .pipeThrough(new DecompressionStream("deflate"));
    const reader = stream.getReader();
    let size = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > expected) {
        await reader.cancel();
        return false;
      }
    }
    return size === expected;
  } catch {
    return false;
  }
}

/** pdf-lib's JPEG start-of-frame markers (it scans for the first of them). */
const JPEG_SOF: ReadonlySet<number> = new Set([
  0xffc0,
  0xffc1,
  0xffc2,
  0xffc3,
  0xffc5,
  0xffc6,
  0xffc7,
  0xffc8,
  0xffc9,
  0xffca,
  0xffcb,
  0xffcc,
  0xffcd,
  0xffce,
  0xffcf,
]);

/**
 * Walks the JPEG segments exactly as pdf-lib does, but refuses a segment
 * length that would not move forward (pdf-lib would loop forever) or run
 * past the end, and checks the frame header it will read.
 */
export function isSafeJpeg(bytes: Uint8Array): boolean {
  if (imageKind(bytes) !== "jpeg") return false;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let pos = 2;
  while (pos + 4 <= bytes.length) {
    const marker = view.getUint16(pos);
    pos += 2;
    if (JPEG_SOF.has(marker)) {
      if (pos + 8 > bytes.length) return false;
      const height = view.getUint16(pos + 3);
      const width = view.getUint16(pos + 5);
      const channels = bytes[pos + 7] ?? 0;
      return height > 0 && width > 0 && height <= 10 * MAX_IMAGE_SIDE &&
        width <= 10 * MAX_IMAGE_SIDE && [1, 3, 4].includes(channels);
    }
    const length = view.getUint16(pos);
    if (length < 2 || pos + length > bytes.length) return false;
    pos += length;
  }
  return false;
}

/**
 * Embeds a PNG/JPEG after the structural checks above; null when the bytes
 * are neither, fail a check, or cannot be decoded.
 */
export async function embedImage(
  doc: PDFDocument,
  bytes: Uint8Array,
): Promise<PDFImage | null> {
  try {
    const kind = imageKind(bytes);
    if (kind === "png" && await isSafePng(bytes)) return await doc.embedPng(bytes);
    if (kind === "jpeg" && isSafeJpeg(bytes)) return await doc.embedJpg(bytes);
  } catch {
    return null;
  }
  return null;
}
