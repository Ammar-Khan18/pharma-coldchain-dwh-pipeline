-- =====================================================================
-- sdi_21_dim_date.sql  —  Phase 1 transform STEP 2a: DimDate (DuckDB)
-- Fills DimDate from 2023-01-01 to 31 Dec of the year of the latest
-- SalesDate / DemandMonth found in the ODS. Only missing days are inserted
-- (ON CONFLICT DO NOTHING), so a 2026 refresh always finds its dates.
-- The -1 Unknown row is seeded by sdi_01_create_schema.sql.
-- =====================================================================
INSERT INTO sdi."DimDate"
WITH mx AS (
    SELECT max(x) AS maxd FROM (
        SELECT max(TRY_CAST("SalesDate" AS DATE)) AS x FROM pg.ods.pharmacy_sales
        UNION ALL
        SELECT max(last_day(TRY_CAST("DemandMonth" AS DATE))) FROM pg.ods.hospital_demand
    )
),
rng AS (
    SELECT DATE '2023-01-01' AS start_d,
           make_date(year(coalesce(maxd, current_date)), 12, 31) AS end_d
    FROM mx
)
SELECT CAST(strftime(g.d, '%Y%m%d') AS INTEGER),
       g.d::DATE,
       day(g.d),
       left(dayname(g.d), 3),
       month(g.d),
       left(monthname(g.d), 3),
       'Q' || quarter(g.d),
       year(g.d)
FROM rng, generate_series(rng.start_d, rng.end_d, INTERVAL 1 DAY) AS g(d)
ON CONFLICT DO NOTHING;
