"""
build_generator_report.py  —  (re)generate docs/generator_report.pdf.

A 1-2 page PDF summary of the data oversampling / generator layer (WBS 2.1) for
the project report: the method, why the chosen volume, a statistics table read
LIVE from meta.generation_log, and a bar chart of rows generated per file per
refresh. Re-run after each refresh to refresh the numbers and the chart.

Run (Ubuntu/WSL, venv active):   python ~/pipeline/docs/build_generator_report.py
Env (optional): IDA_PG_DSN.
Deps: fpdf2 (pip install fpdf2).
"""
import os
from pathlib import Path
import psycopg2
from fpdf import FPDF

REPO = Path(__file__).resolve().parents[1]
OUT = REPO / "docs" / "generator_report.pdf"
DSN = os.environ.get("IDA_PG_DSN",
                     "host=localhost port=5432 dbname=ida_staging user=ida_user password=ida_pass")

NAVY = (31, 78, 120); BLUE = (68, 114, 196); ORANGE = (237, 125, 49); GREEN = (112, 173, 71)
GREY = (120, 120, 120); LIGHT = (217, 225, 242)
FILE_COLOR = {"01": BLUE, "05": ORANGE, "06": GREEN}
FILE_LABEL = {"01": "01 master", "05": "05 sales", "06": "06 demand"}


def load_rows():
    with psycopg2.connect(DSN) as conn, conn.cursor() as cur:
        cur.execute("SELECT period, source_file, rows_generated, bad_rows, min_date, max_date "
                    "FROM meta.generation_log ORDER BY period, source_file")
        return cur.fetchall()


class PDF(FPDF):
    def header(self):
        self.set_fill_color(*NAVY); self.rect(0, 0, 210, 18, "F")
        self.set_xy(12, 4); self.set_font("Helvetica", "B", 15); self.set_text_color(255, 255, 255)
        self.cell(0, 10, "Data Oversampling / Generator - Phase 1 (WBS 2.1)")
        self.set_text_color(0, 0, 0)

    def footer(self):
        self.set_y(-12); self.set_font("Helvetica", "I", 8); self.set_text_color(*GREY)
        self.cell(0, 8, "Pharma Cold-Chain DWH - generator report (generated from meta.generation_log)",
                  align="C"); self.set_text_color(0, 0, 0)


def heading(pdf, text):
    pdf.ln(2); pdf.set_font("Helvetica", "B", 12); pdf.set_text_color(*NAVY)
    pdf.cell(0, 7, text, new_x="LMARGIN", new_y="NEXT"); pdf.set_text_color(0, 0, 0)


def body(pdf, text):
    pdf.set_font("Helvetica", "", 10); pdf.set_x(pdf.l_margin)
    pdf.multi_cell(pdf.epw, 5, text, new_x="LMARGIN", new_y="NEXT"); pdf.ln(1)


def bullet(pdf, text):
    pdf.set_font("Helvetica", "", 10); pdf.set_x(pdf.l_margin + 4)
    pdf.multi_cell(pdf.epw - 4, 5, "- " + text, new_x="LMARGIN", new_y="NEXT")


def stats_table(pdf, rows):
    heading(pdf, "Statistics - from meta.generation_log")
    headers = ["Period", "Generated file", "Rows", "Bad rows", "Date span"]
    w = [22, 78, 20, 22, 40]
    pdf.set_font("Helvetica", "B", 9); pdf.set_fill_color(*NAVY); pdf.set_text_color(255, 255, 255)
    for h, cw in zip(headers, w):
        pdf.cell(cw, 7, h, border=1, fill=True, align="C")
    pdf.ln(); pdf.set_text_color(0, 0, 0); pdf.set_font("Helvetica", "", 9)
    for i, (period, sf, rg, bad, mn, mx) in enumerate(rows):
        span = (f"{mn} -> {mx}" if mn else "-")
        fill = i % 2 == 1
        pdf.set_fill_color(*LIGHT)
        for val, cw, al in zip([period, sf, f"{rg:,}", str(bad), span], w,
                               ["C", "L", "R", "C", "C"]):
            pdf.cell(cw, 6, str(val), border=1, align=al, fill=fill)
        pdf.ln()
    pdf.ln(2)


