-- q3_top_bottom_by_state (AGG): reads agg_top_bottom_medicine_state.
SELECT "State", "MedName", "TherapeuticClass", "QuantitySold", "Rank", "TopOrBottom"
FROM sdi.agg_top_bottom_medicine_state
ORDER BY "State", "TopOrBottom", "Rank";
