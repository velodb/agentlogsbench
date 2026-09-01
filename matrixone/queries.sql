-- Q01
SELECT
  event_time,
  trace_id,
  observation_id,
  seq_no,
  type,
  status,
  model,
  tool_name,
  latency_ms
FROM __MO_TABLE__
WHERE biz_date BETWEEN CAST(__START_DATE__ AS DATE) AND CAST(__END_DATE__ AS DATE)
  AND tenant = __TENANT__
  AND type IN ('GENERATION', 'TOOL')
  AND status IN ('ok', 'error')
ORDER BY event_time DESC, seq_no DESC
LIMIT 50;

-- Q02
SELECT
  trace_id,
  MIN(event_time) AS started_at,
  COUNT(*) AS observation_count,
  SUM(CASE WHEN status <> 'ok' THEN 1 ELSE 0 END) AS failure_count,
  SUM(total_cost) AS total_cost,
  SUM(latency_ms) AS total_latency_ms
FROM __MO_TABLE__
WHERE biz_date BETWEEN CAST(__START_DATE__ AS DATE) AND CAST(__END_DATE__ AS DATE)
GROUP BY trace_id
ORDER BY total_cost DESC, total_latency_ms DESC, trace_id ASC
LIMIT 50;

-- Q03
SELECT
  trace_id,
  seq_no,
  type,
  status,
  model,
  tool_name,
  input,
  output
FROM __MO_TABLE__
WHERE trace_id = __TRACE_ID__
ORDER BY seq_no ASC;

-- Q04
SELECT
  child.trace_id,
  child.seq_no,
  child.observation_id,
  child.parent_observation_id,
  parent.type AS parent_type,
  child.type AS child_type,
  child.status,
  child.tool_name
FROM __MO_TABLE__ AS child
LEFT JOIN __MO_TABLE__ AS parent
  ON child.parent_observation_id = parent.observation_id
WHERE child.trace_id = __TRACE_ID__
ORDER BY child.seq_no ASC;

-- Q05
SELECT
  event_time,
  trace_id,
  observation_id,
  tool_name,
  latency_ms,
  (
    CASE WHEN LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'unable', '%') THEN 1 ELSE 0 END +
    CASE WHEN LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'open', '%') THEN 1 ELSE 0 END
  ) AS text_score,
  payload
FROM __MO_TABLE__
WHERE type = 'TOOL'
  AND status = 'error'
  AND tenant = __TENANT__
  AND app = __APP__
  AND LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'unable', '%')
  AND LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'open', '%')
ORDER BY text_score DESC, latency_ms DESC, event_time DESC
LIMIT 50;

-- Q06
SELECT
  type,
  model,
  COUNT(*) AS observations,
  SUM(input_tokens) AS input_tokens,
  SUM(output_tokens) AS output_tokens,
  SUM(total_cost) AS total_cost,
  AVG(latency_ms) AS avg_latency_ms
FROM __MO_TABLE__
GROUP BY type, model
ORDER BY total_cost DESC, avg_latency_ms DESC, observations DESC,
  input_tokens DESC, output_tokens DESC, type ASC, model ASC
LIMIT 50;

-- Q07
SELECT
  event_time,
  trace_id,
  observation_id,
  type,
  status,
  payload
FROM __MO_TABLE__
WHERE environment = 'prod'
  AND type IN ('GENERATION', 'TOOL', 'RETRIEVAL')
  AND payload ->> '$.attr.release_ring' IN ('stable', 'canary')
  AND payload ->> '$.attr.retrieval_strategy' IN ('hybrid', 'hybrid_rerank')
  AND payload ->> '$.attr.surface' IN ('api', 'workflow_runner')
  AND payload ->> '$.attr.prompt_template_version' IN ('pt_2026_03_2', 'pt_2026_04_1', 'pt_2026_04_2')
ORDER BY event_time DESC, trace_id DESC, observation_id DESC
LIMIT 50;

-- Q08
SELECT
  event_time,
  trace_id,
  observation_id,
  type,
  status,
  input,
  output,
  CASE WHEN LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'unable to open', '%') THEN 1 ELSE 0 END AS phrase_match,
  (
    CASE WHEN LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'unable', '%') THEN 1 ELSE 0 END +
    CASE WHEN LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'open', '%') THEN 1 ELSE 0 END
  ) AS text_score
