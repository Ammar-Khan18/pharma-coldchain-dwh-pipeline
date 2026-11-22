-- q1_channel_margin (AGG): reads the pre-aggregated agg_channel_month.
SELECT "Year", "Month", "SalesChannel", "NetSales", "COGS", "GrossMargin", "GrossMarginPct"
FROM sdi.agg_channel_month
ORDER BY "Year", "Month", "SalesChannel";
