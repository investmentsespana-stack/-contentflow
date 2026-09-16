from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timezone, tzinfo
import json
from typing import Any, Callable, Iterable, Mapping, Sequence
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .backtest_engine import Bar


SUPPORTED_FUTURES = ("ES", "NQ", "YM", "RTY")
SUPPORTED_YFINANCE_INTERVALS = (
    "1m", "2m", "5m", "15m", "30m", "60m", "90m", "1h", "1d", "5d", "1W", "1M", "1Q"
)
OPENBB_FUTURES_HISTORY_PATH = "/api/v1/derivatives/futures/historical"


class OpenBBHistoryError(RuntimeError):
    """Raised when OpenBB data cannot be accepted safely."""


@dataclass(frozen=True)
class OpenBBFetchStats:
    symbol: str
    provider: str
    interval: str
    transport: str
    source_rows: int
    output_bars: int
    missing_volume_rows: int
    first_timestamp: datetime
    last_timestamp: datetime


def _validate_request(symbol: str, interval: str, provider: str) -> tuple[str, str, str]:
    normalized_symbol = symbol.strip().upper()
    if normalized_symbol not in SUPPORTED_FUTURES:
        raise ValueError(f"unsupported futures root: {symbol}; expected one of {SUPPORTED_FUTURES}")
    if provider != "yfinance":
        raise ValueError("OpenBB free-data v1 is intentionally pinned to provider='yfinance'")
    if interval not in SUPPORTED_YFINANCE_INTERVALS:
        raise ValueError(f"unsupported yfinance interval: {interval}")
    return normalized_symbol, interval, provider


def _get(record: Any, key: str) -> Any:
    if isinstance(record, Mapping):
        return record.get(key)
    if hasattr(record, key):
        return getattr(record, key)
    if hasattr(record, "model_dump"):
        return record.model_dump().get(key)
    if hasattr(record, "dict"):
        return record.dict().get(key)
    return None


def _parse_timestamp(value: Any, *, naive_timezone: tzinfo | None) -> datetime:
    if isinstance(value, datetime):
        dt = value
    elif isinstance(value, date):
        dt = datetime(value.year, value.month, value.day, tzinfo=timezone.utc)
    elif isinstance(value, str):
        text = value.strip()
        if not text:
            raise OpenBBHistoryError("OpenBB row has an empty date")
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            dt = datetime.fromisoformat(text)
        except ValueError:
            try:
                parsed_date = date.fromisoformat(text)
            except ValueError as exc:
                raise OpenBBHistoryError(f"unsupported OpenBB date format: {value!r}") from exc
            dt = datetime(parsed_date.year, parsed_date.month, parsed_date.day, tzinfo=timezone.utc)
    else:
        raise OpenBBHistoryError(f"OpenBB row has unsupported date type: {type(value).__name__}")

    if dt.tzinfo is None:
        if naive_timezone is None:
            raise OpenBBHistoryError(
                "OpenBB returned a timezone-naive intraday timestamp; provide naive_timezone explicitly rather than guessing"
            )
        dt = dt.replace(tzinfo=naive_timezone)
    return dt.astimezone(timezone.utc)


def normalize_openbb_results(
    results: Iterable[Any],
    *,
    symbol: str,
    interval: str,
    provider: str = "yfinance",
    transport: str = "python",
    naive_timezone: tzinfo | None = None,
) -> tuple[list[Bar], OpenBBFetchStats]:
    symbol, interval, provider = _validate_request(symbol, interval, provider)
    rows = list(results)
    if not rows:
        raise OpenBBHistoryError(f"OpenBB returned no rows for {symbol}")

    parsed: list[Bar] = []
    missing_volume = 0
    for index, row in enumerate(rows, start=1):
        ts = _parse_timestamp(_get(row, "date"), naive_timezone=naive_timezone)
        try:
            open_ = float(_get(row, "open"))
            high = float(_get(row, "high"))
            low = float(_get(row, "low"))
            close = float(_get(row, "close"))
        except (TypeError, ValueError) as exc:
            raise OpenBBHistoryError(f"OpenBB row {index} has missing/invalid OHLC") from exc

        raw_volume = _get(row, "volume")
        if raw_volume is None:
            volume = 0.0
            missing_volume += 1
        else:
            try:
                volume = float(raw_volume)
            except (TypeError, ValueError) as exc:
                raise OpenBBHistoryError(f"OpenBB row {index} has invalid volume") from exc

        bar = Bar(timestamp=ts, open=open_, high=high, low=low, close=close, volume=volume)
        reason = bar.validate()
        if reason is not None:
            raise OpenBBHistoryError(f"OpenBB row {index} failed OHLCV validation: {reason}")
        parsed.append(bar)

    # Providers do not all guarantee output ordering. Sorting is safe because each
    # row is a closed historical observation; duplicate timestamps are not safe.
    parsed.sort(key=lambda item: item.timestamp)
    for i in range(1, len(parsed)):
        if parsed[i].timestamp == parsed[i - 1].timestamp:
            raise OpenBBHistoryError(f"duplicate OpenBB timestamp: {parsed[i].timestamp.isoformat()}")

    return parsed, OpenBBFetchStats(
        symbol=symbol,
        provider=provider,
        interval=interval,
        transport=transport,
        source_rows=len(rows),
        output_bars=len(parsed),
        missing_volume_rows=missing_volume,
        first_timestamp=parsed[0].timestamp,
        last_timestamp=parsed[-1].timestamp,
    )


def _load_default_openbb_client() -> Any:
    try:
        from openbb import obb  # type: ignore
    except ImportError as exc:
        raise OpenBBHistoryError(
            "OpenBB Python package is not installed. Install OpenBB/BB-Terminal or use transport='http' against its local API."
        ) from exc
    return obb


