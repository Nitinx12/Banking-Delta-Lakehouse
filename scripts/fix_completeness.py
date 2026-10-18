src = open(r"tests\data-quality\raw\08_lp_check_completeness.sql").read()
s = src
s = s.replace("audit.dq_raw_completeness", "audit.dq_staging_completeness")
s = s.replace("v_schema   CONSTANT TEXT   := 'raw';", "v_schema   CONSTANT TEXT   := 'staging';")
s = s.replace("'raw', '08_lp_check_completeness.sql'", "'staging', '08_lp_check_completeness.sql'")
s = s.replace("raw schema", "staging schema")
s = s.replace("v_meta_cols CONSTANT TEXT[] := ARRAY['_batch_id', '_loaded_at'];", "v_meta_cols CONSTANT TEXT[] := ARRAY['source_batch_id', 'source_loaded_at', 'row_added_at', 'row_updated_at'];")
# add exempt var and null_ok
s = s.replace("    v_null_ok  CONSTANT TEXT[] := ARRAY[]::TEXT[];  -- table.column allowed to be NULL",
              "    v_exempt_tables CONSTANT TEXT[] := ARRAY['scd1_history']::TEXT[];\n    v_null_ok  CONSTANT TEXT[] := ARRAY['cards.credit_limit']::TEXT[];  -- table.column allowed to be NULL")
# exempt filter in loop
s = s.replace("          AND NOT c.relispartition\n        ORDER BY c.relname",
              "          AND NOT c.relispartition\n          AND c.relname <> ALL (v_exempt_tables)\n        ORDER BY c.relname")
open(r"tests\data-quality\staging\08_lp_check_completeness.sql", "w").write(s)
print("ok")