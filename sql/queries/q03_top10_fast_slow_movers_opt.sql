-- q03 (OPTIMIZED): reads agg_sales_medicine_month, summed to medicine totals.
WITH med AS (
    SELECT medicine_id,
           any_value(generic_name)      AS generic_name,
           any_value(therapeutic_class) AS therapeutic_class,
           sum(units_sold)              AS units_sold
    FROM sdi.agg_sales_medicine_month
    GROUP BY medicine_id
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
