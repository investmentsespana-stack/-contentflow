from src.shared.contentflow_evidence_checker import has_evidence

# CI observability probe: changing this test path must trigger targeted-evidence-wave3.


def test_empty_output_is_false():
    assert has_evidence({}) is False


def test_partial_evidence_is_true():
    assert has_evidence({"metadata": {"source": "x"}}) is True


def test_full_evidence_is_true():
    assert has_evidence({
        "extracted_text": "text",
        "structured_data": {"a": 1},
        "metadata": {"source": "x"},
        "annotations": ["ok"],
        "validation_results": {"pass": True},
        "source_references": ["ref"],
    }) is True


def test_malformed_or_empty_values_are_false():
    assert has_evidence({"metadata": {}, "extracted_text": "   ", "annotations": []}) is False
