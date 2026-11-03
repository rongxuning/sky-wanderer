DO $$
DECLARE
  constraint_name text;
BEGIN
  FOR constraint_name IN
    SELECT c.conname
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    WHERE t.relname = 'identities'
      AND t.relnamespace = current_schema()::regnamespace
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%wechat%'
      AND pg_get_constraintdef(c.oid) NOT ILIKE '%email%'
  LOOP
    EXECUTE format('ALTER TABLE identities DROP CONSTRAINT %I', constraint_name);
  END LOOP;
END
$$;

ALTER TABLE identities
  ADD CONSTRAINT identities_type_check
  CHECK (type IN ('phone', 'wechat', 'google', 'email'));

ALTER TABLE identities
  ADD COLUMN IF NOT EXISTS password_hash text NOT NULL DEFAULT '';
