#!/usr/bin/env bash
# ==============================================================================
# CatCar Platform - Delivery PDF Generation Script
# ==============================================================================
# Generates the academic delivery document in PDF format (A4) using headless
# Chromium. Supports HTML directly or Markdown (with auto-conversion).
#
# Usage:
#   ./scripts/generate-delivery-pdf.sh [INPUT_FILE] [OUTPUT_PDF]
#
# Defaults:
#   INPUT_FILE : docs/delivery/TECH_CHALLENGE_FASE_3_ENTREGA.html (or .md)
#   OUTPUT_PDF : docs/delivery/TECH_CHALLENGE_FASE_3_ENTREGA.pdf
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_DOCS_DIR="${REPO_ROOT}/docs/delivery"
DEFAULT_HTML_INPUT="${DEFAULT_DOCS_DIR}/TECH_CHALLENGE_FASE_3_ENTREGA.html"
DEFAULT_MD_INPUT="${DEFAULT_DOCS_DIR}/TECH_CHALLENGE_FASE_3_ENTREGA.md"
DEFAULT_PDF_OUTPUT="${DEFAULT_DOCS_DIR}/TECH_CHALLENGE_FASE_3_ENTREGA.pdf"

INPUT_PATH="${1:-}"
OUTPUT_PDF="${2:-${DEFAULT_PDF_OUTPUT}}"

echo "================================================================="
echo "CatCar Platform — Delivery PDF Generator"
echo "================================================================="

# ------------------------------------------------------------------------------
# 1. Locate Headless Chromium binary
# ------------------------------------------------------------------------------
find_chromium() {
    local candidates=(
        "/usr/bin/chromium"
        "/usr/bin/google-chrome"
        "/usr/bin/google-chrome-stable"
        "/usr/bin/chromium-browser"
        "$(command -v chromium 2>/dev/null || true)"
        "$(command -v google-chrome 2>/dev/null || true)"
    )

    for bin in "${candidates[@]}"; do
        if [[ -n "${bin}" && -x "${bin}" ]]; then
            echo "${bin}"
            return 0
        fi
    done

    return 1
}

CHROMIUM_BIN="$(find_chromium || true)"
if [[ -z "${CHROMIUM_BIN}" ]]; then
    echo "[-] Error: Headless Chromium binary was not found on this system." >&2
    echo "    Please install chromium or google-chrome." >&2
    exit 1
fi
echo "[+] Using Chromium binary: ${CHROMIUM_BIN}"

# ------------------------------------------------------------------------------
# 2. Determine and resolve Input File
# ------------------------------------------------------------------------------
mkdir -p "$(dirname "${OUTPUT_PDF}")"
mkdir -p "${DEFAULT_DOCS_DIR}"

if [[ -z "${INPUT_PATH}" ]]; then
    if [[ -f "${DEFAULT_HTML_INPUT}" ]]; then
        INPUT_PATH="${DEFAULT_HTML_INPUT}"
    elif [[ -f "${DEFAULT_MD_INPUT}" ]]; then
        INPUT_PATH="${DEFAULT_MD_INPUT}"
    else
        INPUT_PATH="${DEFAULT_HTML_INPUT}"
    fi
fi

if [[ ! -f "${INPUT_PATH}" ]]; then
    echo "[-] Input file '${INPUT_PATH}' does not exist." >&2
    exit 1
fi

echo "[+] Input file:  ${INPUT_PATH}"
echo "[+] Output file: ${OUTPUT_PDF}"

# ------------------------------------------------------------------------------
# 3. CSS Print Stylesheet
# ------------------------------------------------------------------------------
CSS_PRINT_STYLES='
@page {
  size: A4;
  margin: 18mm 15mm;
  @bottom-right {
    content: counter(page);
    font-size: 8pt;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    color: #64748b;
  }
}

@page :first {
  margin-top: 15mm;
}

* {
  box-sizing: border-box;
  -webkit-print-color-adjust: exact !important;
  print-color-adjust: exact !important;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  font-size: 10pt;
  line-height: 1.5;
  color: #1e293b;
  margin: 0;
  padding: 0;
}

h1, h2, h3, h4, h5, h6 {
  color: #0f172a;
  font-weight: 700;
  margin-top: 1.3em;
  margin-bottom: 0.4em;
  page-break-after: avoid;
  break-after: avoid;
}

h1 {
  font-size: 16pt;
  border-bottom: 2px solid #2563eb;
  padding-bottom: 5px;
  page-break-before: always;
  break-before: page;
}

h1:first-of-type,
h1.no-break {
  page-break-before: avoid;
  break-before: avoid;
}

h2 {
  font-size: 13pt;
  border-bottom: 1px solid #e2e8f0;
  padding-bottom: 4px;
}

