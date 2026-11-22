-- q1_channel_margin (BASE): scans FactPharmacySales. Net sales, COGS, gross margin
-- and margin% per Year, Month, SalesChannel. Margin% is SUM/SUM (never averaged).
SELECT d."Year", d."Month", p."SalesChannel",
       sum(f."NetSales")    AS net_sales,
       sum(f."COGS")        AS cogs,
       sum(f."GrossMargin") AS gross_margin,
       sum(f."GrossMargin") / nullif(sum(f."NetSales"), 0) AS gross_margin_pct
FROM sdi."FactPharmacySales" f
JOIN sdi."DimDate"     d ON d."DateKey"     = f."DateKey"
JOIN sdi."DimPharmacy" p ON p."PharmacyKey" = f."PharmacyKey"
GROUP BY d."Year", d."Month", p."SalesChannel"
ORDER BY d."Year", d."Month", p."SalesChannel";
