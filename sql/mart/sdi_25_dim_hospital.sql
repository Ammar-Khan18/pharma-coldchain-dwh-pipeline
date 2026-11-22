-- =====================================================================
-- sdi_25_dim_hospital.sql  —  Phase 1 transform STEP 2e: DimHospital (DuckDB)
-- SCD Type 1, DISTINCT HospitalID from 06. HospitalGLN padded to 13.
-- HospitalName / HospitalType unchanged. LocationKey = lookup of (City, State).
-- Surrogate keys preserved on update.
-- =====================================================================
INSERT INTO sdi."DimHospital"
    ("HospitalID", "HospitalGLN", "HospitalName", "HospitalType", "LocationKey")
WITH src AS (
    SELECT "HospitalID" AS hid,
           any_value("HospitalGLN")  AS gln,
           any_value("HospitalName")  AS hname,
           any_value("HospitalType")  AS htype,
           any_value(trim("City"))  AS city,
           any_value(trim("State")) AS state
    FROM pg.ods.hospital_demand
    WHERE "HospitalID" IS NOT NULL AND "HospitalID" <> ''
    GROUP BY "HospitalID"
)
SELECT src.hid, lpad(src.gln, 13, '0'), src.hname, src.htype,
       coalesce(loc."LocationKey", -1)
FROM src
LEFT JOIN sdi."DimLocation" loc ON loc."City" = src.city AND loc."State" = src.state
ON CONFLICT ("HospitalID") DO UPDATE SET
    "HospitalGLN"  = excluded."HospitalGLN",
    "HospitalName" = excluded."HospitalName",
    "HospitalType" = excluded."HospitalType",
    "LocationKey"  = excluded."LocationKey";
