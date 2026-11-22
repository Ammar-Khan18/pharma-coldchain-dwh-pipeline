-- =====================================================================
-- sdi_23_dim_location.sql  —  Phase 1 transform STEP 2c: DimLocation (DuckDB)
-- Union of distinct City+State from 05 (PharmacyCity/PharmacyState) and 06
-- (City/State). TRIM both; CountryCode -> Country. Natural key = City+State.
-- City values in the source are already proper case; TRIM only. Member -1 seeded.
-- =====================================================================
INSERT INTO sdi."DimLocation" ("City", "State", "Country")
SELECT DISTINCT city, state, any_value(country) OVER (PARTITION BY city, state) AS country
FROM (
    SELECT trim("PharmacyCity") AS city, trim("PharmacyState") AS state, "CountryCode" AS country
    FROM pg.ods.pharmacy_sales
    WHERE "PharmacyCity" IS NOT NULL AND trim("PharmacyCity") <> ''
    UNION
    SELECT trim("City"), trim("State"), "CountryCode"
    FROM pg.ods.hospital_demand
    WHERE "City" IS NOT NULL AND trim("City") <> ''
)
ON CONFLICT ("City", "State") DO NOTHING;