FROM __MO_TABLE__
WHERE tenant = __TENANT__
  AND LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'unable', '%')
  AND LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'open', '%')
  AND LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'unable to open', '%')
ORDER BY phrase_match DESC, text_score DESC, event_time DESC, trace_id DESC, observation_id DESC
LIMIT 50;

-- Q09
SELECT
  tool_name,
  status,
  COUNT(*) AS observations,
  AVG(latency_ms) AS avg_latency_ms
FROM __MO_TABLE__
WHERE type = 'TOOL'
GROUP BY tool_name, status
ORDER BY observations DESC, avg_latency_ms DESC, tool_name ASC, status ASC
LIMIT 50;

-- Q10
SELECT
  payload ->> '$.provider.stop_reason' AS stop_reason,
  payload ->> '$.provider.cache_hit' AS cache_hit,
  COUNT(*) AS observations,
  AVG(latency_ms) AS avg_latency_ms
FROM __MO_TABLE__
WHERE type = 'GENERATION'
GROUP BY payload ->> '$.provider.stop_reason', payload ->> '$.provider.cache_hit'
ORDER BY observations DESC, avg_latency_ms DESC, stop_reason ASC, cache_hit ASC
LIMIT 50;

-- Q11
SELECT
  event_time,
  trace_id,
  observation_id,
  type,
  status,
  tool_name,
  latency_ms,
  CASE WHEN LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'unable to open', '%') THEN 1 ELSE 0 END AS phrase_match,
  (
    CASE WHEN LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'unable', '%') THEN 1 ELSE 0 END +
    CASE WHEN LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'open', '%') THEN 1 ELSE 0 END
  ) AS text_score
FROM __MO_TABLE__
WHERE tenant = __TENANT__
  AND app = __APP__
  AND type IN ('GENERATION', 'TOOL', 'RETRIEVAL')
  AND LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'unable', '%')
  AND LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'open', '%')
  AND LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE CONCAT('%', 'unable to open', '%')
ORDER BY phrase_match DESC, text_score DESC, latency_ms DESC, event_time DESC, trace_id DESC, observation_id DESC
LIMIT 50;

-- Q12
SELECT
  payload ->> '$.attr.release_ring' AS release_ring,
  payload ->> '$.attr.customer_tier' AS customer_tier,
  payload ->> '$.attr.retrieval_strategy' AS retrieval_strategy,
  COUNT(*) AS observations,
  AVG(latency_ms) AS avg_latency_ms,
  SUM(total_cost) AS total_cost
FROM __MO_TABLE__
WHERE type IN ('GENERATION', 'TOOL', 'RETRIEVAL')
GROUP BY
  payload ->> '$.attr.release_ring',
  payload ->> '$.attr.customer_tier',
  payload ->> '$.attr.retrieval_strategy'
ORDER BY observations DESC, total_cost DESC, release_ring ASC, customer_tier ASC, retrieval_strategy ASC
LIMIT 50;

-- Q13
SELECT
  COUNT(*) AS observations,
  COUNT(DISTINCT trace_id) AS traces,
  MAX(event_time) AS last_event_time
FROM __MO_TABLE__
WHERE biz_date BETWEEN CAST(__START_DATE__ AS DATE) AND CAST(__END_DATE__ AS DATE)
  AND tenant = __TENANT__
  AND type IN ('GENERATION', 'TOOL', 'RETRIEVAL', 'EVENT')
  AND (
    LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE '%timeout awaiting headers%'
    OR LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE '%retry budget depleted%'
    OR LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE '%transient upstream failure%'
  );

-- Q14
SELECT
  event_time,
  trace_id,
  observation_id,
  type,
  status,
  tool_name,
  output
FROM __MO_TABLE__
WHERE tenant = __TENANT__
  AND app = __APP__
  AND type IN ('GENERATION', 'TOOL', 'EVENT')
  AND (
    LOWER(IFNULL(input, '')) LIKE '%deployment%'
    OR LOWER(IFNULL(output, '')) LIKE '%deployment%'
    OR LOWER(IFNULL(input, '')) LIKE '%rollback%'
    OR LOWER(IFNULL(output, '')) LIKE '%rollback%'
    OR LOWER(IFNULL(output, '')) LIKE '%transient%'
  )
