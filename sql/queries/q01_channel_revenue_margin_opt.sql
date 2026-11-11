-- q01 (OPTIMIZED): reads the pre-aggregated agg_sales_month_channel.
SELECT year_month, channel_name,
       round(net_sales_usd, 2)    AS revenue_usd,
       round(cogs_usd, 2)         AS cost_usd,
       round(gross_margin_usd, 2) AS gross_margin_usd,
       margin_pct
FROM sdi.agg_sales_month_channel
ORDER BY year_month, channel_name;
