-- =====================================================================
-- sdi_24_dim_pharmacy.sql  —  Phase 1 transform STEP 2d: DimPharmacy (DuckDB)
-- SCD Type 1. Grain = one row per (PharmacyID, SalesChannel) — 48 pharmacies sell
-- through both channels, so SalesChannel is part of the natural key (decision R1).
--   PharmacyGLN  = lpad(...,13,'0')
--   PharmacyName = seed_pharmacy_short_names, else fallback:
--                  initials of every word but the last + '.' + the last word
--   PharmacyType = seed_pharmacy_type_abbrev, else fallback:
--                  first 4 letters of each word joined by '.'
--   SalesChannel = unchanged;  LocationKey = lookup of (City, State)
-- Surrogate keys are preserved on update (ON CONFLICT DO UPDATE keeps PharmacyKey).
-- =====================================================================
INSERT INTO sdi."DimPharmacy"
    ("PharmacyID", "PharmacyGLN", "PharmacyName", "PharmacyType", "SalesChannel", "LocationKey")
WITH src AS (
    SELECT "PharmacyID" AS pid, "SalesChannel" AS chan,
           any_value("PharmacyGLN")  AS gln,
           any_value("PharmacyName")  AS pname,
           any_value("PharmacyType")  AS ptype,
           any_value(trim("PharmacyCity"))  AS city,
           any_value(trim("PharmacyState")) AS state
    FROM pg.ods.pharmacy_sales
    WHERE "PharmacyID" IS NOT NULL AND "PharmacyID" <> ''
    GROUP BY "PharmacyID", "SalesChannel"
)
SELECT
    src.pid,
    lpad(src.gln, 13, '0'),
    coalesce(sn.pharmacy_name,
             array_to_string(list_transform(w.pw[1:len(w.pw) - 1], lambda x: upper(left(x, 1))), '')
             || '.' || w.pw[len(w.pw)]),
    coalesce(pt.abbrev,
             array_to_string(list_transform(w.tw, lambda x: left(x, 4)), '.')),
    src.chan,
    coalesce(loc."LocationKey", -1)
FROM src
LEFT JOIN sdi.seed_pharmacy_short_names sn ON sn.pharmacy_id = src.pid
LEFT JOIN sdi.seed_pharmacy_type_abbrev pt ON pt.pharmacy_type = src.ptype
LEFT JOIN sdi."DimLocation" loc ON loc."City" = src.city AND loc."State" = src.state,
LATERAL (SELECT string_split(trim(src.pname), ' ') AS pw,
                string_split(trim(src.ptype), ' ') AS tw) AS w
ON CONFLICT ("PharmacyID", "SalesChannel") DO UPDATE SET
    "PharmacyGLN"  = excluded."PharmacyGLN",
    "PharmacyName" = excluded."PharmacyName",
    "PharmacyType" = excluded."PharmacyType",
    "LocationKey"  = excluded."LocationKey";
