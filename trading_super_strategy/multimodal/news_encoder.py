"""Provider-neutral contract for financial text encoders.

FinBERT (or another finance-domain encoder) should implement this interface.
The encoder produces embeddings only; it is explicitly forbidden from emitting
BUY/SELL decisions on its own.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, Sequence

import numpy as np


@dataclass(frozen=True)
class EncoderInfo:
    model_id: str
    model_version: str
    embedding_dim: int
    domain: str = "finance"


class FinancialTextEncoder(Protocol):
    info: EncoderInfo

    def encode(self, texts: Sequence[str]) -> np.ndarray:
        """Return [n_texts, embedding_dim] point embeddings."""
        ...


def validate_embeddings(matrix: np.ndarray, info: EncoderInfo) -> np.ndarray:
    arr = np.asarray(matrix, dtype=float)
    if arr.ndim != 2 or arr.shape[1] != info.embedding_dim:
        raise ValueError("encoder output has unexpected shape")
    if not np.isfinite(arr).all():
        raise ValueError("encoder output contains non-finite values")
    return arr
