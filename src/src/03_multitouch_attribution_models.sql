-- =============================================================================
-- Enterprise Practice: Elsamag IT Solutions
-- Author & Lead Technical Consultant: Samuel Chinwendu Agu
-- Target Client: AuraMetric Media Group
-- Target File: src/03_multitouch_attribution_models.sql
-- Objective: Multi-Touch GA4 Attribution Engine with 4-Model Revenue Allocation
-- Dialect: Google Cloud BigQuery Standard SQL
-- =============================================================================

WITH raw_touchpoints AS (
    -- Tier 1: Ingest and Unnest Web Application Touchpoints with Partition Pruning
    SELECT
        TO_HEX(SHA256(LOWER(TRIM(user_pseudo_id)))) AS hashed_user_id,
        TIMESTAMP_MICROS(event_timestamp) AS touchpoint_timestamp,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'source') AS traffic_source,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'medium') AS traffic_medium,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'campaign') AS campaign_name,
        COALESCE((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id'), 0) AS session_id,
        event_name,
        COALESCE(event_value_in_usd, 0.0) AS conversion_value
    FROM
        `aurametric-media-analytics.analytics_293847102.events_*`
    WHERE
        _TABLE_SUFFIX BETWEEN '20260701' AND '20260731'
        AND event_name IN ('session_start', 'page_view', 'purchase', 'generate_lead')

    UNION ALL

    -- Tier 2: Ingest and Stack Secondary CRM Pipeline Conversions
    SELECT
        TO_HEX(SHA256(LOWER(TRIM(crm_lead_id)))) AS hashed_user_id,
        crm_created_at AS touchpoint_timestamp,
        lead_source AS traffic_source,
        lead_medium AS traffic_medium,
        lead_campaign AS campaign_name,
        0 AS session_id,
        'crm_conversion' AS event_name,
        deal_amount_usd AS conversion_value
    FROM
        `aurametric-media-analytics.crm_data.closed_deals_2026`
    WHERE
        deal_status = 'WON'
        AND DATE(crm_created_at) BETWEEN '2026-07-01' AND '2026-07-31'
),

customer_journeys AS (
    -- Tier 3: Chronologically Order Cross-Channel Touchpoints per User
    SELECT
        hashed_user_id,
        touchpoint_timestamp,
        traffic_source,
        traffic_medium,
        campaign_name,
        event_name,
        conversion_value,
        DENSE_RANK() OVER(
            PARTITION BY hashed_user_id 
            ORDER BY touchpoint_timestamp ASC
        ) AS touchpoint_position,
        COUNT(*) OVER(
            PARTITION BY hashed_user_id
        ) AS total_touchpoints
    FROM
        raw_touchpoints
)

-- Tier 4: Calculate 4-Model Attribution Weights and Weighted Revenue
SELECT
    hashed_user_id,
    touchpoint_position,
    total_touchpoints,
    traffic_source,
    traffic_medium,
    campaign_name,
    conversion_value,
    
    -- Model 1: First-Touch Attribution
    CASE 
        WHEN touchpoint_position = 1 THEN 1.0 
        ELSE 0.0 
    END AS first_touch_weight,
    
    -- Model 2: Last-Touch Attribution
    CASE 
        WHEN touchpoint_position = total_touchpoints THEN 1.0 
        ELSE 0.0 
    END AS last_touch_weight,
    
    -- Model 3: Linear Attribution
    ROUND(1.0 / total_touchpoints, 4) AS linear_weight,
    
    -- Model 4: Position-Based (U-Shaped) Attribution
    CASE
        WHEN total_touchpoints = 1 THEN 1.0
        WHEN total_touchpoints = 2 THEN 0.50
        WHEN total_touchpoints >= 3 AND touchpoint_position = 1 THEN 0.40
        WHEN total_touchpoints >= 3 AND touchpoint_position = total_touchpoints THEN 0.40
        ELSE ROUND(0.20 / (total_touchpoints - 2), 4)
    END AS u_shaped_weight,
    
    -- Revenue Multipliers
    ROUND(conversion_value * (CASE WHEN touchpoint_position = 1 THEN 1.0 ELSE 0.0 END), 2) AS fta_revenue_usd,
    ROUND(conversion_value * (CASE WHEN touchpoint_position = total_touchpoints THEN 1.0 ELSE 0.0 END), 2) AS lta_revenue_usd,
    ROUND(conversion_value * (1.0 / total_touchpoints), 2) AS linear_revenue_usd,
    ROUND(conversion_value * (
        CASE
            WHEN total_touchpoints = 1 THEN 1.0
            WHEN total_touchpoints = 2 THEN 0.50
            WHEN total_touchpoints >= 3 AND touchpoint_position = 1 THEN 0.40
            WHEN total_touchpoints >= 3 AND touchpoint_position = total_touchpoints THEN 0.40
            ELSE 0.20 / (total_touchpoints - 2)
        END
    ), 2) AS u_shaped_revenue_usd
FROM
    customer_journeys
ORDER BY
    hashed_user_id,
    touchpoint_position ASC;
