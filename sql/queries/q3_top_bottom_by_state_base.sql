-- q3_top_bottom_by_state (BASE): scans FactPharmacySales. Per State (via
-- DimPharmacy -> DimLocation), the top 10 and bottom 10 MedName by units sold,
-- with TherapeuticClass, Rank and a TopOrBottom column (window functions).
WITH base AS (
    SELECT loc."State" AS state, m."MedName" AS medname,
           any_value(m."TherapeuticClass") AS tclass,
           sum(f."QuantitySold") AS qty
    FROM sdi."FactPharmacySales" f
    JOIN sdi."DimPharmacy" p   ON p."PharmacyKey" = f."PharmacyKey"
    JOIN sdi."DimLocation" loc ON loc."LocationKey" = p."LocationKey"
    JOIN sdi."DimMedicine" m   ON m."MedicineKey" = f."MedicineKey"
    WHERE f."PharmacyKey" <> -1 AND f."MedicineKey" <> -1 AND p."LocationKey" <> -1
    GROUP BY loc."State", m."MedName"
),
ranked AS (
    SELECT state, medname, tclass, qty,
           row_number() OVER (PARTITION BY state ORDER BY qty DESC, medname) AS rank_desc,
           row_number() OVER (PARTITION BY state ORDER BY qty ASC,  medname) AS rank_asc
    FROM base
)
SELECT state AS "State", medname AS "MedName", tclass AS "TherapeuticClass",
       qty AS "QuantitySold", rank_desc AS "Rank", 'Top' AS "TopOrBottom"
FROM ranked WHERE rank_desc <= 10
UNION ALL
SELECT state, medname, tclass, qty, rank_asc, 'Bottom'
FROM ranked WHERE rank_asc <= 10
ORDER BY "State", "TopOrBottom", "Rank";
