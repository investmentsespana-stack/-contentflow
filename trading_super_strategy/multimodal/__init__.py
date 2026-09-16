"""Point-in-time price/news fusion components (shadow/research only)."""

from .cross_attention import AttentionResult, CrossAttentionContextEngine
from .timestamp_guard import NewsEvent, PointInTimeNewsGuard

__all__ = ["AttentionResult", "CrossAttentionContextEngine", "NewsEvent", "PointInTimeNewsGuard"]
