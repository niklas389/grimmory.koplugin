-- Lookups by Grimmory ID (every book of a sync) and a book's reading
-- sessions and events (its progress, what is left to send)
CREATE INDEX IF NOT EXISTS book_grimmory_id ON book (grimmory_id);
CREATE INDEX IF NOT EXISTS book_session_book_id ON book_session (book_id);
CREATE INDEX IF NOT EXISTS book_event_session_id ON book_event (session_id);
