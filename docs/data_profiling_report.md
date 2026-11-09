# Source data profiling report (WBS 1.4)

Generated: 2026-11-10 00:59 from `/home/lenovo/pipeline/data`


## Overview

| File | Rows | Columns | Size (MB) | Duplicate rows | Read time (s) |
|---|---|---|---|---|---|
| 01_master_data.csv | 63 | 34 | 0.0 | 0 | 0.1 |
| 02_manufacturing_data.csv | 561 | 39 | 0.2 | 0 | 0.0 |
| 03_manufacturer_delivery_data.csv | 999 | 42 | 0.4 | 0 | 0.0 |
| 04_warehouse_data.csv | 112,184 | 41 | 32.0 | 0 | 1.0 |
| 05_pharmacy_sales_data.csv | 500,000 | 45 | 208.5 | 0 | 6.6 |
| 06_hospital_demand_data.csv | 27,216 | 41 | 8.3 | 0 | 0.3 |
| 07_iot_streaming_data.csv | 293,425 | 30 | 71.7 | 0 | 2.1 |

## 01_master_data.csv

- Rows: **63**  |  Columns: **34**  |  File size: 0.0 MB  |  Read time: 0.1 s
- Fully duplicated rows: 0
- Primary key: `MedicineID` -> UNIQUE - OK (duplicate keys: 0, rows with empty key: 0)

| Column | Type | Empty | Empty % | Distinct | Min | Max | Examples | Notes |
|---|---|---|---|---|---|---|---|---|
| MedicineID | str | 0 | 0.0 | 63 |  |  | MED001, MED002, MED003 |  |
| InternalSKU | str | 0 | 0.0 | 63 |  |  | SKU-01-0001, SKU-01-0002, SKU-01-0003 |  |
| GTIN14 | int64 | 0 | 0.0 | 63 | 9506000000015 | 9506000000633 | 9506000000015, 9506000000022, 9506000000039 |  |
| GenericName | str | 0 | 0.0 | 63 |  |  | Metformin, Gliclazide MR, Sitagliptin |  |
| FictionalBrandName | str | 0 | 0.0 | 63 |  |  | ClariMetform01, ClariGliclaz02, ClariSitagli03 |  |
| DiseaseCategory | str | 0 | 0.0 | 7 |  |  | Diabetes Mellitus, Cardiovascular Disease, Respiratory Disease |  |
| ICD10Category | str | 0 | 0.0 | 7 |  |  | E11, I10-I99, J40-J47 |  |
| ATCCode | str | 0 | 0.0 | 63 |  |  | A10BA02, A10BB09, A10BH01 |  |
| TherapeuticClass | str | 0 | 0.0 | 49 |  |  | Biguanide, Sulfonylurea, DPP-4 inhibitor |  |
| DosageForm | str | 0 | 0.0 | 13 |  |  | Tablet, Modified-release tablet, Solution for injection |  |
| Strength | str | 0 | 0.0 | 30 |  |  | 500 mg, 60 mg, 100 mg |  |
| RouteOfAdministration | str | 0 | 0.0 | 3 |  |  | Oral, Subcutaneous, Inhalation |  |
| PackSize | int64 | 0 | 0.0 | 13 | 1 | 100 | 30, 28, 5 |  |
| BaseUnitOfMeasure | str | 0 | 0.0 | 2 |  |  | pack, device |  |
| PrescriptionClass | str | 0 | 0.0 | 2 |  |  | Prescription, OTC |  |
| ControlledMedicineFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| ColdChainFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| StorageMinTempC | int64 | 0 | 0.0 | 2 | 2 | 15 | 15, 2 |  |
| StorageMaxTempC | int64 | 0 | 0.0 | 2 | 8 | 25 | 25, 8 |  |
| MaxHumidityPct | int64 | 0 | 0.0 | 2 | 65 | 75 | 65, 75 |  |
| ShelfLifeMonths | int64 | 0 | 0.0 | 2 | 24 | 36 | 24, 36 |  |
| MinimumRemainingShelfLifeDays | int64 | 0 | 0.0 | 2 | 180 | 270 | 270, 180 |  |
| PrimarySupplierID | str | 0 | 0.0 | 12 |  |  | SUP001, SUP002, SUP003 |  |
| PrimaryPlantID | str | 0 | 0.0 | 4 |  |  | PLT02, PLT03, PLT04 |  |
| ManufacturingLeadTimeDays | int64 | 0 | 0.0 | 4 | 14 | 35 | 21, 28, 35 |  |
| StandardBatchSizePacks | int64 | 0 | 0.0 | 7 | 5000 | 30000 | 15000, 20000, 25000 |  |
| SafetyStockDays | int64 | 0 | 0.0 | 5 | 21 | 49 | 35, 42, 49 |  |
| ReorderReviewCycleDays | int64 | 0 | 0.0 | 1 | 7 | 7 | 7 | constant column |
| UnitManufacturingCostUSD | float64 | 0 | 0.0 | 39 | 0.35 | 44.0 | 0.55, 1.2, 4.8 |  |
| WholesalePriceUSD | float64 | 0 | 0.0 | 41 | 1.8 | 92.0 | 2.2, 4.8, 14.5 |  |
| RecommendedRetailPriceUSD | float64 | 0 | 0.0 | 41 | 2.38 | 121.44 | 2.9, 6.34, 19.14 |  |
| ProductStatus | str | 0 | 0.0 | 1 |  |  | Active | constant column |
| EffectiveFromDate | str (date-like) | 0 | 0.0 | 1 | 2023-01-01 00:00:00 | 2023-01-01 00:00:00 | 2023-01-01 | constant column |
| SourceSystem | str | 0 | 0.0 | 1 |  |  | ERP_PRODUCT_MASTER | constant column |

