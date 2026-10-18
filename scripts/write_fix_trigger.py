sql = r"""CREATE OR REPLACE FUNCTION audit.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    NEW.row_updated_at := clock_timestamp();
    RETURN NEW;
END
$fn$;"""
open(r"C:\Users\91852\AppData\Local\Temp\opencode\fix_trigger.sql", "w").write(sql)
print("ok")