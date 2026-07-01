use super::*;

#[test]
fn test_conversion_char_commits_and_continues() {
    let mut engine = InputMethodEngine::new();

    // Type "あい" and enter conversion
    engine.process_key(&press('a'));
    engine.process_key(&press('i'));
    engine.process_key(&press_key(Keysym::SPACE));
    assert!(matches!(engine.state(), InputState::Conversion { .. }));

    // Type 'k' during conversion → should commit candidate and start new input
    let result = engine.process_key(&press('k'));
    assert!(result.consumed);

    // Should have committed the conversion
    let has_commit = result
        .actions
        .iter()
        .any(|a| matches!(a, EngineAction::Commit(_)));
    assert!(has_commit, "Should have a commit action");

    // Should now be in Composing with 'k' in preedit
    assert!(matches!(engine.state(), InputState::Composing { .. }));
    assert_eq!(engine.preedit().unwrap().text(), "k");
}

#[test]
fn test_conversion_char_commits_and_continues_romaji() {
    let mut engine = InputMethodEngine::new();

    // Type "あ" and enter conversion
    engine.process_key(&press('a'));
    engine.process_key(&press_key(Keysym::SPACE));
    assert!(matches!(engine.state(), InputState::Conversion { .. }));

    // Type 'k', 'a' → commits conversion, then starts "か"
    engine.process_key(&press('k'));
    assert!(matches!(engine.state(), InputState::Composing { .. }));
    assert_eq!(engine.preedit().unwrap().text(), "k");

    engine.process_key(&press('a'));
    assert_eq!(engine.preedit().unwrap().text(), "か");
}

#[test]
fn test_conversion_ctrl_n_p_moves_conversion_cursor() {
    let mut engine = InputMethodEngine::new();

    engine.process_key(&press('a'));
    engine.process_key(&press_key(Keysym::SPACE));
    assert!(matches!(engine.state(), InputState::Conversion { .. }));

    let candidates = engine.state().candidates().unwrap();
    assert!(candidates.len() >= 2);
    assert_eq!(candidates.cursor(), 0);

    let result = engine.process_key(&press_ctrl(Keysym::KEY_N));
    assert!(result.consumed);
    assert_eq!(engine.state().candidates().unwrap().cursor(), 1);

    let result = engine.process_key(&press_ctrl(Keysym::KEY_P));
    assert!(result.consumed);
    assert_eq!(engine.state().candidates().unwrap().cursor(), 0);
}

#[test]
fn test_composing_ctrl_n_enters_conversion_and_moves_cursor() {
    let mut engine = InputMethodEngine::new();

    engine.process_key(&press('a'));
    assert!(matches!(engine.state(), InputState::Composing { .. }));

    let result = engine.process_key(&press_ctrl(Keysym::KEY_N));
    assert!(result.consumed);

    let candidates = engine.state().candidates().unwrap();
    assert!(candidates.len() >= 2);
    assert_eq!(candidates.cursor(), 1);
}

#[test]
fn test_composing_ctrl_p_enters_conversion_and_moves_cursor_to_previous() {
    let mut engine = InputMethodEngine::new();

    engine.process_key(&press('a'));
    assert!(matches!(engine.state(), InputState::Composing { .. }));

    let result = engine.process_key(&press_ctrl(Keysym::KEY_P));
    assert!(result.consumed);

    let candidates = engine.state().candidates().unwrap();
    assert!(candidates.len() >= 2);
    assert_eq!(candidates.cursor(), candidates.len() - 1);
}

#[test]
fn test_composing_ctrl_digit_commits_shown_auto_suggest_candidate() {
    let mut engine = InputMethodEngine::new();

    // Put the engine in Composing with a known auto-suggest candidate list,
    // mirroring what refresh_input_state stores while the suggest window shows.
    engine.input_buf.insert("でぃ");
    engine.state = InputState::Composing {
        preedit: Preedit::with_text_underlined("でぃ"),
        romaji_buffer: String::new(),
    };
    engine.composing_candidates = Some(CandidateList::new(vec![
        Candidate::with_reading("ディ", "でぃ"),
        Candidate::with_reading("ディレクトリ", "でぃ"),
        Candidate::with_reading("ディレ", "でぃ"),
    ]));

    // Ctrl+2 commits exactly the second shown candidate.
    let result = engine.process_key(&press_ctrl(Keysym::KEY_2));
    assert!(result.consumed);
    let committed = result.actions.iter().find_map(|a| match a {
        EngineAction::Commit(t) => Some(t.clone()),
        _ => None,
    });
    assert_eq!(committed.as_deref(), Some("ディレクトリ"));
    assert!(matches!(engine.state(), InputState::Empty));
    assert!(engine.composing_candidates.is_none());
    assert!(
        result
            .actions
            .iter()
            .any(|a| matches!(a, EngineAction::HideCandidates))
    );
}

