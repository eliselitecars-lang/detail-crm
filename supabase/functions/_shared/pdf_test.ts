import { assert, assertEquals } from "@std/assert";
import {
  embedImage,
  imageKind,
  isSafeJpeg,
  isSafePng,
  MARGIN,
  PAGE_CONTENT_HEIGHT,
  PAGE_HEIGHT,
  PdfWriter,
} from "./pdf.ts";
import { LOGO_PNG } from "./testing/images.ts";

const b64 = (text: string) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

/** Right chunk layout, wrong CRCs and garbage pixel data (pdf-lib alone spins on it). */
const CORRUPT_PNG = b64(
  "iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAIAAAAt/+nTAAAAKUlEQVR42u3OMQEAAAgDoK1/aNXXgQYk5DjHSkBAQEBAQEBAQEBAQOAvYGU4AUHw5mH6AAAAAElFTkSuQmCC",
);

function jpeg(segments: number[][]): Uint8Array {
  return new Uint8Array([0xff, 0xd8, ...segments.flat()]);
}
const APP0 = [0xff, 0xe0, 0x00, 0x06, 0x4a, 0x46, 0x49, 0x46];
const SOF0 = [
  0xff,
  0xc0,
  0x00,
  0x11,
  0x08,
  0x00,
  0x20,
  0x00,
  0x40,
  0x03,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
];

Deno.test("pdf images: PNG structure is verified before pdf-lib decodes it", async () => {
  assertEquals(imageKind(LOGO_PNG), "png");
  assertEquals(await isSafePng(LOGO_PNG), true);
  assertEquals(await isSafePng(CORRUPT_PNG), false);
  const flipped = LOGO_PNG.slice();
  flipped[40] = (flipped[40] ?? 0) ^ 0xff; // inside IDAT: CRC no longer matches
  assertEquals(await isSafePng(flipped), false);
  assertEquals(await isSafePng(LOGO_PNG.slice(0, 50)), false); // truncated
  assertEquals(await isSafePng(new TextEncoder().encode("GIF89a....")), false);
});

Deno.test("pdf images: JPEG segments must move forward and stay in bounds", () => {
  assertEquals(isSafeJpeg(jpeg([APP0, SOF0])), true);
  // a zero-length segment would make pdf-lib loop forever
  assertEquals(isSafeJpeg(jpeg([[0xff, 0xe1, 0x00, 0x00], SOF0])), false);
  assertEquals(isSafeJpeg(jpeg([[0xff, 0xe1, 0x7f, 0xff], SOF0])), false);
  assertEquals(isSafeJpeg(jpeg([APP0])), false); // no frame header
  assertEquals(isSafeJpeg(jpeg([APP0, [0xff, 0xc0, 0x00, 0x11, 0x08, 0, 0, 0, 0x40, 3]])), false);
});

Deno.test("pdf images: embedImage embeds good images and skips bad ones quickly", async () => {
  const w = await PdfWriter.create({ title: "t" });
  const good = await embedImage(w.doc, LOGO_PNG);
  assert(good);
  assertEquals([good.width, good.height], [64, 32]);
  assertEquals(await embedImage(w.doc, CORRUPT_PNG), null);
  assertEquals(await embedImage(w.doc, jpeg([[0xff, 0xe1, 0x00, 0x00]])), null);
  assert(await embedImage(w.doc, jpeg([APP0, SOF0])));
});

interface Draw {
  page: number;
  text: string;
  y: number;
}

/** Records every text run the writer draws (page index + baseline). */
function recordDraws(w: PdfWriter): Draw[] {
  const draws: Draw[] = [];
  const watch = (page: PdfWriter["page"]) => {
    const index = w.doc.getPageCount() - 1;
    const original = page.drawText.bind(page);
    page.drawText = (text, options) => {
      draws.push({ page: index, text, y: options?.y ?? 0 });
      original(text, options);
    };
    return page;
  };
  watch(w.page);
  const addPage = w.doc.addPage.bind(w.doc);
  w.doc.addPage =
    ((...args: Parameters<typeof addPage>) => watch(addPage(...args))) as typeof addPage;
  return draws;
}

const COLUMNS = [
  { width: 296 },
  { width: 60, align: "right" as const },
  { width: 80, align: "right" as const },
  { width: 80, align: "right" as const },
];
const FOOTER_TOP = MARGIN + 36;

Deno.test("pdf rows: a row taller than a page continues on the next pages, nothing below the footer", async () => {
  const w = await PdfWriter.create({ title: "t" });
  const draws = recordDraws(w);
  w.y -= 300; // start mid-page, like a line table under the header
  const words = Array.from({ length: 900 }, (_, i) => `w${i + 1}`);
  w.row(COLUMNS, [["Full detail", words.join(" ")], ["1"], ["$10.00"], ["$10.00"]], {
    firstBold: true,
  });
  w.row(COLUMNS, [["Next line"], ["1"], ["$1.00"], ["$1.00"]]);
  assert(w.doc.getPageCount() >= 2, `expected a continuation page, got ${w.doc.getPageCount()}`);
  for (const draw of draws) {
    assert(
      draw.y >= FOOTER_TOP && draw.y <= PAGE_HEIGHT - MARGIN,
      `"${draw.text}" drawn at y=${draw.y}`,
    );
  }
  // every word is drawn exactly once, in order
  const drawn = draws.flatMap((d) => d.text.split(" ")).filter((t) => /^w\d+$/.test(t));
  assertEquals(drawn, words);
  // the first page is used (the row starts where the cursor was) and the next row follows it
  assertEquals(draws[0]?.page, 0);
  const next = draws.find((d) => d.text === "Next line");
  assertEquals(next?.page, w.doc.getPageCount() - 1);
  assert(w.y >= FOOTER_TOP);
});

Deno.test("pdf rows: a row that fits on a page is moved whole to the next page", async () => {
  const w = await PdfWriter.create({ title: "t" });
  const draws = recordDraws(w);
  w.y = FOOTER_TOP + 30; // room for about two lines
  const lines = Array.from({ length: 6 }, (_, i) => `detail ${i + 1}`);
  w.row(COLUMNS, [["Item", ...lines], ["1"], ["$1.00"], ["$1.00"]]);
  assertEquals(w.doc.getPageCount(), 2);
  assert(draws.every((d) => d.page === 1), "the row should not be split");
  assert(PAGE_CONTENT_HEIGHT > 600);
});