## 02_manufacturing_data.csv

- Rows: **561**  |  Columns: **39**  |  File size: 0.2 MB  |  Read time: 0.0 s
- Fully duplicated rows: 0
- Primary key: `ManufacturingOrderID` -> UNIQUE - OK (duplicate keys: 0, rows with empty key: 0)

| Column | Type | Empty | Empty % | Distinct | Min | Max | Examples | Notes |
|---|---|---|---|---|---|---|---|---|
| ManufacturingOrderID | str | 0 | 0.0 | 561 |  |  | MO-2023-00001, MO-2023-00002, MO-2023-00003 |  |
| ProductionBatchID | str | 0 | 0.0 | 561 |  |  | B23-PLT02-000001, B23-PLT02-000002, B23-PLT02-000003 |  |
| MedicineID | str | 0 | 0.0 | 63 |  |  | MED001, MED002, MED003 |  |
| GTIN14 | int64 | 0 | 0.0 | 63 | 9506000000015 | 9506000000633 | 9506000000015, 9506000000022, 9506000000039 |  |
| PlantID | str | 0 | 0.0 | 4 |  |  | PLT02, PLT03, PLT04 |  |
| OrderDate | str (date-like) | 0 | 0.0 | 374 | 2023-01-01 00:00:00 | 2025-12-20 00:00:00 | 2023-01-15, 2023-03-08, 2023-07-04 |  |
| DemandSignalSource | str | 0 | 0.0 | 6 |  |  | Safety stock replenishment, Hospital consumption plan, Confirmed pharmacy orders |  |
| PlanningRunType | str | 0 | 0.0 | 2 |  |  | Weekly MRP run, Exception planning |  |
| ManufacturingPriority | str | 0 | 0.0 | 3 |  |  | High, Normal, Urgent |  |
| PlannedStartDate | str (date-like) | 0 | 0.0 | 404 | 2023-01-07 00:00:00 | 2025-12-27 00:00:00 | 2023-01-20, 2023-03-11, 2023-07-08 |  |
| PlannedCompletionDate | str (date-like) | 0 | 0.0 | 425 | 2023-01-18 00:00:00 | 2026-01-11 00:00:00 | 2023-02-01, 2023-03-23, 2023-07-20 |  |
| ActualStartDate | str (date-like) | 0 | 0.0 | 409 | 2023-01-07 00:00:00 | 2025-12-27 00:00:00 | 2023-01-20, 2023-03-14, 2023-07-08 |  |
| ActualCompletionDate | str (date-like) | 0 | 0.0 | 422 | 2023-01-19 00:00:00 | 2026-01-14 00:00:00 | 2023-02-01, 2023-03-24, 2023-07-21 |  |
| PlannedQuantityPacks | int64 | 0 | 0.0 | 20 | 3800 | 36000 | 15000, 12000, 18000 |  |
| ActualQuantityPacks | int64 | 0 | 0.0 | 524 | 3778 | 36341 | 14819, 12099, 15087 |  |
| RejectedQuantityPacks | int64 | 0 | 0.0 | 385 | 22 | 1237 | 346, 37, 296 |  |
| ReleasedQuantityPacks | int64 | 0 | 0.0 | 542 | 0 | 36083 | 14473, 12062, 14791 | 5 zero |
| YieldPct | float64 | 0 | 0.0 | 266 | 0.0 | 99.7 | 97.67, 99.69, 98.04 |  |
| BatchStatus | str | 0 | 0.0 | 2 |  |  | Released, Rejected |  |
| QualityTestStatus | str | 0 | 0.0 | 3 |  |  | Passed, Failed, Conditional pass |  |
| QualitySampleDate | str (date-like) | 0 | 0.0 | 422 | 2023-01-20 00:00:00 | 2026-01-15 00:00:00 | 2023-02-02, 2023-03-25, 2023-07-22 |  |
| BatchReleaseDate | str (date-like) | 0 | 0.0 | 415 | 2023-01-21 00:00:00 | 2026-01-21 00:00:00 | 2023-02-04, 2023-03-26, 2023-07-24 |  |
| ExpiryDate | str (date-like) | 0 | 0.0 | 443 | 2025-01-10 00:00:00 | 2029-01-05 00:00:00 | 2025-01-24, 2025-03-15, 2025-07-13 |  |
| StandardBatchSizePacks | int64 | 0 | 0.0 | 7 | 5000 | 30000 | 15000, 20000, 25000 |  |
| ManufacturingLeadTimeDays | int64 | 0 | 0.0 | 4 | 14 | 35 | 21, 28, 35 |  |
| SetupHours | float64 | 0 | 0.0 | 41 | 2.0 | 6.0 | 4.2, 3.7, 4.0 |  |
| RunHours | float64 | 0 | 0.0 | 196 | 6.0 | 29.8 | 13.1, 10.5, 12.5 |  |
| DowntimeHours | float64 | 0 | 0.0 | 99 | 0.0 | 19.9 | 1.6, 8.8, 1.2 |  |
| DelayDays | int64 | 0 | 0.0 | 9 | 0 | 8 | 0, 1, 2 |  |
| DelayReason | str | 458 | 81.64 | 6 |  |  | Utility interruption, Raw material received late, Packaging line congestion |  |
| LaborCostUSD | float64 | 0 | 0.0 | 229 | 399.0 | 2041.2 | 793.8, 966.0, 743.4 |  |
| MaterialCostUSD | float64 | 0 | 0.0 | 555 | 1892.52 | 222284.52 | 5868.32, 4791.2, 5974.45 |  |
| OverheadCostUSD | float64 | 0 | 0.0 | 561 | 524.99 | 55736.13 | 1643.08, 2165.8, 1625.61 |  |
| TotalManufacturingCostUSD | float64 | 0 | 0.0 | 561 | 3072.05 | 279326.85 | 8305.2, 7923.0, 8343.46 |  |
| CostPerReleasedPackUSD | float64 | 5 | 0.89 | 547 | 0.3763 | 41.1472 | 0.5738, 0.6569, 0.5641 |  |
| DeviationFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| DeviationCategory | str | 442 | 78.79 | 5 |  |  | Packaging variance, Process parameter, Documentation |  |
| SourceSystem | str | 0 | 0.0 | 1 |  |  | MES_QMS_INTEGRATED | constant column |
| RecordCreatedTimestampUTC | str (date-like) | 0 | 0.0 | 415 | 2023-01-22 06:00:00+00:00 | 2026-01-22 06:00:00+00:00 | 2023-02-05T06:00:00Z, 2023-03-27T06:00:00Z, 2023-07-25T06:00:00Z |  |

