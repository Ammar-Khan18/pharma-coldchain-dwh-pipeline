-- q06 (RAW): KPI card — gross margin % for the latest month. Scans fact_sales.
WITH lm AS (
    SELECT max(dd.year_month) AS ym
    FROM sdi.fact_sales f JOIN sdi.dim_date dd ON dd.date_key = f.sale_date_key
)
SELECT (SELECT ym FROM lm) AS year_month,
       round(100.0 * sum(f.gross_margin_usd) / nullif(sum(f.net_sales_usd), 0), 2) AS margin_pct
FROM sdi.fact_sales f
JOIN sdi.dim_date dd ON dd.date_key = f.sale_date_key
WHERE dd.year_month = (SELECT ym FROM lm);
