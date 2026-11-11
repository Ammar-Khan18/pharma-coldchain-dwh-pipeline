-- q04 (OPTIMIZED): KPI card — total net revenue for the latest month, from aggregate.
WITH lm AS (SELECT max(year_month) AS ym FROM sdi.agg_sales_month_channel)
SELECT (SELECT ym FROM lm) AS year_month,
       round(sum(net_sales_usd), 2) AS total_revenue_usd
FROM sdi.agg_sales_month_channel
WHERE year_month = (SELECT ym FROM lm);
