// Markdown -> DOCX (Arabic RTL) for D:\Dafter\fix-plan.md
import fs from "node:fs";
import path from "node:path";
import {
  AlignmentType, Document, Footer, Header, HeadingLevel, ImportedXmlComponent,
  Packer, PageNumber, Paragraph, ShadingType, Table, TableCell, TableRow,
  TextRun, WidthType, convertInchesToTwip,
} from "docx";

const outputPath = process.argv[2];
if (!outputPath) throw new Error("Usage: node build-fix-plan-docx.js /abs/output.docx");
const mdPath = path.join(path.dirname(outputPath), "fix-plan.md");
const md = fs.readFileSync(mdPath, "utf8");

const font = { ascii: "Arial", hAnsi: "Arial", cs: "Arial" };
const codeFont = { ascii: "Consolas", hAnsi: "Consolas", cs: "Arial" };
const run = (text, options = {}) => new TextRun({ text, font, size: 24, ...options });
const para = (children, options = {}) => new Paragraph({
  bidirectional: true,
  spacing: { after: 120, line: 300 },
  ...options,
  children: Array.isArray(children) ? children : [children],
});

function parseInline(text, base = {}) {
  const runs = [];
  const re = /(\*\*[^*]+\*\*|`[^`]+`)/g;
  let last = 0, m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) runs.push(run(text.slice(last, m.index), base));
    const tok = m[0];
    if (tok.startsWith("**")) runs.push(run(tok.slice(2, -2), { ...base, bold: true }));
    else runs.push(run(tok.slice(1, -1), { ...base, font: codeFont, size: 20 }));
    last = m.index + tok.length;
  }
  if (last < text.length) runs.push(run(text.slice(last), base));
  return runs.length ? runs : [run("", base)];
}

const pBody = (text) => para(parseInline(text), { alignment: AlignmentType.JUSTIFIED });
const h1 = (text) => para(run(text, { bold: true, size: 32, color: "1F3A2E" }), {
  heading: HeadingLevel.HEADING_1, alignment: AlignmentType.RIGHT,
  spacing: { before: 360, after: 160 },
});
const h2 = (text) => para(run(text, { bold: true, size: 28, color: "2E5543" }), {
  heading: HeadingLevel.HEADING_2, alignment: AlignmentType.RIGHT,
  spacing: { before: 280, after: 140 },
});
const h3 = (text) => para(run(text, { bold: true, size: 25, color: "3E6B54" }), {
  heading: HeadingLevel.HEADING_3, alignment: AlignmentType.RIGHT,
  spacing: { before: 220, after: 120 },
});
const bullet = (text, level = 0) => para(parseInline(text), {
  alignment: AlignmentType.JUSTIFIED,
  indent: { right: convertInchesToTwip(0.3 + level * 0.25) },
  bullet: { level },
});
const quote = (text) => para(parseInline(text, { italics: true, color: "555555" }), {
  alignment: AlignmentType.JUSTIFIED,
  indent: { right: convertInchesToTwip(0.4) },
  shading: { type: ShadingType.CLEAR, fill: "F4F1EA" },
});

function makeTable(rows) {
  const cols = rows[0].length;
  const w = Math.floor(9000 / cols);
  const widths = Array(cols).fill(w);
  const cell = (text, header) => new TableCell({
    children: [para(parseInline(text, header ? { bold: true, size: 21 } : { size: 21 }),
      { alignment: AlignmentType.RIGHT, spacing: { after: 40, line: 260 } })],
    margins: { top: 80, bottom: 80, left: 100, right: 100 },
    shading: header ? { type: ShadingType.CLEAR, fill: "E8EFE9" } : undefined,
  });
  return new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    columnWidths: widths,
    visuallyRightToLeft: true,
    rows: rows.map((r, i) => new TableRow({
      tableHeader: i === 0,
      children: r.map((c) => cell(c, i === 0)),
    })),
  });
}

// ---- Parse markdown ----
const lines = md.split(/\r?\n/);
const children = [];
const tocEntries = [];
let i = 0;
let estPage = 3;
while (i < lines.length) {
  const line = lines[i];
  if (!line.trim() || line.trim() === "---") { i++; continue; }
  if (line.startsWith("|")) {
    const rows = [];
    while (i < lines.length && lines[i].startsWith("|")) {
      const l = lines[i];
      if (!/^\|[\s:|-]+\|$/.test(l.trim())) {
        rows.push(l.split("|").slice(1, -1).map((c) => c.trim()));
      }
      i++;
    }
    if (rows.length) children.push(makeTable(rows), para(run(""), { spacing: { after: 120 } }));
    continue;
  }
  if (line.startsWith("### ")) {
    const t = line.slice(4).trim();
    children.push(h3(t)); tocEntries.push({ title: t, level: 3, page: estPage });
  } else if (line.startsWith("## ")) {
    const t = line.slice(3).trim();
    children.push(h2(t)); tocEntries.push({ title: t, level: 2, page: estPage }); estPage += 2;
  } else if (line.startsWith("# ")) {
    const t = line.slice(2).trim();
    children.push(h1(t)); tocEntries.push({ title: t, level: 1, page: estPage }); estPage += 2;
  } else if (line.startsWith("> ")) {
    children.push(quote(line.slice(2).trim()));
  } else if (/^\s*- /.test(line)) {
    children.push(bullet(line.replace(/^\s*- /, "").trim()));
  } else if (/^\s*\d+\. /.test(line)) {
    children.push(para(parseInline(line.trim()), {
      alignment: AlignmentType.JUSTIFIED,
      indent: { right: convertInchesToTwip(0.3) },
    }));
  } else {
    children.push(pBody(line.trim()));
  }
  i++;
}

// ---- TOC (RTL: bidi paragraphs, dot leader to the left) ----
const xmlEscape = (v) => String(v)
  .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
const toc = (entries) => {
  const cached = entries.map(({ title, level, page }) => {
    const indent = Math.max(0, level - 1) * 360;
    return `<w:p><w:pPr><w:bidi/><w:pStyle w:val="TOC${level}"/>
      <w:tabs><w:tab w:val="left" w:leader="dot" w:pos="9000"/></w:tabs>
      <w:ind w:right="${indent}"/></w:pPr>
      <w:r><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/><w:sz w:val="22"/></w:rPr><w:t>${xmlEscape(title)}</w:t></w:r><w:r><w:tab/></w:r><w:r><w:t>${page}</w:t></w:r></w:p>`;
  }).join("");
  return ImportedXmlComponent.fromXmlString(`<w:sdt xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:sdtPr><w:alias w:val="فهرس المحتويات"/></w:sdtPr>
    <w:sdtContent>
      <w:p><w:r><w:fldChar w:fldCharType="begin" w:dirty="true"/>
        <w:instrText xml:space="preserve"> TOC \\o &quot;1-3&quot; \\h \\z \\u </w:instrText>
        <w:fldChar w:fldCharType="separate"/></w:r></w:p>
      ${cached}
      <w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>
    </w:sdtContent>
  </w:sdt>`).root[0];
};

const cover = [
  para(run("الخطة الرئيسية الموحدة لإصلاح نظام «دفتر ديون / مُثبَت»", { bold: true, size: 44, color: "1F3A2E" }), {
    alignment: AlignmentType.CENTER, spacing: { before: 2400, after: 320 },
  }),
  para(run("دمج خطط الإصلاح التسع في خطة تنفيذ رئيسية واحدة مع حسم التعارضات", { size: 28, color: "2E5543" }), {
    alignment: AlignmentType.CENTER, spacing: { after: 240 },
  }),
  para(run("كبير المهندسين المعماريين (Chief_Architect_Integrator) — 2026-08-18", { size: 22, color: "666666" }), {
    alignment: AlignmentType.CENTER, spacing: { after: 1200 },
  }),
  para(run("فهرس المحتويات", { bold: true, size: 30, color: "1F3A2E" }), {
    alignment: AlignmentType.RIGHT, spacing: { before: 400, after: 200 },
  }),
  toc(tocEntries),
  new Paragraph({ pageBreakBefore: true, children: [run("")] }),
];

const doc = new Document({
  features: { updateFields: true },
  creator: "Chief_Architect_Integrator",
  title: "الخطة الرئيسية الموحدة لإصلاح نظام دفتر ديون",
  sections: [{
    properties: { page: { margin: { top: 1200, right: 1200, bottom: 1200, left: 1200 } } },
    headers: { default: new Header({ children: [para(run("الخطة الرئيسية — دفتر ديون / مُثبَت", { bold: true, size: 20, color: "666666" }), { alignment: AlignmentType.CENTER })] }) },
    footers: { default: new Footer({ children: [para(new TextRun({ children: [PageNumber.CURRENT], font, size: 20 }), { alignment: AlignmentType.CENTER })] }) },
    children: [...cover, ...children],
  }],
});

fs.writeFileSync(outputPath, await Packer.toBuffer(doc));
console.log("WROTE", outputPath);
