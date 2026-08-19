use super::*;

// --- Candidate preservation tests ---

#[test]
fn test_live_text_preserved_in_conversion_via_down() {
    // When DOWN is pressed during live conversion, the AI inference result
    // (live_conversion_text) should appear in the candidate list.
    let mut engine = make_live_conversion_engine();

    // Simulate typing "あい" with live conversion active
    engine.process_key(&press('a'));
    engine.process_key(&press('i'));
    set_live_text(&mut engine, "愛");

    // Press DOWN → start_conversion()
    let result = engine.process_key(&press_key(Keysym::DOWN));
    assert!(result.consumed);
    assert!(matches!(engine.state(), InputState::Conversion { .. }));

    // The candidate list should contain "愛"
    let candidates = engine.state().candidates().unwrap();
    assert!(
        candidates.candidates().iter().any(|c| c.text == "愛"),
        "AI inference result '愛' should be in the candidate list"
    );
}

#[test]
fn test_live_text_not_duplicated_in_conversion() {
    // If the live_text matches the reading, it should not be duplicated
    let mut engine = make_live_conversion_engine();

    engine.process_key(&press('a'));
    engine.process_key(&press('i'));
    // live_conversion_text same as hiragana reading → should not be added
    set_live_text(&mut engine, "あい");

    let result = engine.process_key(&press_key(Keysym::DOWN));
    assert!(result.consumed);
    assert!(matches!(engine.state(), InputState::Conversion { .. }));

    // "あい" should not appear twice (it's same as reading, so live_text is skipped)
    let candidates = engine.state().candidates().unwrap();
    let count = candidates
        .candidates()
        .iter()
        .filter(|c| c.text == "あい")
        .count();
    assert_eq!(count, 1, "Reading should appear exactly once");
}

#[test]
fn test_suggest_result_preserved_in_start_conversion() {
    // When Space is pressed, the previous auto-suggest/live conversion result
    // should be preserved in the candidate list even if re-inference doesn't produce it.
    // (Without a kanji converter, build_conversion_candidates returns fallback only,
    // so the live_conversion_text would be lost without the preservation logic.)
    let mut engine = InputMethodEngine::new();

    engine.process_key(&press('a'));
    engine.process_key(&press('i'));
    set_live_text(&mut engine, "愛");

    // Press Space → start_conversion()
    let result = engine.process_key(&press_key(Keysym::SPACE));
    assert!(result.consumed);
    assert!(matches!(engine.state(), InputState::Conversion { .. }));

    // "愛" should be preserved in the candidate list
    let candidates = engine.state().candidates().unwrap();
    assert!(
        candidates.candidates().iter().any(|c| c.text == "愛"),
        "Previous suggest result '愛' should be preserved in candidates"
    );
}

#[test]
fn test_empty_live_text_not_added_to_candidates() {
    // When live_conversion_text is empty, no extra candidate should be added
    let mut engine = make_live_conversion_engine();

    engine.process_key(&press('a'));
    engine.process_key(&press('i'));
    // Force empty to test the "no live text" scenario
    engine.live.shown = false;

    // DOWN → start_conversion()
    let result = engine.process_key(&press_key(Keysym::DOWN));
    assert!(result.consumed);

    // Should have candidates but no empty-string candidate
    if let Some(candidates) = engine.state().candidates() {
        assert!(
            !candidates.candidates().iter().any(|c| c.text.is_empty()),
            "Empty candidate should not be in the list"
        );
    }
}

#[test]
fn test_space_preserves_displayed_composing_candidate_order() {
    let mut engine = InputMethodEngine::new();
    engine.input_buf.insert("こん");
    engine.state = InputState::Composing {
        preedit: Preedit::with_text_underlined("こん"),
    };
    engine.shown_suggestions = CandidateList::new(vec![
        Candidate::with_reading("こん", "こん"),
        Candidate::with_reading("コン", "こん"),
        Candidate::with_reading("今回の", "こん"),
        Candidate::with_reading("KON", "こん"),
    ]);

    let result = engine.process_key(&press_key(Keysym::SPACE));
    assert!(result.consumed);
    assert!(matches!(engine.state(), InputState::Conversion { .. }));

    let texts: Vec<String> = engine
        .state()
        .candidates()
        .unwrap()
        .candidates()
        .iter()
        .map(|c| c.text.clone())
        .collect();
    assert_eq!(
        &texts[..4],
        ["こん", "コン", "今回の", "KON"],
        "Space must keep the composing candidate order at the top, got {:?}",
        texts
    );
}

#[test]
fn test_down_preserves_displayed_composing_candidate_order() {
    let mut engine = InputMethodEngine::new();
    engine.input_buf.insert("こん");
    engine.state = InputState::Composing {
        preedit: Preedit::with_text_underlined("こん"),
    };
    engine.shown_suggestions = CandidateList::new(vec![
        Candidate::with_reading("こん", "こん"),
        Candidate::with_reading("コン", "こん"),
        Candidate::with_reading("今回の", "こん"),
    ]);

    let result = engine.process_key(&press_key(Keysym::DOWN));
    assert!(result.consumed);
    assert!(matches!(engine.state(), InputState::Conversion { .. }));

    let texts: Vec<String> = engine
        .state()
        .candidates()
        .unwrap()
        .candidates()
        .iter()
        .map(|c| c.text.clone())
        .collect();
    assert_eq!(
        &texts[..3],
        ["こん", "コン", "今回の"],
        "Down must keep the composing candidate order at the top, got {:?}",
        texts
    );
}

#[test]
fn test_tab_does_not_preserve_displayed_composing_candidates() {
    let mut engine = InputMethodEngine::new();
    engine.input_buf.insert("あい");
    engine.state = InputState::Composing {
        preedit: Preedit::with_text_underlined("あい"),
    };
    engine.shown_suggestions =
        CandidateList::new(vec![Candidate::with_reading("表示中だけの候補", "あい")]);

    let result = engine.process_key(&press_key(Keysym::TAB));
    assert!(result.consumed);
    assert!(matches!(engine.state(), InputState::Conversion { .. }));
    assert!(engine.shown_suggestions.is_empty());

    let texts: Vec<String> = engine
        .state()
        .candidates()
        .unwrap()
        .candidates()
        .iter()
        .map(|c| c.text.clone())
        .collect();
    assert!(
        !texts.contains(&"表示中だけの候補".to_string()),
        "Tab should keep using the regenerated learning-skipping conversion list, got {:?}",
        texts
    );
}