## 03_manufacturer_delivery_data.csv

- Rows: **999**  |  Columns: **42**  |  File size: 0.4 MB  |  Read time: 0.0 s
- Fully duplicated rows: 0
- Primary key: **Key column(s) not found:** LineNo - check the real column names.

| Column | Type | Empty | Empty % | Distinct | Min | Max | Examples | Notes |
|---|---|---|---|---|---|---|---|---|
| ShipmentID | str | 0 | 0.0 | 897 |  |  | MFG-SHP-0000001, MFG-SHP-0000002, MFG-SHP-0000003 |  |
| ShipmentLineNumber | int64 | 0 | 0.0 | 3 | 1 | 3 | 1, 2, 3 |  |
| SSCC18 | int64 | 0 | 0.0 | 897 | 95060010008000016 | 95060010008008975 | 95060010008000016, 95060010008000023, 95060010008000030 |  |
| ManufacturingOrderID | str | 0 | 0.0 | 556 |  |  | MO-2023-00001, MO-2023-00002, MO-2023-00259 |  |
| ProductionBatchID | str | 0 | 0.0 | 556 |  |  | B23-PLT02-000001, B23-PLT02-000002, B23-PLT02-000259 |  |
| MedicineID | str | 0 | 0.0 | 63 |  |  | MED001, MED030, MED005 |  |
| GTIN14 | int64 | 0 | 0.0 | 63 | 9506000000015 | 9506000000633 | 9506000000015, 9506000000305, 9506000000053 |  |
| OriginPlantID | str | 0 | 0.0 | 4 |  |  | PLT02, PLT03, PLT04 |  |
| OriginPlantGLN | int64 | 0 | 0.0 | 4 | 950600100004 | 950600100035 | 950600100011, 950600100028, 950600100035 |  |
| OriginPlantName | str | 0 | 0.0 | 4 |  |  | Clarity Pharma Central Plant, Clarity Pharma South Plant, Clarity Pharma West Plant |  |
| DestinationWarehouseID | str | 0 | 0.0 | 6 |  |  | WH003, WH006, WH002 |  |
| DestinationWarehouseGLN | int64 | 0 | 0.0 | 6 | 950600200018 | 950600200063 | 950600200032, 950600200063, 950600200025 |  |
| DestinationWarehouseName | str | 0 | 0.0 | 6 |  |  | Southern Distribution Center, New England Cold Chain Hub, Midwest Distribution Center |  |
| DestinationCity | str | 0 | 0.0 | 6 |  |  | Dallas, Worcester, Joliet |  |
| DestinationState | str | 0 | 0.0 | 6 |  |  | TX, MA, IL |  |
| DestinationCountryCode | str | 0 | 0.0 | 1 |  |  | US | constant column |
| CarrierID | str | 0 | 0.0 | 5 |  |  | CAR02, CAR01, CAR04 |  |
| CarrierName | str | 0 | 0.0 | 5 |  |  | BlueLine Healthcare Freight, NorthStar Medical Logistics, SecureCold Transport |  |
| TransportMode | str | 0 | 0.0 | 3 |  |  | Road, Refrigerated road, Air |  |
| ColdChainRequiredFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| DispatchDate | str (date-like) | 0 | 0.0 | 544 | 2023-01-22 00:00:00 | 2026-01-26 00:00:00 | 2023-02-08, 2023-02-07, 2023-03-27 |  |
| PromisedDeliveryDate | str (date-like) | 0 | 0.0 | 543 | 2023-01-23 00:00:00 | 2026-01-27 00:00:00 | 2023-02-10, 2023-02-09, 2023-03-28 |  |
| ActualDeliveryDate | str (date-like) | 0 | 0.0 | 547 | 2023-01-23 00:00:00 | 2026-01-27 00:00:00 | 2023-02-14, 2023-02-09, 2023-03-28 |  |
| ShipmentStatus | str | 0 | 0.0 | 1 |  |  | Delivered | constant column |
| ShippedQuantityPacks | int64 | 0 | 0.0 | 922 | 3695 | 13569 | 7419, 7054, 6538 |  |
| ReceivedQuantityPacks | int64 | 0 | 0.0 | 918 | 3695 | 13569 | 7419, 7054, 6538 |  |
| DamagedQuantityPacks | int64 | 0 | 0.0 | 30 | 0 | 133 | 0, 39, 68 | 966 zero |
| ShortQuantityPacks | int64 | 0 | 0.0 | 23 | 0 | 76 | 0, 16, 14 | 973 zero |
| DistanceMiles | int64 | 0 | 0.0 | 22 | 95 | 2760 | 900, 850, 190 |  |
| TransitHours | int64 | 0 | 0.0 | 10 | 24 | 240 | 144, 48, 24 |  |
| OnTimeDeliveryFlag | str (date-like) | 0 | 0.0 | 2 |  |  | N, Y | 999 unparseable dates |
| InFullDeliveryFlag | str | 0 | 0.0 | 2 |  |  | Y, N |  |
| OTIFFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| FreightCostUSD | float64 | 0 | 0.0 | 994 | 463.6 | 10966.6 | 1463.47, 1503.85, 713.95 |  |
| FreightCostPerPackUSD | float64 | 0 | 0.0 | 910 | 0.0477 | 1.9434 | 0.1973, 0.2132, 0.1092 |  |
| SealNumber | str | 0 | 0.0 | 897 |  |  | SEAL-00800001, SEAL-00800002, SEAL-00800003 |  |
| TemperatureMonitoringRequiredFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| TemperatureExcursionFlag | str | 0 | 0.0 | 1 |  |  | N | constant column |
| ProofOfDeliveryFlag | str | 0 | 0.0 | 1 |  |  | Y | constant column |
| DeliveryExceptionReason | str | 890 | 89.09 | 6 |  |  | Traffic disruption, Handling damage, Carrier capacity delay |  |
| EPCISEventType | str | 0 | 0.0 | 1 |  |  | ShippingEvent / ReceivingEvent | constant column |
| SourceSystem | str | 0 | 0.0 | 1 |  |  | TMS_EPCIS_GATEWAY | constant column |

