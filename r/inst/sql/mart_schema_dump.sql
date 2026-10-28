-- Dump mart columns from information_schema.
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'marts' AND table_name = '{mart}'
ORDER BY ordinal_position;