def bar_chart(pdf, rows):
    heading(pdf, "Rows generated per file per refresh")
    # group: period -> {file-prefix: rows}
    periods = []
    data = {}
    for period, sf, rg, bad, mn, mx in rows:
        pref = sf[:2]
        if period not in data:
            data[period] = {}; periods.append(period)
        data[period][pref] = data[period].get(pref, 0) + rg
    maxv = max((v for p in data.values() for v in p.values()), default=1)

    x0 = pdf.get_x() + 8; y0 = pdf.get_y() + 58; H = 50     # baseline y0, bars grow upward
    files = ["01", "05", "06"]
    cluster_w = 48; bar_w = 12; gap = 6
    pdf.set_draw_color(180, 180, 180)
    pdf.line(x0 - 3, y0, x0 + len(periods) * (cluster_w + gap), y0)  # x axis
    for pi, period in enumerate(periods):
        cx = x0 + pi * (cluster_w + gap)
        for fi, pref in enumerate(files):
            val = data[period].get(pref, 0)
            h = (val / maxv) * H if maxv else 0
            bx = cx + fi * (bar_w + 2)
            pdf.set_fill_color(*FILE_COLOR[pref])
            pdf.rect(bx, y0 - h, bar_w, h, "F")
            pdf.set_font("Helvetica", "", 7); pdf.set_text_color(60, 60, 60)
            pdf.set_xy(bx - 1, y0 - h - 4); pdf.cell(bar_w + 2, 3, f"{val:,}", align="C")
        pdf.set_font("Helvetica", "B", 8); pdf.set_text_color(0, 0, 0)
        pdf.set_xy(cx, y0 + 2); pdf.cell(cluster_w, 4, period, align="L")
    # legend
    lx = x0; ly = y0 + 10
    pdf.set_font("Helvetica", "", 8)
    for pref in files:
        pdf.set_fill_color(*FILE_COLOR[pref]); pdf.rect(lx, ly, 4, 4, "F")
        pdf.set_xy(lx + 5, ly - 1); pdf.cell(26, 5, FILE_LABEL[pref]); lx += 34
    pdf.set_y(ly + 8); pdf.set_text_color(0, 0, 0)


def main():
    rows = load_rows()
    pdf = PDF(format="A4"); pdf.set_auto_page_break(True, margin=15)
    pdf.add_page(); pdf.set_y(24)

    body(pdf, "The generator simulates a new business month on each refresh so the warehouse and "
              "dashboards visibly update, while every row stays realistic and passes validation. "
              "New data is appended; history is never replaced.")

    heading(pdf, "Method - bootstrap resampling")
    bullet(pdf, "Resample real history from the SAME month-of-year, so seasonality and the per-medicine, "
                "channel, pharmacy and hospital mix match the real distributions.")
    bullet(pdf, "Keep every attribute and amount verbatim from the sampled real row, so referential "
                "integrity holds (only existing IDs appear) and the money/stock/returns rules pass.")
    bullet(pdf, "ID continuation: new SalesTransactionID / HospitalDemandRecordID continue the existing "
                "number sequence read from the ODS, so IDs never collide across refreshes.")
    bullet(pdf, "Format preservation: every column, text format, GTIN14 leading zero and date format "
                "matches the source, so ingestion and validation treat the file like real data.")
    bullet(pdf, "Optional levers: --price-change N (new SCD2 versions in dim_medicine) and "
                "--bad-rows N (deliberately invalid rows that validation rejects).")

    heading(pdf, "Why this volume - one realistic month per refresh")
    body(pdf, "The source holds 36 months (2023-01 to 2025-12). A refresh simulates ONE new month, "
              "sized from history so it looks like a real month, not a spike:")
    bullet(pdf, "Sales approx the average monthly count = 500,000 / 36 approx 13,900 rows.")
    bullet(pdf, "Hospital demand = the full grain = 12 hospitals x 63 medicines = 756 rows.")
    body(pdf, "The demo uses two refreshes (Refresh 1 = 2026-01, Refresh 2 = 2026-02) so the dashboards "
              "step forward twice while every number still reconciles.")

    stats_table(pdf, rows)
    bar_chart(pdf, rows)

    pdf.output(str(OUT))
    print("saved:", OUT, "| refreshes:", sorted({r[0] for r in rows}))


if __name__ == "__main__":
    main()
