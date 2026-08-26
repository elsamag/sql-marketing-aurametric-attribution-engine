-- =============================================================================
-- Enterprise Practice: Elsamag IT Solutions
-- Author & Lead Technical Consultant: Samuel Chinwendu Agu
-- Target Client: AuraMetric Media Group
-- Script Asset: src/04_pii_sanitization_layer.sql
-- Objective: Cryptographic SHA-256 PII Hashing & Data Governance Transformation
-- Dialect: Google Cloud BigQuery Standard SQL
-- =============================================================================

CREATE OR REPLACE VIEW `aurametric-media-analytics.attribution_mart.v_sanitized_touchpoints` AS

WITH raw_event_stream AS (
    SELECT
        user_pseudo_id,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'user_email') AS raw_email,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'phone_number') AS raw_phone,
        geo.region AS region,
        geo.country AS country,
        TIMESTAMP_MICROS(event_timestamp) AS touchpoint_timestamp,
        event_name,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'source') AS traffic_source,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'medium') AS traffic_medium,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'campaign') AS campaign_name,
        COALESCE((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'), 0) AS session_id,
        COALESCE(event_value_in_usd, 0.0) AS conversion_value
    FROM
        `aurametric-media-analytics.analytics_293847102.events_*`
    WHERE
        _TABLE_SUFFIX BETWEEN '20260701' AND '20260731'
        AND event_name IN ('session_start', 'page_view', 'purchase', 'generate_lead')
)

SELECT
    -- Irreversible Cryptographic Hashing for GA4 Device/Cookie Identifiers
    TO_HEX(SHA256(LOWER(TRIM(user_pseudo_id)))) AS hashed_user_id,

    -- Salted SHA-256 Normalization for Direct User Identifiers (Email)
    CASE 
        WHEN raw_email IS NOT NULL AND TRIM(raw_email) != '' 
        THEN TO_HEX(SHA256(CONCAT('AURA_2026_SALT_', LOWER(TRIM(raw_email)))))
        ELSE NULL 
    END AS hashed_email,

    -- Sanitized & Salted Phone Hash (Stripping non-numeric characters prior to hash)
    CASE 
        WHEN raw_phone IS NOT NULL AND TRIM(raw_phone) != '' 
        THEN TO_HEX(SHA256(CONCAT('AURA_2026_SALT_', REGEXP_REPLACE(raw_phone, r'[^0-9]', ''))))
        ELSE NULL 
    END AS hashed_phone,

    -- Preserved Non-PII Dimensions for Attribution Modeling
    touchpoint_timestamp,
    event_name,
    traffic_source,
    traffic_medium,
    campaign_name,
    session_id,
    conversion_value,
    country,
    region,

    -- Metadata Governance Flags
    CURRENT_TIMESTAMP() AS sanitization_processed_at,
    'SHA-256-SALTED-V1' AS encryption_standard
FROM
    raw_event_stream;