h3 {
  font-size: 11pt;
  color: #1d4ed8;
}

h4 {
  font-size: 10pt;
  color: #334155;
}

p, ul, ol {
  margin-top: 0;
  margin-bottom: 0.7em;
}

li {
  margin-bottom: 0.25em;
}

a {
  color: #2563eb;
  text-decoration: none;
}

table {
  width: 100%;
  border-collapse: collapse;
  margin: 0.9em 0;
  font-size: 8.5pt;
  page-break-inside: avoid;
  break-inside: avoid;
}

th, td {
  border: 1px solid #cbd5e1;
  padding: 6px 8px;
  text-align: left;
  vertical-align: top;
}

th {
  background-color: #f1f5f9;
  color: #0f172a;
  font-weight: 600;
}

tr:nth-child(even) td {
  background-color: #f8fafc;
}

tr {
  page-break-inside: avoid;
  break-inside: avoid;
}

code {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
  font-size: 8pt;
  background-color: #f1f5f9;
  color: #0f172a;
  padding: 1px 4px;
  border-radius: 3px;
  border: 1px solid #e2e8f0;
}

pre {
  background-color: #0f172a;
  color: #f8fafc;
  padding: 10px 12px;
  border-radius: 5px;
  overflow-x: auto;
  font-size: 8pt;
  line-height: 1.35;
  page-break-inside: avoid;
  break-inside: avoid;
  margin: 0.8em 0;
}

pre code {
  background: none;
  color: inherit;
  padding: 0;
  border: none;
  font-size: inherit;
}

blockquote {
  border-left: 3px solid #94a3b8;
  margin: 0.8em 0;
  padding: 6px 12px;
  color: #475569;
  background-color: #f8fafc;
  page-break-inside: avoid;
  break-inside: avoid;
}