## 04_warehouse_data.csv

- Rows: **112,184**  |  Columns: **41**  |  File size: 32.0 MB  |  Read time: 1.0 s
- Fully duplicated rows: 0
- Primary key: `InventorySnapshotID` -> UNIQUE - OK (duplicate keys: 0, rows with empty key: 0)

| Column | Type | Empty | Empty % | Distinct | Min | Max | Examples | Notes |
|---|---|---|---|---|---|---|---|---|
| InventorySnapshotID | str | 0 | 0.0 | 112,184 |  |  | INV-000000001, INV-000000002, INV-000000003 |  |
| SnapshotDate | str (date-like) | 0 | 0.0 | 1,074 | 2023-01-23 00:00:00 | 2025-12-31 00:00:00 | 2023-02-14, 2023-02-15, 2023-02-16 |  |
| WarehouseLotID | str | 0 | 0.0 | 964 |  |  | WHLOT-0000001, WHLOT-0000002, WHLOT-0000003 |  |
| InboundShipmentID | str | 0 | 0.0 | 865 |  |  | MFG-SHP-0000001, MFG-SHP-0000002, MFG-SHP-0000003 |  |
| InboundShipmentLineNumber | int64 | 0 | 0.0 | 3 | 1 | 3 | 1, 2, 3 |  |
| ProductionBatchID | str | 0 | 0.0 | 538 |  |  | B23-PLT02-000001, B23-PLT02-000002, B23-PLT02-000259 |  |
| MedicineID | str | 0 | 0.0 | 63 |  |  | MED001, MED030, MED005 |  |
| GTIN14 | int64 | 0 | 0.0 | 63 | 9506000000015 | 9506000000633 | 9506000000015, 9506000000305, 9506000000053 |  |
| WarehouseID | str | 0 | 0.0 | 6 |  |  | WH003, WH006, WH002 |  |
| WarehouseGLN | int64 | 0 | 0.0 | 6 | 950600200018 | 950600200063 | 950600200032, 950600200063, 950600200025 |  |
| WarehouseName | str | 0 | 0.0 | 6 |  |  | Southern Distribution Center, New England Cold Chain Hub, Midwest Distribution Center |  |
| StorageZoneID | str | 0 | 0.0 | 84 |  |  | WH003-AMB-03, WH006-AMB-04, WH002-AMB-05 |  |
| StorageCondition | str | 0 | 0.0 | 2 |  |  | 15-25 C, 2-8 C |  |
| BatchExpiryDate | str (date-like) | 0 | 0.0 | 428 | 2025-01-10 00:00:00 | 2028-12-12 00:00:00 | 2025-01-24, 2025-03-15, 2025-02-22 |  |
| DaysToExpiry | int64 | 0 | 0.0 | 1,079 | 0 | 1078 | 710, 709, 708 |  |
| InventoryStatus | str | 0 | 0.0 | 5 |  |  | Quarantined, Available, Depleted |  |
| OpeningQuantityPacks | int64 | 0 | 0.0 | 12,366 | 0 | 13558 | 0, 7407, 7307 | 964 zero |
| ReceivedQuantityPacks | int64 | 0 | 0.0 | 888 | 0 | 13569 | 7419, 0, 7054 | 111,220 zero |
| PutawayQuantityPacks | int64 | 0 | 0.0 | 892 | 0 | 13558 | 7407, 0, 7033 | 111,220 zero |
| QuarantineQuantityPacks | int64 | 0 | 0.0 | 897 | 0 | 13558 | 7407, 0, 7033 | 110,239 zero |
| AvailableQuantityPacks | int64 | 0 | 0.0 | 11,186 | 0 | 12607 | 0, 6698, 6439 | 2,776 zero |
| ReservedQuantityPacks | int64 | 0 | 0.0 | 1,870 | 0 | 2065 | 0, 609, 667 | 2,816 zero |
| PickedQuantityPacks | int64 | 0 | 0.0 | 474 | 0 | 575 | 0, 97, 190 | 2,776 zero |
| ShippedQuantityPacks | int64 | 0 | 0.0 | 568 | 0 | 1599 | 0, 100, 201 | 1,961 zero |
| TransferInQuantityPacks | int64 | 0 | 0.0 | 90 | 0 | 99 | 0, 32, 8 | 111,837 zero |
| TransferOutQuantityPacks | int64 | 0 | 0.0 | 163 | 0 | 187 | 0, 72, 60 | 111,503 zero |
| DamagedQuantityPacks | int64 | 0 | 0.0 | 39 | 0 | 38 | 12, 0, 2 | 110,939 zero |
| ExpiredQuantityPacks | int64 | 0 | 0.0 | 17 | 0 | 1763 | 0, 311, 1646 | 112,168 zero |
| AdjustmentQuantityPacks | int64 | 0 | 0.0 | 5 | -2 | 2 | 0, 2, 1 | 218 negative; 111,721 zero |
| ClosingQuantityPacks | int64 | 0 | 0.0 | 12,367 | 0 | 13558 | 7407, 7307, 7106 | 831 zero |
| StockoutFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| NearExpiryFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| FEFOComplianceFlag | str | 0 | 0.0 | 2 |  |  | Y, N |  |
| CycleCountPerformedFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| CycleCountVariancePacks | int64 | 0 | 0.0 | 6 | -3 | 2 | 0, -3, -1 |  |
| DockToStockHours | float64 | 111,220 | 99.14 | 80 | 5.0 | 15.0 | 7.2, 9.9, 9.5 |  |
| OrderPickingAccuracyPct | float64 | 1,961 | 1.75 | 251 | 97.5 | 100.0 | 98.26, 99.29, 99.03 |  |
| AllocatedBinCapacityPacks | int64 | 0 | 0.0 | 88 | 4300 | 15700 | 8600, 8200, 7600 |  |
| WarehouseTotalCapacityPacks | int64 | 0 | 0.0 | 6 | 280000 | 900000 | 900000, 280000, 800000 |  |
| WarehouseActivityStatus | str | 0 | 0.0 | 5 |  |  | Receive and putaway, Storage monitoring, Pick and dispatch |  |
| SourceSystem | str | 0 | 0.0 | 1 |  |  | WMS_DAILY_SNAPSHOT | constant column |

