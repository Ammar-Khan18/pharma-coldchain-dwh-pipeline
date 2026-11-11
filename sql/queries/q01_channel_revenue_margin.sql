-- q01 (RAW): revenue, cost, gross margin and margin % by channel by month.
-- Widget: "Channel revenue & margin by month". Scans fact_sales.
SELECT dd.year_month,
       ch.channel_name,
       round(sum(f.net_sales_usd), 2)    AS revenue_usd,
       round(sum(f.cogs_usd), 2)         AS cost_usd,
       round(sum(f.gross_margin_usd), 2) AS gross_margin_usd,
       round(100.0 * sum(f.gross_margin_usd) / nullif(sum(f.net_sales_usd), 0), 2) AS margin_pct
FROM sdi.fact_sales f
JOIN sdi.dim_date    dd ON dd.date_key    = f.sale_date_key
JOIN sdi.dim_channel ch ON ch.channel_key = f.channel_key
GROUP BY dd.year_month, ch.channel_name
ORDER BY dd.year_month, ch.channel_name;
