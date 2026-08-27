CREATE TRIGGER fail_batch_boundary
BEFORE INSERT ON epoch_snapshot_info
WHEN NEW.epoch_number = 0 AND NEW.input_number = 3
BEGIN
    SELECT RAISE(ABORT, 'injected boundary failure');
END;