## 05_pharmacy_sales_data.csv

- Rows: **500,000**  |  Columns: **45**  |  File size: 208.5 MB  |  Read time: 6.6 s
- Fully duplicated rows: 0
- Primary key: `SalesTransactionID` -> UNIQUE - OK (duplicate keys: 0, rows with empty key: 0)

| Column | Type | Empty | Empty % | Distinct | Min | Max | Examples | Notes |
|---|---|---|---|---|---|---|---|---|
| SalesTransactionID | str | 0 | 0.0 | 500,000 |  |  | SALE-000000001, SALE-000000002, SALE-000000003 |  |
| SalesDate | str (date-like) | 0 | 0.0 | 1,067 | 2023-01-30 00:00:00 | 2025-12-31 00:00:00 | 2023-11-12, 2023-02-27, 2023-09-24 |  |
| SalesTimestampUTC | str (date-like) | 0 | 0.0 | 452,674 | 2023-01-30 23:29:47+00:00 | 2025-12-31 23:44:11+00:00 | 2023-11-12T13:43:13Z, 2023-02-27T11:38:43Z, 2023-09-24T17:55:25Z |  |
| SalesChannel | str | 0 | 0.0 | 2 |  |  | Physical Pharmacy, Ecommerce |  |
| PharmacyID | str | 0 | 0.0 | 60 |  |  | PHR014, PHR052, PHR005 |  |
| PharmacyGLN | int64 | 0 | 0.0 | 60 | 950600300010 | 950600300607 | 950600300140, 950600300522, 950600300058 |  |
| PharmacyName | str | 0 | 0.0 | 60 |  |  | WellSpring Pharmacy 14, Community Care Pharmacy 52, Clarity Medical Center Pharmacy 05 |  |
| PharmacyType | str | 0 | 0.0 | 3 |  |  | Chain Pharmacy, Independent Pharmacy, Hospital Pharmacy |  |
| HospitalID | str | 390,808 | 78.16 | 12 |  |  | HOSP005, HOSP012, HOSP010 |  |
| PharmacyCity | str | 0 | 0.0 | 18 |  |  | Las Vegas, Miami, Hartford |  |
| PharmacyState | str | 0 | 0.0 | 15 |  |  | NV, FL, CT |  |
| CountryCode | str | 0 | 0.0 | 1 |  |  | US | constant column |
| PharmacyOrderID | str | 0 | 0.0 | 3,774 |  |  | PHO-0002583, PHO-0000343, PHO-0002597 |  |
| PharmacyDeliveryID | str | 0 | 0.0 | 3,774 |  |  | PHD-0002583, PHD-0000343, PHD-0002597 |  |
| PharmacyDeliveryDate | str (date-like) | 0 | 0.0 | 888 | 2023-01-27 00:00:00 | 2025-12-31 00:00:00 | 2023-09-07, 2023-02-20, 2023-09-15 |  |
| DeliveryQuantityPacks | int64 | 0 | 0.0 | 2,072 | 396 | 6817 | 1246, 1312, 2403 |  |
| DeliveryOTIFFlag | str | 0 | 0.0 | 2 |  |  | Y, N |  |
| WarehouseLotID | str | 0 | 0.0 | 956 |  |  | WHLOT-0000658, WHLOT-0000087, WHLOT-0000660 |  |
| SourceWarehouseID | str | 0 | 0.0 | 6 |  |  | WH004, WH005, WH006 |  |
| ProductionBatchID | str | 0 | 0.0 | 536 |  |  | B23-PLT02-000362, B23-PLT02-000037, B23-PLT02-000363 |  |
| MedicineID | str | 0 | 0.0 | 63 |  |  | MED041, MED005, MED007 |  |
| GTIN14 | int64 | 0 | 0.0 | 63 | 9506000000015 | 9506000000633 | 9506000000411, 9506000000053, 9506000000077 |  |
| DiseaseCategory | str | 0 | 0.0 | 7 |  |  | Gastrointestinal Disease, Diabetes Mellitus, Cardiovascular Disease |  |
| GenericName | str | 0 | 0.0 | 63 |  |  | Domperidone, Dapagliflozin, Insulin Glargine |  |
| BatchExpiryDate | str (date-like) | 0 | 0.0 | 426 | 2025-01-10 00:00:00 | 2028-12-05 00:00:00 | 2025-07-31, 2025-01-27, 2025-08-24 |  |
| DaysToExpiryAtSale | int64 | 0 | 0.0 | 709 | 9 | 1075 | 627, 700, 707 |  |
| QuantitySoldPacks | int64 | 0 | 0.0 | 3 | 1 | 3 | 2, 1, 3 |  |
| UnitRetailPriceUSD | float64 | 0 | 0.0 | 41 | 2.38 | 121.44 | 3.96, 17.42, 50.16 |  |
| GrossSalesAmountUSD | float64 | 0 | 0.0 | 112 | 2.38 | 364.32 | 7.92, 17.42, 3.96 |  |
| DiscountAmountUSD | float64 | 0 | 0.0 | 211 | 0.0 | 36.43 | 0.4, 0.0, 1.39 | 420,276 zero |
| NetSalesAmountUSD | float64 | 0 | 0.0 | 414 | 2.14 | 364.32 | 7.52, 17.42, 3.96 |  |
| SalesTaxUSD | float64 | 0 | 0.0 | 232 | 0.13 | 21.86 | 0.45, 1.05, 0.24 |  |
| CostOfGoodsSoldUSD | float64 | 0 | 0.0 | 103 | 1.8 | 276.0 | 6.0, 13.2, 3.0 |  |
| GrossMarginUSD | float64 | 0 | 0.0 | 356 | 0.34 | 88.32 | 1.52, 4.22, 0.96 |  |
| PromotionCode | str | 420,276 | 84.06 | 4 |  |  | LOYALTY5, SEASON5, ONLINE10 |  |
| PrescriptionRequiredFlag | str | 0 | 0.0 | 2 |  |  | Y, N |  |
| PrescriptionID | str | 37,316 | 7.46 | 462,684 |  |  | RX-000000001, RX-000000002, RX-000000003 |  |
| CustomerSegment | str | 0 | 0.0 | 5 |  |  | Adult chronic care, General wellness, Pediatric household |  |
| PayerType | str | 0 | 0.0 | 4 |  |  | Government program, Cash, Insurance |  |
| PaymentMethod | str | 0 | 0.0 | 4 |  |  | Cash, Insurance claim, Digital wallet |  |
| EcommerceDeliveryStatus | str | 0 | 0.0 | 3 |  |  | Not applicable, Delivered, Returned to sender |  |
| ReturnFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| ReturnedQuantityPacks | int64 | 0 | 0.0 | 2 | 0 | 1 | 0, 1 | 494,028 zero |
| SaleStatus | str | 0 | 0.0 | 2 |  |  | Completed, Partially returned |  |
| SourceSystem | str | 0 | 0.0 | 2 |  |  | PHARMACY_POS, ECOM_ORDER_PLATFORM |  |

