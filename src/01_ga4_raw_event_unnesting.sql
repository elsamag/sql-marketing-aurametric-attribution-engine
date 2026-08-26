-- =============================================================================
-- Enterprise Practice : Elsamag IT Solutions
-- Author & Lead Cons. : Samuel Chinwendu Agu
-- Repository Target   : https://github.com/Elsamag/sql-marketing-aurametric-attribution-engine
-- File Path           : src/01_ga4_raw_event_unnesting.sql
-- Target Client       : AuraMetric Media Group
-- Objective           : Partition-pruned event extraction, scalar parameter 
--                       unnesting, and SHA-256 PII sanitization from raw GA4 streams.
-- Dialect Standard    : Google Cloud BigQuery Standard SQL
-- =============================================================================

CREATE OR REPLACE VIEW `aurametric-media-analytics.attribution_staging.v_ga4_raw_event_unnesting` AS
SELECT
    -- PII Protection Layer (Cryptographic Irreversible SHA-256 Hashing)
    TO_HEX(SHA256(LOWER(TRIM(user_pseudo_id)))) AS hashed_user_id,
    
    -- Event Temporal Metadata
    TIMESTAMP_MICROS(event_timestamp) AS event_timestamp,
    DATE(TIMESTAMP_MICROS(event_timestamp)) AS event_date,
    event_name,

    -- Parameter Array Unnesting via Targeted Scalar Subqueries
    (
        SELECT value.string_value 
        FROM UNNEST(event_params) 
        WHERE key = 'source'
    ) AS traffic_source,

    (
        SELECT value.string_value 
        FROM UNNEST(event_params) 
        WHERE key = 'medium'
    ) AS traffic_medium,

    (
        SELECT value.string_value 
        FROM UNNEST(event_params) 
        WHERE key = 'campaign'
    ) AS campaign_name,

    (
        SELECT value.string_value 
        FROM UNNEST(event_params) 
        WHERE key = 'page_location'
    ) AS page_location,

    COALESCE(
        (
            SELECT value.int_value 
            FROM UNNEST(event_params) 
            WHERE key = 'ga_session_id'
        ), 
        0
    ) AS session_id,

    -- Financial & Conversion Valuation
    COALESCE(event_value_in_usd, 0.0) AS conversion_value,
    
    -- Audit & Partition Metadata
    _TABLE_SUFFIX AS partition_suffix

FROM
    `aurametric-media-analytics.analytics_293847102.events_*`
WHERE
    -- Date Partition Pruning to eliminate full-table scan overhead
    _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY))
                      AND FORMAT_DATE('%Y%m%d', CURRENT_DATE())
    AND event_name IN (
        'session_start',
        'first_visit',
        'page_view',
        'view_item',
        'add_to_cart',
        'begin_checkout',
        'purchase',
        'generate_lead'
    );
