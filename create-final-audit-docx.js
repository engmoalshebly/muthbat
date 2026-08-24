import fs from "node:fs";
import path from "node:path";
import {
  AlignmentType, Document, Footer, Header, HeadingLevel, ImportedXmlComponent,
  Packer, PageNumber, Paragraph, ShadingType, Table, TableCell, TableRow,
  TextRun, WidthType, PageBreak,
} from "docx";

const outputPath = process.argv[2];
if (!outputPath) throw new Error("Usage: node create.js /absolute/path/output.docx");

const mdPath = path.join(path.dirname(outputPath), "final-audit-report.md");
const md = fs.readFileSync(mdPath, "utf-8");
const lines = md.split(/\r?\n/);

// ---------- fonts & helpers (RTL) ----------
const fontBody = { ascii: "Segoe UI", hAnsi: "Segoe UI", cs: "Arial" };
const fontCode = { ascii: "Consolas", hAnsi: "Consolas", cs: "Arial" };

const run = (text, options = {}) =>
  new TextRun({ text, font: fontBody, size: 22, rightToLeft: true, ...options });

const para = (children, options = {}) =>
  new Paragraph({
    bidirectional: true,
    alignment: AlignmentType.JUSTIFIED,
    spacing: { after: 120, line: 300 },
    ...options,
    children: Array.isArray(children) ? children : [children],
  });

