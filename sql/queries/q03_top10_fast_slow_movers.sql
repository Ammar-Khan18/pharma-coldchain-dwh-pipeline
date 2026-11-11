-- q03 (RAW): top 10 fast-moving and top 10 slow-moving medicines by units sold,
-- each labelled with its therapeutic class. Widget: "Top/bottom 10 movers".
WITH med AS (
    SELECT m.medicine_id, m.generic_name, m.therapeutic_class,
           sum(f.quantity_sold_packs) AS units_sold
    FROM sdi.fact_sales f
    JOIN sdi.dim_medicine m ON m.medicine_key = f.medicine_key
    GROUP BY m.medicine_id, m.generic_name, m.therapeutic_class
),
ranked AS (
    SELECT *,
           row_number() OVER (ORDER BY units_sold DESC) AS rnk_fast,
           row_number() OVER (ORDER BY units_sold ASC)  AS rnk_slow
    FROM med
)
SELECT 'Fast mover' AS mover_type, generic_name, therapeutic_class, units_sold
FROM ranked WHERE rnk_fast <= 10
UNION ALL
SELECT 'Slow mover', generic_name, therapeutic_class, units_sold
FROM ranked WHERE rnk_slow <= 10
ORDER BY mover_type, units_sold DESC;
