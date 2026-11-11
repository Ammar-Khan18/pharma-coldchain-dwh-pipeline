-- q04 (RAW): KPI card — total net revenue for the latest month. Scans fact_sales.
WITH lm AS (
    SELECT max(dd.year_month) AS ym
    FROM sdi.fact_sales f JOIN sdi.dim_date dd ON dd.date_key = f.sale_date_key
)
SELECT (SELECT ym FROM lm) AS year_month,
       round(sum(f.net_sales_usd), 2) AS total_revenue_usd
FROM sdi.fact_sales f
JOIN sdi.dim_date dd ON dd.date_key = f.sale_date_key
WHERE dd.year_month = (SELECT ym FROM lm);