// inline markdown: **bold**, *italic*, `code`
function inlineRuns(text, baseOptions = {}) {
  const out = [];
  const re = /(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`)/g;
  let last = 0, m;
  const push = (t, o) => { if (t) out.push(run(t, { ...baseOptions, ...o })); };
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) push(text.slice(last, m.index), {});
    const tok = m[0];
    if (tok.startsWith("**")) push(tok.slice(2, -2), { bold: true });
    else if (tok.startsWith("*")) push(tok.slice(1, -1), { italics: true });
    else out.push(new TextRun({ text: tok.slice(1, -1), font: fontCode, size: 20, rightToLeft: true, ...baseOptions }));
    last = m.index + tok.length;
  }
  if (last < text.length) push(text.slice(last), {});
  return out.length ? out : [run("", baseOptions)];
}

const stripMd = (t) => t.replace(/\*\*([^*]+)\*\*/g, "$1").replace(/\*([^*]+)\*/g, "$1").replace(/`([^`]+)`/g, "$1");

const heading = (text, level) => {
  const sizes = { 1: 32, 2: 28, 3: 24, 4: 22 };
  const levels = { 1: HeadingLevel.HEADING_1, 2: HeadingLevel.HEADING_2, 3: HeadingLevel.HEADING_3, 4: HeadingLevel.HEADING_4 };
  return para(run(stripMd(text), { bold: true, size: sizes[level] || 22 }), {
    heading: levels[level] || HeadingLevel.HEADING_4,
    alignment: AlignmentType.RIGHT,
    spacing: { before: level <= 2 ? 320 : 200, after: 140, line: 300 },
  });
};

// ---------- TOC helper (build-tested shape) ----------
const xmlEscape = (v) => String(v).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
const toc = (entries) => {
  const cached = entries.map(({ title, level, page }) => {
    const indent = Math.max(0, level - 1) * 360;
    return `<w:p><w:pPr><w:pStyle w:val="TOC${level}"/><w:bidi/>
      <w:tabs><w:tab w:val="right" w:leader="dot" w:pos="9000"/></w:tabs>
      <w:ind w:right="${indent}"/></w:pPr>
      <w:r><w:rPr><w:rtl/></w:rPr><w:t>${xmlEscape(title)}</w:t></w:r><w:r><w:tab/></w:r><w:r><w:t>${page}</w:t></w:r></w:p>`;
  }).join("");
  return ImportedXmlComponent.fromXmlString(`<w:sdt xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:sdtPr><w:alias w:val="المحتويات"/></w:sdtPr>
    <w:sdtContent>
      <w:p><w:r><w:fldChar w:fldCharType="begin" w:dirty="true"/>
        <w:instrText xml:space="preserve"> TOC \\o &quot;1-2&quot; \\h \\z \\u </w:instrText>
        <w:fldChar w:fldCharType="separate"/></w:r></w:p>
      ${cached}
      <w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>
    </w:sdtContent>
  </w:sdt>`).root[0];
};

// ---------- tables ----------
const PAGE_WIDTH = 9026; // A4, 1" margins
function columnWidths(n) {
  if (n >= 4) {
    const first = 500, last = 1250;
    const mid = Math.floor((PAGE_WIDTH - first - last) / (n - 2));
    return [first, ...Array(n - 2).fill(mid), last];
  }
  return Array(n).fill(Math.floor(PAGE_WIDTH / n));
}
const cell = (text, width, header = false) => new TableCell({
  children: [para(inlineRuns(text, { size: 18, bold: header }), {
    alignment: AlignmentType.RIGHT,
    spacing: { after: 40, line: 260 },
  })],
  width: { size: width, type: WidthType.DXA },
  margins: { top: 80, bottom: 80, left: 80, right: 80 },
  shading: header ? { type: ShadingType.CLEAR, fill: "EEF3F6" } : undefined,
});
function buildTable(tableLines) {
  const rows = tableLines
    .filter((l) => !/^\|[\s:|-]+\|$/.test(l.trim()))
    .map((l) => l.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((s) => s.trim()));
  if (!rows.length) return null;
  const n = rows[0].length;
  const widths = columnWidths(n);
  return new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    columnWidths: widths,
    visuallyRightToLeft: true,
    rows: rows.map((r, i) => new TableRow({
      tableHeader: i === 0,
      children: Array.from({ length: n }, (_, c) => cell(r[c] ?? "", widths[c], i === 0)),
    })),
  });
}

// ---------- parse markdown ----------
const children = [];
const tocEntries = [];
let i = 0;
// skip leading title/metadata block (goes on cover) — body starts at first "## "
let bodyStart = lines.findIndex((l) => l.startsWith("## "));
if (bodyStart < 0) bodyStart = 0;
i = bodyStart;

let pageEst = 3;
while (i < lines.length) {
  const line = lines[i];
  const trimmed = line.trim();

  if (!trimmed) { i++; continue; }
  if (/^---+$/.test(trimmed)) { i++; continue; }

  const h = trimmed.match(/^(#{1,4})\s+(.*)$/);
  if (h) {
    const level = h[1].length;
    children.push(heading(h[2], level));
    if (level <= 2) { tocEntries.push({ title: stripMd(h[2]), level, page: pageEst }); }
    pageEst += level === 1 ? 4 : 2;
    i++; continue;
  }

  if (trimmed.startsWith("|")) {
    const tbl = [];
    while (i < lines.length && lines[i].trim().startsWith("|")) { tbl.push(lines[i]); i++; }
    const t = buildTable(tbl);
    if (t) { children.push(t); children.push(para(run(""), { spacing: { after: 120 } })); }
    continue;
  }

  const bullet = trimmed.match(/^[-*]\s+(.*)$/);
  if (bullet) {
    children.push(para([run("• "), ...inlineRuns(bullet[1])], { indent: { right: 360 } }));
    i++; continue;
  }
  const numbered = trimmed.match(/^(\d+)\.\s+(.*)$/);
  if (numbered) {
    children.push(para([run(numbered[1] + ". ", { bold: true }), ...inlineRuns(numbered[2])], { indent: { right: 360 } }));
    i++; continue;
  }
  if (trimmed.startsWith(">")) {
    children.push(para(inlineRuns(trimmed.replace(/^>\s?/, ""), { italics: true }), { indent: { right: 360 } }));
    i++; continue;
  }

  children.push(para(inlineRuns(trimmed)));
  i++;
}

// ---------- cover ----------
const cover = [
  para(run("التقرير النهائي الموحد للتدقيق الشامل", { bold: true, size: 44 }), {
    alignment: AlignmentType.CENTER, spacing: { before: 2400, after: 200 },
  }),
  para(run("نظام «دفتر ديون» (مُثبَت) — قبل الإطلاق التجاري", { size: 28 }), {
    alignment: AlignmentType.CENTER, spacing: { after: 600 },
  }),
  para(run("دمج وتوثيق نهائي لعشرة تقارير تدقيق متخصصة", { size: 24 }), { alignment: AlignmentType.CENTER, spacing: { after: 120 } }),
  para(run("النطاق: باكند Supabase (debt-ledger-supabase) وتطبيق Flutter (mobile)", { size: 22 }), { alignment: AlignmentType.CENTER, spacing: { after: 120 } }),
  para(run("المصادر: analysis-reports/ — التقارير 01 إلى 10", { size: 22 }), { alignment: AlignmentType.CENTER, spacing: { after: 120 } }),
  para(run("الإجمالي: 52 حرج · 51 عالي · 62 متوسط · 47 منخفض · 75 إيجابي", { bold: true, size: 22 }), { alignment: AlignmentType.CENTER }),
  new Paragraph({ children: [new PageBreak()] }),
  para(run("المحتويات", { bold: true, size: 30 }), { alignment: AlignmentType.RIGHT, spacing: { after: 200 } }),
  toc(tocEntries),
  new Paragraph({ children: [new PageBreak()] }),
];

// ---------- document ----------
const doc = new Document({
  features: { updateFields: true },
  sections: [{
    properties: { page: { margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } } },
    headers: { default: new Header({ children: [para(run("التقرير النهائي للتدقيق الشامل — نظام دفتر ديون", { size: 18 }), { alignment: AlignmentType.CENTER })] }) },
    footers: { default: new Footer({ children: [para(new TextRun({ children: [PageNumber.CURRENT], size: 18 }), { alignment: AlignmentType.CENTER })] }) },
    children: [...cover, ...children],
  }],
});

fs.writeFileSync(outputPath, await Packer.toBuffer(doc));
console.log("Wrote", outputPath);