.badge {
  display: inline-block;
  padding: 2px 7px;
  font-size: 7.5pt;
  font-weight: 600;
  border-radius: 9999px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.badge-success {
  background-color: #dcfce7;
  color: #166534;
  border: 1px solid #86efac;
}

.badge-info {
  background-color: #e0f2fe;
  color: #0369a1;
  border: 1px solid #7dd3fc;
}

.badge-warning {
  background-color: #fef9c3;
  color: #854d0e;
  border: 1px solid #fde047;
}

.badge-primary {
  background-color: #dbeafe;
  color: #1e40af;
  border: 1px solid #93c5fd;
}

.callout {
  border-left: 4px solid #2563eb;
  background-color: #eff6ff;
  padding: 8px 12px;
  margin: 0.8em 0;
  border-radius: 0 5px 5px 0;
  page-break-inside: avoid;
  break-inside: avoid;
}

.callout-success {
  border-left-color: #16a34a;
  background-color: #f0fdf4;
}

.callout-warning {
  border-left-color: #eab308;
  background-color: #fefce8;
}

.callout-title {
  font-weight: 700;
  color: #1e40af;
  margin-bottom: 3px;
  font-size: 9.5pt;
}

.callout-success .callout-title {
  color: #15803d;
}

.cover {
  text-align: center;
  padding: 80px 20px 60px;
  page-break-after: always;
  break-after: page;
}

.cover h1 {
  font-size: 26pt;
  border-bottom: none;
  margin-top: 15px;
  margin-bottom: 12px;
  color: #0f172a;
}

.cover .subtitle {
  font-size: 13pt;
  color: #475569;
  margin-bottom: 25px;
  line-height: 1.4;
}

.cover .meta {
  margin-top: 80px;
  font-size: 10.5pt;
  color: #64748b;
  line-height: 1.6;
}

.cover .meta strong {
  color: #1e293b;
}

.header-banner {
  display: flex;
  justify-content: space-between;
  align-items: center;
  border-bottom: 2px solid #0f172a;
  padding-bottom: 8px;
  margin-bottom: 20px;
  font-size: 8pt;
  color: #64748b;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.footer-page-number {
  text-align: right;
  font-size: 8pt;
  color: #94a3b8;
  margin-top: 15px;
}
'

# ------------------------------------------------------------------------------
# 4. Prepare HTML Content
# ------------------------------------------------------------------------------
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

RENDER_HTML="${TEMP_DIR}/render.html"

convert_markdown_to_html_body() {
    local md_file="$1"
    if command -v bunx >/dev/null 2>&1; then
        bunx marked < "${md_file}"
    elif command -v npx >/dev/null 2>&1; then
        npx --yes marked < "${md_file}"
    else
        # Fallback python converter
        python3 - "${md_file}" << 'PYEOF'
import sys, re, html

def simple_md_to_html(text):
    lines = text.split('\n')
    output = []
    in_code = False
    code_block = []
    in_table = False
    table_rows = []

    def flush_table():
        nonlocal in_table, table_rows
        if not table_rows:
            return ""
        res = ["<table>"]
        is_first = True
        for row in table_rows:
            cols = [c.strip() for c in row.strip('|').split('|')]
            if any(set(c).issubset({'-', ':', ' '}) for c in cols if c):
                continue
            tag = "th" if is_first else "td"
            res.append("<tr>" + "".join(f"<{tag}>{c}</{tag}>" for c in cols) + "</tr>")
            is_first = False
        res.append("</table>")
        table_rows = []
        in_table = False
        return "\n".join(res)

    for line in lines:
        if line.startswith('```'):
            if in_code:
                output.append("<pre><code>" + html.escape("\n".join(code_block)) + "</code></pre>")
                code_block = []
                in_code = False
            else:
                if in_table:
                    output.append(flush_table())
                in_code = True
            continue
        if in_code:
            code_block.append(line)
            continue
        if '|' in line and (line.strip().startswith('|') or line.strip().endswith('|')):
            in_table = True
            table_rows.append(line)
            continue
        else:
            if in_table:
                output.append(flush_table())

        if line.startswith('# '):
            output.append(f"<h1>{html.escape(line[2:].strip())}</h1>")
        elif line.startswith('## '):
            output.append(f"<h2>{html.escape(line[3:].strip())}</h2>")
        elif line.startswith('### '):
            output.append(f"<h3>{html.escape(line[4:].strip())}</h3>")
        elif line.startswith('#### '):
            output.append(f"<h4>{html.escape(line[5:].strip())}</h4>")
        elif line.strip().startswith('- '):
            output.append(f"<li>{html.escape(line.strip()[2:])}</li>")
        elif line.strip():
            output.append(f"<p>{html.escape(line)}</p>")

    if in_table:
        output.append(flush_table())
    return "\n".join(output)

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    print(simple_md_to_html(f.read()))
PYEOF
    fi
}

if [[ "${INPUT_PATH}" == *.md || "${INPUT_PATH}" == *.markdown ]]; then
    echo "[+] Converting Markdown to HTML..."
    HTML_BODY="$(convert_markdown_to_html_body "${INPUT_PATH}")"

    cat << EOF > "${RENDER_HTML}"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <title>Tech Challenge Fase 3 — CatCar Platform</title>
  <style>
${CSS_PRINT_STYLES}
  </style>
</head>
<body>
${HTML_BODY}
</body>
</html>
EOF
else
    # It's an HTML file
    # If the HTML doesn't contain a print style, inject our print stylesheet
    if grep -q "@page" "${INPUT_PATH}"; then
        cp "${INPUT_PATH}" "${RENDER_HTML}"
    else
        echo "[+] Injecting print CSS styles into HTML..."
        python3 - "${INPUT_PATH}" "${RENDER_HTML}" << 'PYEOF'
import sys, re

in_path = sys.argv[1]
out_path = sys.argv[2]

with open(in_path, 'r', encoding='utf-8') as f:
    content = f.read()

style_tag = f"<style>\n{sys.stdin.read()}\n</style>\n"

if "</head>" in content:
    content = content.replace("</head>", f"{style_tag}</head>", 1)
else:
    content = f"<!DOCTYPE html><html><head>{style_tag}</head><body>{content}</body></html>"

with open(out_path, 'w', encoding='utf-8') as f:
    f.write(content)
PYEOF
    fi
fi

# ------------------------------------------------------------------------------
# 5. Render to PDF via Headless Chromium
# ------------------------------------------------------------------------------
echo "[+] Rendering PDF via Headless Chromium..."

"${CHROMIUM_BIN}" \
    --headless \
    --disable-gpu \
    --no-sandbox \
    --no-pdf-header-footer \
    --print-to-pdf="${OUTPUT_PDF}" \
    "file://${RENDER_HTML}" 2>&1

# ------------------------------------------------------------------------------
# 6. Verification and Summary
# ------------------------------------------------------------------------------
if [[ -s "${OUTPUT_PDF}" ]]; then
    FILE_SIZE="$(du -h "${OUTPUT_PDF}" | cut -f1)"
    echo "================================================================="
    echo "[✔] PDF generation successful!"
    echo "    Output file : ${OUTPUT_PDF}"
    echo "    File size   : ${FILE_SIZE}"
    if command -v pdfinfo >/dev/null 2>&1; then
        PAGES="$(pdfinfo "${OUTPUT_PDF}" 2>/dev/null | grep "Pages:" | awk '{print $2}')"
        echo "    Page count  : ${PAGES} page(s)"
    fi
    echo "================================================================="
else
    echo "[-] Error: Output PDF was not created or is empty." >&2
    exit 1
fi
