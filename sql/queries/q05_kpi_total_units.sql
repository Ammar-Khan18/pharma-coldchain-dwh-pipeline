-- q05 (RAW): KPI card — total units sold for the latest month. Scans fact_sales.
WITH lm AS (
    SELECT max(dd.year_month) AS ym
    FROM sdi.fact_sales f JOIN sdi.dim_date dd ON dd.date_key = f.sale_date_key
)
SELECT (SELECT ym FROM lm) AS year_month,
       sum(f.quantity_sold_packs) AS total_units_sold
FROM sdi.fact_sales f
JOIN sdi.dim_date dd ON dd.date_key = f.sale_date_key
WHERE dd.year_month = (SELECT ym FROM lm);
