-- q05 (OPTIMIZED): KPI card — total units sold for the latest month, from aggregate.
WITH lm AS (SELECT max(year_month) AS ym FROM sdi.agg_sales_month_channel)
SELECT (SELECT ym FROM lm) AS year_month,
       sum(units_sold) AS total_units_sold
FROM sdi.agg_sales_month_channel
WHERE year_month = (SELECT ym FROM lm);
