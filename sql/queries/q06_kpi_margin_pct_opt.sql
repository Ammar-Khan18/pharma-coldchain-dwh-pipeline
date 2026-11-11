-- q06 (OPTIMIZED): KPI card — gross margin % for the latest month, from aggregate.
WITH lm AS (SELECT max(year_month) AS ym FROM sdi.agg_sales_month_channel)
SELECT (SELECT ym FROM lm) AS year_month,
       round(100.0 * sum(gross_margin_usd) / nullif(sum(net_sales_usd), 0), 2) AS margin_pct
FROM sdi.agg_sales_month_channel
WHERE year_month = (SELECT ym FROM lm);
