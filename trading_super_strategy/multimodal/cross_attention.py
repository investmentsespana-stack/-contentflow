"""Causal cross-attention between market state and point-in-time news.

This is an executable identity-projection attention block for research/shadow
use. It does NOT contain trained projection matrices and must not route live
orders. A trained/calibrated model can later replace the identity projections
behind the same interface.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from math import sqrt
from typing import Iterable

import numpy as np

from .timestamp_guard import NewsEvent, PointInTimeNewsGuard


@dataclass(frozen=True)
class AttentionResult:
    status: str
    decision_time: datetime
    context_vector: np.ndarray
    event_ids: tuple[str, ...]
    attention_weights: tuple[float, ...]
    encoder_model_ids: tuple[str, ...]


def _softmax(values: np.ndarray) -> np.ndarray:
    shifted = values - np.max(values)
    exp = np.exp(shifted)
    total = float(np.sum(exp))
    if total <= 0 or not np.isfinite(total):
        raise ValueError("invalid attention normalization")
    return exp / total


class CrossAttentionContextEngine:
    """Market-query/news-key-value attention, point-in-time and shadow-only."""

    STATUS = "SHADOW_ONLY_UNTRAINED_IDENTITY_PROJECTIONS"

    def attend(
        self,
        market_embedding: np.ndarray,
        events: Iterable[NewsEvent],
        *,
        decision_time: datetime,
    ) -> AttentionResult:
        query = np.asarray(market_embedding, dtype=float).reshape(-1)
        if query.size == 0 or not np.isfinite(query).all():
            raise ValueError("market_embedding must be a finite non-empty vector")

        visible = PointInTimeNewsGuard.visible(events, decision_time)
        if not visible:
            return AttentionResult(
                status=self.STATUS,
                decision_time=decision_time,
                context_vector=np.zeros_like(query),
                event_ids=(),
                attention_weights=(),
                encoder_model_ids=(),
            )

        keys = np.vstack([np.asarray(e.embedding, dtype=float).reshape(-1) for e in visible])
        if keys.shape[1] != query.size:
            raise ValueError("market/news embedding dimensions must match in identity mode")
        if not np.isfinite(keys).all():
            raise ValueError("news embeddings contain non-finite values")

        logits = keys @ query / sqrt(float(query.size))
        weights = _softmax(logits)
        context = weights @ keys
        return AttentionResult(
            status=self.STATUS,
            decision_time=decision_time,
            context_vector=context,
            event_ids=tuple(e.event_id for e in visible),
            attention_weights=tuple(float(x) for x in weights),
            encoder_model_ids=tuple(e.encoder_model_id for e in visible),
        )