ORDER BY event_time DESC, trace_id DESC, observation_id DESC
LIMIT 50;

-- Q15
SELECT
  event_time,
  trace_id,
  observation_id,
  type,
  status,
  tool_name,
  latency_ms
FROM __MO_TABLE__
WHERE tenant = __TENANT__
  AND type IN ('GENERATION', 'TOOL', 'RETRIEVAL', 'EVENT')
  AND (
    LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE '%transient upstream failure%'
    OR LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE '%retry budget depleted%'
    OR LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE '%connector timeout%'
  )
ORDER BY latency_ms DESC, event_time DESC, trace_id DESC, observation_id DESC
LIMIT 50;

-- Q16
SELECT
  event_time,
  trace_id,
  observation_id,
  type,
  status,
  payload ->> '$.attr.release_ring' AS release_ring,
  payload ->> '$.attr.customer_tier' AS customer_tier,
  payload ->> '$.attr.traffic_cluster' AS traffic_cluster
FROM __MO_TABLE__
WHERE tenant = __TENANT__
  AND environment = 'prod'
  AND type IN ('GENERATION', 'TOOL', 'RETRIEVAL')
  AND payload ->> '$.attr.release_ring' = __RELEASE_RING__
  AND payload ->> '$.attr.customer_tier' = __CUSTOMER_TIER__
  AND payload ->> '$.attr.traffic_cluster' = __TRAFFIC_CLUSTER__
ORDER BY event_time DESC, trace_id DESC, observation_id DESC
LIMIT 50;

-- Q17
SELECT
  trace_id,
  observation_id,
  seq_no,
  type,
  status,
  payload ->> '$.attr.request_key' AS request_key,
  payload ->> '$.attr.workflow_variant' AS workflow_variant
FROM __MO_TABLE__
WHERE tenant = __TENANT__
  AND payload ->> '$.attr.request_key' = __REQUEST_KEY__
  AND payload ->> '$.attr.workflow_variant' = __WORKFLOW_VARIANT__
ORDER BY seq_no ASC, observation_id ASC
LIMIT 100;

-- Q18
SELECT
  payload ->> '$.attr.prompt_template_version' AS prompt_template_version,
  COUNT(*) AS observations,
  COUNT(DISTINCT trace_id) AS traces,
  AVG(latency_ms) AS avg_latency_ms,
  SUM(total_cost) AS total_cost
FROM __MO_TABLE__
WHERE type IN ('GENERATION', 'REASONING', 'TOOL')
GROUP BY payload ->> '$.attr.prompt_template_version'
ORDER BY observations DESC, total_cost DESC, prompt_template_version ASC
LIMIT 20;

-- Q19
SELECT
  payload ->> '$.attr.deployment_channel' AS deployment_channel,
  payload ->> '$.attr.release_ring' AS release_ring,
  COUNT(*) AS incident_observations,
  COUNT(DISTINCT trace_id) AS incident_traces,
  AVG(latency_ms) AS avg_latency_ms
FROM __MO_TABLE__
WHERE type IN ('GENERATION', 'TOOL', 'RETRIEVAL', 'EVENT')
  AND (
    LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE '%error%'
    OR LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE '%timeout%'
    OR LOWER(CONCAT(IFNULL(input, ''), ' ', IFNULL(output, ''))) LIKE '%retry%'
  )
GROUP BY payload ->> '$.attr.deployment_channel', payload ->> '$.attr.release_ring'
ORDER BY incident_observations DESC, incident_traces DESC, deployment_channel ASC, release_ring ASC
LIMIT 20;

-- Q20
SELECT
  payload ->> '$.attr.workflow_variant' AS workflow_variant,
  payload ->> '$.attr.policy_pack' AS policy_pack,
  COUNT(*) AS observations,
  COUNT(DISTINCT tenant) AS tenants,
  AVG(latency_ms) AS avg_latency_ms,
  SUM(total_cost) AS total_cost
FROM __MO_TABLE__
WHERE type IN ('GENERATION', 'TOOL', 'RETRIEVAL', 'REASONING')
GROUP BY payload ->> '$.attr.workflow_variant', payload ->> '$.attr.policy_pack'
ORDER BY observations DESC, total_cost DESC, workflow_variant ASC, policy_pack ASC
LIMIT 20;