def fetch_openbb_python(
    *,
    symbol: str,
    interval: str = "15m",
    start_date: str | date | None = None,
    end_date: str | date | None = None,
    provider: str = "yfinance",
    client: Any | None = None,
    naive_timezone: tzinfo | None = None,
) -> tuple[list[Bar], OpenBBFetchStats]:
    symbol, interval, provider = _validate_request(symbol, interval, provider)
    obb = client if client is not None else _load_default_openbb_client()
    kwargs: dict[str, Any] = {
        "symbol": symbol,
        "interval": interval,
        "provider": provider,
    }
    if start_date is not None:
        kwargs["start_date"] = start_date
    if end_date is not None:
        kwargs["end_date"] = end_date

    try:
        response = obb.derivatives.futures.historical(**kwargs)
    except Exception as exc:
        raise OpenBBHistoryError(f"OpenBB Python request failed for {symbol}: {exc}") from exc

    results = getattr(response, "results", None)
    if results is None and isinstance(response, Mapping):
        results = response.get("results")
    actual_provider = getattr(response, "provider", None)
    if actual_provider is None and isinstance(response, Mapping):
        actual_provider = response.get("provider")
    if actual_provider not in (None, provider):
        raise OpenBBHistoryError(f"provider mismatch: requested {provider}, received {actual_provider}")

    return normalize_openbb_results(
        results or (),
        symbol=symbol,
        interval=interval,
        provider=provider,
        transport="python",
        naive_timezone=naive_timezone,
    )


def _default_http_get(url: str, timeout_seconds: float) -> Mapping[str, Any]:
    request = Request(url, headers={"Accept": "application/json", "User-Agent": "super-estrategia-openbb-v1"})
    try:
        with urlopen(request, timeout=timeout_seconds) as response:  # nosec B310 - URL is locally/configurably scoped by caller
            payload = response.read().decode("utf-8")
    except Exception as exc:
        raise OpenBBHistoryError(f"OpenBB HTTP request failed: {exc}") from exc
    try:
        decoded = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise OpenBBHistoryError("OpenBB HTTP response was not valid JSON") from exc
    if not isinstance(decoded, Mapping):
        raise OpenBBHistoryError("OpenBB HTTP response must be a JSON object")
    return decoded


def fetch_openbb_http(
    *,
    symbol: str,
    interval: str = "15m",
    start_date: str | date | None = None,
    end_date: str | date | None = None,
    provider: str = "yfinance",
    base_url: str = "http://127.0.0.1:6900",
    timeout_seconds: float = 20.0,
    http_get: Callable[[str, float], Mapping[str, Any]] | None = None,
    naive_timezone: tzinfo | None = None,
) -> tuple[list[Bar], OpenBBFetchStats]:
    symbol, interval, provider = _validate_request(symbol, interval, provider)
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    params: dict[str, str] = {"symbol": symbol, "interval": interval, "provider": provider}
    if start_date is not None:
        params["start_date"] = str(start_date)
    if end_date is not None:
        params["end_date"] = str(end_date)
    url = base_url.rstrip("/") + OPENBB_FUTURES_HISTORY_PATH + "?" + urlencode(params)
    getter = http_get or _default_http_get
    payload = getter(url, timeout_seconds)
    results = payload.get("results")
    actual_provider = payload.get("provider")
    if actual_provider not in (None, provider):
        raise OpenBBHistoryError(f"provider mismatch: requested {provider}, received {actual_provider}")
    return normalize_openbb_results(
        results or (),
        symbol=symbol,
        interval=interval,
        provider=provider,
        transport="http",
        naive_timezone=naive_timezone,
    )


def fetch_openbb_futures(
    *,
    symbol: str,
    interval: str = "15m",
    start_date: str | date | None = None,
    end_date: str | date | None = None,
    provider: str = "yfinance",
    transport: str = "python",
    client: Any | None = None,
    base_url: str = "http://127.0.0.1:6900",
    timeout_seconds: float = 20.0,
    http_get: Callable[[str, float], Mapping[str, Any]] | None = None,
    naive_timezone: tzinfo | None = None,
) -> tuple[list[Bar], OpenBBFetchStats]:
    if transport == "python":
        return fetch_openbb_python(
            symbol=symbol,
            interval=interval,
            start_date=start_date,
            end_date=end_date,
            provider=provider,
            client=client,
            naive_timezone=naive_timezone,
        )
    if transport == "http":
        return fetch_openbb_http(
            symbol=symbol,
            interval=interval,
            start_date=start_date,
            end_date=end_date,
            provider=provider,
            base_url=base_url,
            timeout_seconds=timeout_seconds,
            http_get=http_get,
            naive_timezone=naive_timezone,
        )
    raise ValueError("transport must be 'python' or 'http'")


def bars_to_ohlcv_rows(bars: Sequence[Bar]) -> list[dict[str, Any]]:
    """Provider-neutral bridge for legacy/frozen strategy loaders.

    R1/R2/R3 consume Bar directly. Frozen pandas/CSV strategies can consume
    these records without changing their trading rules.
    """
    rows: list[dict[str, Any]] = []
    previous: datetime | None = None
    for index, bar in enumerate(bars, start=1):
        reason = bar.validate()
        if reason is not None:
            raise ValueError(f"bar {index}: {reason}")
        if previous is not None and bar.timestamp <= previous:
            raise ValueError("bars must be strictly increasing")
        previous = bar.timestamp
        rows.append(
            {
                "timestamp": bar.timestamp.isoformat(),
                "open": bar.open,
                "high": bar.high,
                "low": bar.low,
                "close": bar.close,
                "volume": bar.volume,
            }
        )
    return rows
