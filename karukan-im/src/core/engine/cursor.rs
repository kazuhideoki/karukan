//! Cursor movement and character deletion

use super::*;

impl InputMethodEngine {
    fn flush_romaji_preserving_display_caret(&mut self) {
        if self.converters.romaji.buffer().is_empty() {
            return;
        }
        let display_caret = self.display_caret_position();
        self.flush_romaji_to_composed();
        self.converters.romaji.reset();
        let total = self.input_buf.text.chars().count();
        self.input_buf.cursor_pos = display_caret.min(total);
    }

    /// Common helper for cursor movement: flush romaji, clear live conversion, set new display position
    fn move_caret_to_display_pos(&mut self, new_pos: usize) -> EngineResult {
        if !self.converters.romaji.buffer().is_empty() {
            self.flush_romaji_preserving_display_caret();
        }
        self.live.text.clear();
        // Cursor movement hides the auto-suggest window (below); drop the
        // stored list so a following Ctrl+1..9 can't commit a stale candidate.
        self.composing_candidates = None;
        self.input_buf.cursor_pos = new_pos;
        self.log_chunk_state("cursor");
        let preedit = self.set_composing_state();
        EngineResult::consumed()
            .with_action(EngineAction::UpdatePreedit(preedit))
            .with_action(EngineAction::HideCandidates)
            .with_action(EngineAction::UpdateAuxText(self.format_aux_composing()))
    }

    /// Handle backspace in composing mode
    pub(super) fn backspace_composing(&mut self) -> EngineResult {
        // If romaji buffer is not empty, backspace from buffer (not from composed text)
        if !self.converters.romaji.buffer().is_empty() {
            let backspace = self.converters.romaji.backspace();
            if self.converters.romaji.buffer().is_empty()
                && let Some(prev_ch) = self.input_buf.char_before_cursor()
                && let karukan_engine::BackspaceResult::RemovedBuffer(deleted_ch) = backspace
                && self
                    .converters
                    .romaji
                    .rebuffer_last_output_after_buffer_delete(deleted_ch, prev_ch)
            {
                self.input_buf.remove_char_before_cursor();
            }
            if let Some(result) = self.try_reset_if_empty() {
                return result;
            }

            let preedit = self.set_composing_state();
            return EngineResult::consumed()
                .with_action(EngineAction::UpdatePreedit(preedit))
                .with_action(EngineAction::UpdateAuxText(self.format_aux_composing()));
        }

        // Remove character before cursor from composed_hiragana
        if self.input_buf.cursor_pos > 0 {
            self.input_buf.remove_char_before_cursor();
        } else {
            // Nothing to delete
            return EngineResult::consumed();
        }

        if let Some(result) = self.try_reset_if_empty() {
            return result;
        }

        self.refresh_input_state()
    }

    /// Move caret left within hiragana input
    pub(super) fn move_caret_left(&mut self) -> EngineResult {
        let new_pos = self.display_caret_position().saturating_sub(1);
        self.move_caret_to_display_pos(new_pos)
    }

    /// Move caret right within hiragana input
    pub(super) fn move_caret_right(&mut self) -> EngineResult {
        let total = self.build_input_display().chars().count();
        let new_pos = (self.display_caret_position() + 1).min(total);
        self.move_caret_to_display_pos(new_pos)
    }

    /// Handle delete key in hiragana mode
    pub(super) fn delete_composing(&mut self) -> EngineResult {
        if !self.converters.romaji.buffer().is_empty() {
            self.flush_romaji_preserving_display_caret();
        }

        // Delete character at cursor position
        if self.input_buf.remove_char_at_cursor().is_none() {
            return EngineResult::consumed();
        }

        if let Some(result) = self.try_reset_if_empty() {
            return result;
        }

        self.refresh_input_state()
    }

    /// Move caret to start of input
    pub(super) fn move_caret_home(&mut self) -> EngineResult {
        self.move_caret_to_display_pos(0)
    }

    /// Move caret to end of input
    pub(super) fn move_caret_end(&mut self) -> EngineResult {
        let total = self.build_input_display().chars().count();
        self.move_caret_to_display_pos(total)
    }
}