#[test]
fn test_composing_ctrl_digit_out_of_range_is_swallowed() {
    let mut engine = InputMethodEngine::new();
    engine.input_buf.insert("あ");
    engine.state = InputState::Composing {
        preedit: Preedit::with_text_underlined("あ"),
        romaji_buffer: String::new(),
    };
    engine.composing_candidates = Some(CandidateList::new(vec![Candidate::with_reading(
        "あ", "あ",
    )]));

    // Ctrl+5 has no candidate at that position: swallow the key (don't leak a
    // literal '5' into the buffer) but commit nothing and stay composing.
    let result = engine.process_key(&press_ctrl(Keysym::KEY_5));
    assert!(result.consumed);
    assert!(
        !result
            .actions
            .iter()
            .any(|a| matches!(a, EngineAction::Commit(_)))
    );
    assert!(matches!(engine.state(), InputState::Composing { .. }));
}

#[test]
fn test_composing_ctrl_digit_without_candidates_is_not_consumed() {
    let mut engine = InputMethodEngine::new();
    engine.input_buf.insert("あ");
    engine.state = InputState::Composing {
        preedit: Preedit::with_text_underlined("あ"),
        romaji_buffer: String::new(),
    };
    engine.composing_candidates = None;

    let result = engine.process_key(&press_ctrl(Keysym::KEY_1));
    assert!(!result.consumed);
}

#[test]
fn test_composing_ctrl_alt_digit_is_not_consumed() {
    // Alt/Super must be clear for the Ctrl+digit binding to fire, so platform
    // shortcuts (e.g. macOS Command combos) aren't swallowed.
    let mut engine = InputMethodEngine::new();
    engine.input_buf.insert("あ");
    engine.state = InputState::Composing {
        preedit: Preedit::with_text_underlined("あ"),
        romaji_buffer: String::new(),
    };
    engine.composing_candidates = Some(CandidateList::new(vec![Candidate::with_reading(
        "亜", "あ",
    )]));

    let mut key = press_ctrl(Keysym::KEY_1);
    key.modifiers.alt_key = true;
    let result = engine.process_key(&key);
    assert!(!result.consumed);
    // The stored list is untouched and nothing was committed.
    assert!(matches!(engine.state(), InputState::Composing { .. }));
    assert!(engine.composing_candidates.is_some());
}

#[test]
fn test_composing_suggest_stores_displayed_list() {
    let mut engine = InputMethodEngine::new();
    let result = engine.process_key(&press('a'));

    let shown = result.actions.iter().find_map(|a| match a {
        EngineAction::ShowCandidates(list) => Some(list.clone()),
        _ => None,
    });
    match shown {
        Some(shown) => {
            let stored = engine
                .composing_candidates
                .as_ref()
                .expect("shown candidates must be stored for Ctrl+1..9");
            assert_eq!(stored.len(), shown.len());
        }
        None => assert!(engine.composing_candidates.is_none()),
    }
}

#[test]
fn test_cursor_move_clears_stored_suggest_candidates() {
    let mut engine = InputMethodEngine::new();
    engine.input_buf.insert("あい");
    engine.input_buf.cursor_pos = 2;
    engine.state = InputState::Composing {
        preedit: Preedit::with_text_underlined("あい"),
        romaji_buffer: String::new(),
    };
    engine.composing_candidates = Some(CandidateList::new(vec![Candidate::with_reading(
        "愛", "あい",
    )]));

    // Ctrl+B moves the caret left, which hides the suggest window; the stored
    // list must be dropped so a following Ctrl+1..9 can't commit it stale.
    engine.process_key(&press_ctrl(Keysym::KEY_B));
    assert!(engine.composing_candidates.is_none());
}

#[test]
fn test_alphabet_mode_space_inserts_literal_space() {
    let mut engine = InputMethodEngine::new();

    // Enter alphabet mode via Shift+N
    engine.process_key(&press_shift('N'));
    assert!(engine.input_mode == InputMode::Alphabet);

    // Type "ew"
    engine.process_key(&press('e'));
    engine.process_key(&press('w'));
    assert_eq!(engine.preedit().unwrap().text(), "New");

    // Space → should insert literal space, NOT start conversion
    engine.process_key(&press_key(Keysym::SPACE));
    assert!(matches!(engine.state(), InputState::Composing { .. }));
    assert_eq!(engine.preedit().unwrap().text(), "New ");

    // Type "york"
    engine.process_key(&press('y'));
    engine.process_key(&press('o'));
    engine.process_key(&press('r'));
    engine.process_key(&press('k'));
    assert_eq!(engine.preedit().unwrap().text(), "New york");
}
