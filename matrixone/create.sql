DROP TABLE IF EXISTS __MO_TABLE__;

CREATE TABLE __MO_TABLE__ (
    event_time DATETIME NOT NULL,
    biz_date DATE NOT NULL,
    trace_id VARCHAR(128) NOT NULL,
    session_id VARCHAR(128) NOT NULL,
    observation_id VARCHAR(128) NOT NULL,
    parent_observation_id VARCHAR(128),
    seq_no INT NOT NULL,
    type VARCHAR(64) NOT NULL,
    status VARCHAR(64) NOT NULL,
    tenant VARCHAR(128) NOT NULL,
    app VARCHAR(128) NOT NULL,
    environment VARCHAR(64) NOT NULL,
    task_category VARCHAR(128) NOT NULL,
    trace_archetype VARCHAR(128) NOT NULL,
    model VARCHAR(128) NOT NULL,
    tool_name VARCHAR(256),
    input TEXT,
    output TEXT,
    input_tokens BIGINT NOT NULL,
    output_tokens BIGINT NOT NULL,
    total_cost DOUBLE NOT NULL,
    latency_ms INT NOT NULL,
    payload JSON NOT NULL,
    PRIMARY KEY (trace_id, seq_no, observation_id)
);