## 06_hospital_demand_data.csv

- Rows: **27,216**  |  Columns: **41**  |  File size: 8.3 MB  |  Read time: 0.3 s
- Fully duplicated rows: 0
- Primary key: `HospitalDemandRecordID` -> UNIQUE - OK (duplicate keys: 0, rows with empty key: 0)

| Column | Type | Empty | Empty % | Distinct | Min | Max | Examples | Notes |
|---|---|---|---|---|---|---|---|---|
| HospitalDemandRecordID | str | 0 | 0.0 | 27,216 |  |  | HDEM-00000001, HDEM-00000002, HDEM-00000003 |  |
| DemandMonth | str | 0 | 0.0 | 36 |  |  | 2023-01-01, 2023-02-01, 2023-03-01 |  |
| HospitalID | str | 0 | 0.0 | 12 |  |  | HOSP001, HOSP002, HOSP003 |  |
| HospitalGLN | int64 | 0 | 0.0 | 12 | 950600400017 | 950600400123 | 950600400017, 950600400024, 950600400031 |  |
| HospitalName | str | 0 | 0.0 | 12 |  |  | University Medical Center, Mercy Regional Hospital, Metro Specialty Institute |  |
| HospitalType | str | 0 | 0.0 | 4 |  |  | Academic Medical Center, General Hospital, Specialty Hospital |  |
| HospitalPharmacyID | str | 0 | 0.0 | 12 |  |  | PHR001, PHR002, PHR003 |  |
| City | str | 0 | 0.0 | 12 |  |  | Philadelphia, Pittsburgh, New York |  |
| State | str | 0 | 0.0 | 10 |  |  | PA, NY, MA |  |
| CountryCode | str | 0 | 0.0 | 1 |  |  | US | constant column |
| LicensedBeds | int64 | 0 | 0.0 | 12 | 280 | 920 | 850, 520, 310 |  |
| ICUBeds | int64 | 0 | 0.0 | 12 | 24 | 110 | 96, 54, 38 |  |
| AverageOccupancyRatePct | int64 | 0 | 0.0 | 12 | 68 | 86 | 68, 75, 82 |  |
| TraumaLevel | str | 13,608 | 50.0 | 2 |  |  | Level I, Level II |  |
| CatchmentPopulation | int64 | 0 | 0.0 | 12 | 610000 | 2100000 | 1800000, 920000, 1300000 |  |
| MedicineID | str | 0 | 0.0 | 63 |  |  | MED001, MED002, MED003 |  |
| GTIN14 | int64 | 0 | 0.0 | 63 | 9506000000015 | 9506000000633 | 9506000000015, 9506000000022, 9506000000039 |  |
| GenericName | str | 0 | 0.0 | 63 |  |  | Metformin, Gliclazide MR, Sitagliptin |  |
| DiseaseCategory | str | 0 | 0.0 | 7 |  |  | Diabetes Mellitus, Cardiovascular Disease, Respiratory Disease |  |
| ICD10Category | str | 0 | 0.0 | 7 |  |  | E11, I10-I99, J40-J47 |  |
| EstimatedDiseaseCases | int64 | 0 | 0.0 | 3,699 | 655 | 6502 | 3329, 2537, 2817 |  |
| DiseaseRelatedAdmissions | int64 | 0 | 0.0 | 2,549 | 255 | 3635 | 1769, 1373, 1300 |  |
| OutpatientEncounters | int64 | 0 | 0.0 | 6,559 | 775 | 11647 | 5111, 3558, 3825 |  |
| ForecastDemandPacks | int64 | 0 | 0.0 | 624 | 38 | 809 | 226, 191, 175 |  |
| RequestedQuantityPacks | int64 | 0 | 0.0 | 714 | 40 | 1144 | 307, 204, 192 |  |
| ApprovedQuantityPacks | int64 | 0 | 0.0 | 690 | 39 | 1109 | 292, 204, 182 |  |
| ReceivedQuantityPacks | int64 | 0 | 0.0 | 675 | 29 | 1068 | 282, 198, 181 |  |
| EmergencyRequestQuantityPacks | int64 | 0 | 0.0 | 135 | 0 | 195 | 44, 0, 39 | 24,210 zero |
| OpeningStockPacks | int64 | 0 | 0.0 | 823 | 0 | 937 | 409, 393, 391 |  |
| DispensedQuantityPacks | int64 | 0 | 0.0 | 658 | 39 | 1020 | 298, 200, 167 |  |
| ConsumedQuantityPacks | int64 | 0 | 0.0 | 655 | 38 | 994 | 291, 196, 164 |  |
| WastageQuantityPacks | int64 | 0 | 0.0 | 9 | 0 | 8 | 0, 4, 1 | 24,977 zero |
| ClosingStockPacks | int64 | 0 | 0.0 | 825 | 0 | 937 | 393, 391, 405 |  |
| UnfulfilledDemandPacks | int64 | 0 | 0.0 | 49 | 0 | 153 | 0, 46, 12 |  |
| StockoutDays | int64 | 0 | 0.0 | 9 | 0 | 8 | 0, 5, 1 |  |
| ServiceLevelPct | float64 | 0 | 0.0 | 78 | 70.23 | 100.0 | 100.0, 83.15, 95.51 |  |
| MedicationRequestStatus | str | 0 | 0.0 | 2 |  |  | Completed, Partially fulfilled |  |
| FormularyStatus | str | 0 | 0.0 | 3 |  |  | Formulary, Restricted, Non-formulary exception |  |
| AverageLeadTimeDays | int64 | 0 | 0.0 | 14 | 7 | 20 | 12, 11, 10 |  |
| DemandTrendIndex | float64 | 0 | 0.0 | 402 | 0.86 | 1.32 | 1.215, 0.865, 0.938 |  |
| SourceSystem | str | 0 | 0.0 | 1 |  |  | HOSPITAL_ERP_FHIR_EXPORT | constant column |

