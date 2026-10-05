-- Runs once, when the database volume is created: the app keeps its job queue, cache and
-- WebSocket messages in three more databases next to the main one (CYRA-919).
CREATE DATABASE closeyourit_queue OWNER closeyourit;
CREATE DATABASE closeyourit_cache OWNER closeyourit;
CREATE DATABASE closeyourit_cable OWNER closeyourit;
