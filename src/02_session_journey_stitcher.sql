-- =============================================================================
-- Enterprise Practice: Elsamag IT Solutions
-- Author & Lead Technical Consultant: Samuel Chinwendu Agu
-- Repository: sql-marketing-aurametric-attribution-engine
-- File Target: src/02_session_journey_stitcher.sql
-- Dialect: Google Cloud BigQuery Standard SQL
-- Target Client: AuraMetric Media Group (VP Marcus Vance)
-- Objective: Chronologically order, stitch, and window-rank cross-channel 
--            touchpoints into coherent multi-touch customer journey sequences.
-- =============================================================================

CREATE OR REPLACE VIEW `aurametric-media-analytics.attribution_mart.v_session_journeys` AS

WITH consolidated_event_stream AS (
    -- Tier 1: Pull sanitized web & CRM conversion touchpoints
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

journey_sequencer AS (
    -- Tier 2: Sequence touchpoints and compute trajectory dynamics per user
    SELECT
        hashed_user_id,
        touchpoint_timestamp,
        COALESCE(traffic_source, '(direct)') AS traffic_source,
        COALESCE(traffic_medium, '(none)') AS traffic_medium,
        COALESCE(campaign_name, '(organic/untracked)') AS campaign_name,
        session_id,
        event_name,
        conversion_value,
        
        -- Chronological Position & Total Journey Path Length
        DENSE_RANK() OVER(
            PARTITION BY hashed_user_id 
            ORDER BY touchpoint_timestamp ASC
        ) AS touchpoint_position,
        
        COUNT(*) OVER(
            PARTITION BY hashed_user_id
        ) AS total_touchpoints,

        -- Prior Step Lag for Path Transition Analysis
        LAG(traffic_source, 1) OVER(
            PARTITION BY hashed_user_id 
            ORDER BY touchpoint_timestamp ASC
        ) AS previous_channel_source,

        -- Path Latency (Hours between interactions)
        ROUND(
            TIMESTAMP_DIFF(
                touchpoint_timestamp, 
                LAG(touchpoint_timestamp, 1) OVER(
                    PARTITION BY hashed_user_id 
                    ORDER BY touchpoint_timestamp ASC
                ),
                SECOND
            ) / 3600.0, 
            2
        ) AS hours_since_prior_touchpoint,

        -- Total Path Lifespan
        ROUND(
            TIMESTAMP_DIFF(
                MAX(touchpoint_timestamp) OVER(PARTITION BY hashed_user_id),
                MIN(touchpoint_timestamp) OVER(PARTITION BY hashed_user_id),
                SECOND
            ) / 86400.0,
            2
        ) AS journey_duration_days
    FROM
        consolidated_event_stream
)

-- Tier 3: Staged Output Ready for Multi-Touch Weight Allocation
SELECT
    hashed_user_id,
    touchpoint_position,
    total_touchpoints,
    touchpoint_timestamp,
    traffic_source,
    traffic_medium,
    campaign_name,
    previous_channel_source,
    hours_since_prior_touchpoint,
    journey_duration_days,
    event_name,
    conversion_value,
    CASE 
        WHEN touchpoint_position = 1 AND total_touchpoints = 1 THEN 'Single-Touch Interaction'
        WHEN touchpoint_position = 1 THEN 'First-Touch (Acquisition)'
        WHEN touchpoint_position = total_touchpoints THEN 'Last-Touch (Conversion Close)'
        ELSE 'Middle-Touch (Nurture/Assisting)'
    END AS touchpoint_funnel_role
FROM
    journey_sequencer
ORDER BY
    hashed_user_id,
    touchpoint_position ASC;