## 07_iot_streaming_data.csv

- Rows: **293,425**  |  Columns: **30**  |  File size: 71.7 MB  |  Read time: 2.1 s
- Fully duplicated rows: 0
- Primary key: `SensorReadingID` -> UNIQUE - OK (duplicate keys: 0, rows with empty key: 0)

| Column | Type | Empty | Empty % | Distinct | Min | Max | Examples | Notes |
|---|---|---|---|---|---|---|---|---|
| SensorReadingID | str | 0 | 0.0 | 293,425 |  |  | IOTR-0000000001, IOTR-0000000002, IOTR-0000000003 |  |
| DeviceID | str | 0 | 0.0 | 891 |  |  | IOT-WH001-AMB-01, IOT-WH001-AMB-02, IOT-WH001-COLD-01 |  |
| DeviceType | str | 0 | 0.0 | 2 |  |  | Temperature-humidity logger, Multi-sensor GPS logger |  |
| AssetType | str | 0 | 0.0 | 2 |  |  | WarehouseZone, Shipment |  |
| ShipmentID | str | 210,432 | 71.72 | 867 |  |  | MFG-SHP-0000001, MFG-SHP-0000002, MFG-SHP-0000003 |  |
| SSCC18 | float64 | 210,432 | 71.72 | 549 | 9.506001000800002e+16 | 9.506001000800898e+16 | 9.506001000800002e+16, 9.506001000800003e+16, 9.506001000800005e+16 |  |
| WarehouseID | str | 82,993 | 28.28 | 6 |  |  | WH001, WH002, WH003 |  |
| StorageZoneID | str | 82,993 | 28.28 | 24 |  |  | WH001-AMB-01, WH001-AMB-02, WH001-COLD-01 |  |
| EventTimestampUTC | str (date-like) | 0 | 0.0 | 38,080 | 2023-01-01 00:00:00+00:00 | 2025-12-31 23:30:00+00:00 | 2023-01-01T00:00:00Z, 2023-01-01T03:00:00Z, 2023-01-01T06:00:00Z |  |
| IngestionTimestampUTC | str (date-like) | 0 | 0.0 | 264,448 | 2023-01-01 00:00:06+00:00 | 2025-12-31 23:31:31+00:00 | 2023-01-01T00:00:46Z, 2023-01-01T03:00:51Z, 2023-01-01T06:00:34Z |  |
| EventSequenceNumber | int64 | 0 | 0.0 | 8,768 | 1 | 8768 | 1, 2, 3 |  |
| TemperatureC | float64 | 0 | 0.0 | 1,350 | 0.51 | 30.27 | 18.51, 22.61, 22.14 |  |
| RelativeHumidityPct | float64 | 0 | 0.0 | 2,944 | 42.0 | 83.67 | 56.99, 56.38, 44.84 |  |
| Latitude | float64 | 0 | 0.0 | 82,765 | 27.001364 | 48.195281 | 40.6023, 41.525, 32.7767 |  |
| Longitude | float64 | 0 | 0.0 | 82,916 | -125.641711 | -63.858079 | -75.4714, -88.0817, -96.797 |  |
| DoorOpenFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| ShockG | float64 | 0 | 0.0 | 721 | 0.0 | 4.495 | 0.061, 0.046, 0.068 |  |
| BatteryLevelPct | float64 | 0 | 0.0 | 160 | 84.1 | 100.0 | 100.0, 99.9, 99.8 |  |
| SignalStrengthDbm | int64 | 0 | 0.0 | 49 | -96 | -48 | -51, -74, -87 |  |
| StorageMinTempC | int64 | 0 | 0.0 | 2 | 2 | 15 | 15, 2 |  |
| StorageMaxTempC | int64 | 0 | 0.0 | 2 | 8 | 25 | 25, 8 |  |
| MaxHumidityPct | int64 | 0 | 0.0 | 2 | 65 | 75 | 65, 75 |  |
| TemperatureBreachFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| HumidityBreachFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| ThresholdBreachFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| AlertSeverity | str | 0 | 0.0 | 3 |  |  | Normal, Warning, Critical |  |
| ReadingQuality | str | 0 | 0.0 | 2 |  |  | Valid, Suspect |  |
| DataLatencySeconds | int64 | 0 | 0.0 | 2,460 | 2 | 3600 | 46, 51, 34 |  |
| LateArrivalFlag | str | 0 | 0.0 | 2 |  |  | N, Y |  |
| SourceStream | str | 0 | 0.0 | 2 |  |  | mqtt/pharma/warehouse/environment, mqtt/pharma/transport/telemetry |  |

## Relationships between files

An orphan is an ID in the child file that does not exist in the parent file. Orphans must be handled by validation rules before loading facts.

| ID column | Parent file (ID unique) | Child file | Orphan rows | Result |
|---|---|---|---|---|
| HospitalID | - | 05_pharmacy_sales_data.csv, 06_hospital_demand_data.csv | - | no file has this ID as a unique key |
| ManufacturingOrderID | 02_manufacturing_data.csv | 03_manufacturer_delivery_data.csv | 0 | OK |
| MedicineID | 01_master_data.csv | 02_manufacturing_data.csv | 0 | OK |
| MedicineID | 01_master_data.csv | 03_manufacturer_delivery_data.csv | 0 | OK |
| MedicineID | 01_master_data.csv | 04_warehouse_data.csv | 0 | OK |
| MedicineID | 01_master_data.csv | 05_pharmacy_sales_data.csv | 0 | OK |
| MedicineID | 01_master_data.csv | 06_hospital_demand_data.csv | 0 | OK |
| ProductionBatchID | 02_manufacturing_data.csv | 03_manufacturer_delivery_data.csv | 0 | OK |
| ProductionBatchID | 02_manufacturing_data.csv | 04_warehouse_data.csv | 0 | OK |
| ProductionBatchID | 02_manufacturing_data.csv | 05_pharmacy_sales_data.csv | 0 | OK |
| ShipmentID | - | 03_manufacturer_delivery_data.csv, 07_iot_streaming_data.csv | - | no file has this ID as a unique key |
| StorageZoneID | - | 04_warehouse_data.csv, 07_iot_streaming_data.csv | - | no file has this ID as a unique key |
| WarehouseID | - | 04_warehouse_data.csv, 07_iot_streaming_data.csv | - | no file has this ID as a unique key |
| WarehouseLotID | - | 04_warehouse_data.csv, 05_pharmacy_sales_data.csv | - | no file has this ID as a unique key |
