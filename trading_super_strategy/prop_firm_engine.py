from dataclasses import dataclass, replace
from typing import Optional, Tuple


@dataclass(frozen=True)
class PropFirmProfile:
    profile_id: str
    firm: str
    plan: str
    phase: str
    consistency_pct: Optional[float] = None
    profit_target: Optional[float] = None
    max_loss_type: str = "none"  # none | static | eod_trailing | intraday_trailing
    max_loss_distance: Optional[float] = None
    daily_loss_limit: Optional[float] = None
    minimum_trading_days: int = 0
    minimum_winning_days: int = 0
    winning_day_threshold: float = 0.0
    payout_buffer: float = 0.0
    contract_limit: Optional[int] = None
    news_restricted: bool = False
    requires_refresh_before_execution: bool = True


@dataclass(frozen=True)
class AccountState:
    starting_balance: float
    balance: float
    equity_peak: float
    trailing_floor: Optional[float]
    trading_days: int = 0
    winning_days: int = 0
    cycle_profit: float = 0.0
    largest_winning_day: float = 0.0
    failed: bool = False
    fail_reason: str = ""


@dataclass(frozen=True)
class TradeDay:
    realized_pnl: float
    intraday_peak_equity: Optional[float] = None
    intraday_min_equity: Optional[float] = None
    max_contracts_used: int = 0
    traded_restricted_news: bool = False


@dataclass(frozen=True)
class CycleAssessment:
    passed_profit_target: bool
    payout_eligible: bool
    consistency_ratio: Optional[float]
    consistency_ok: bool
    survival_ok: bool
    reason: str


class PropFirmPolicyEngine:
    """Stateful prop-firm constraint simulator.

    Profiles are deliberately external/versioned because prop-firm rules change.
    This engine models normalized rules and fails closed on explicit breaches.
    It is suitable for research/backtesting; live execution must refresh the
    selected profile immediately before use when the profile says so.
    """

    @staticmethod
    def initial_state(starting_balance: float, profile: PropFirmProfile) -> AccountState:
        floor = None
        if profile.max_loss_distance is not None and profile.max_loss_type != "none":
            floor = starting_balance - profile.max_loss_distance
        return AccountState(
            starting_balance=starting_balance,
            balance=starting_balance,
            equity_peak=starting_balance,
            trailing_floor=floor,
        )

    @staticmethod
    def consistency_ratio(state: AccountState) -> Optional[float]:
        if state.cycle_profit <= 0:
            return None
        return state.largest_winning_day / state.cycle_profit

    def apply_day(self, state: AccountState, day: TradeDay, profile: PropFirmProfile) -> AccountState:
        if state.failed:
            return state

        if profile.contract_limit is not None and day.max_contracts_used > profile.contract_limit:
            return replace(state, failed=True, fail_reason="CONTRACT_LIMIT")
        if profile.news_restricted and day.traded_restricted_news:
            return replace(state, failed=True, fail_reason="NEWS_RESTRICTION")
        if profile.daily_loss_limit is not None and day.realized_pnl < -abs(profile.daily_loss_limit):
            return replace(state, failed=True, fail_reason="DAILY_LOSS_LIMIT")

        new_balance = state.balance + day.realized_pnl
        intraday_peak = day.intraday_peak_equity if day.intraday_peak_equity is not None else max(state.balance, new_balance)
        intraday_low = day.intraday_min_equity if day.intraday_min_equity is not None else min(state.balance, new_balance)
        new_peak = max(state.equity_peak, intraday_peak, new_balance)
        floor = state.trailing_floor

        if profile.max_loss_distance is not None:
            distance = abs(profile.max_loss_distance)
            if profile.max_loss_type == "static":
                floor = state.starting_balance - distance
            elif profile.max_loss_type == "eod_trailing":
                # EOD models advance the floor from closed balance, not intraday highs.
                floor = max(floor if floor is not None else float("-inf"), new_balance - distance)
            elif profile.max_loss_type == "intraday_trailing":
                floor = max(floor if floor is not None else float("-inf"), new_peak - distance)

        breach_level = floor
        if breach_level is not None:
            observed_low = intraday_low if profile.max_loss_type == "intraday_trailing" else new_balance
            if observed_low <= breach_level:
                return replace(
                    state,
                    balance=new_balance,
                    equity_peak=new_peak,
                    trailing_floor=floor,
                    trading_days=state.trading_days + 1,
                    failed=True,
                    fail_reason="MAX_LOSS_BREACH",
                )

        winning = day.realized_pnl >= profile.winning_day_threshold and day.realized_pnl > 0
        return AccountState(
            starting_balance=state.starting_balance,
            balance=new_balance,
            equity_peak=new_peak,
            trailing_floor=floor,
            trading_days=state.trading_days + 1,
            winning_days=state.winning_days + int(winning),
            cycle_profit=state.cycle_profit + day.realized_pnl,
            largest_winning_day=max(state.largest_winning_day, day.realized_pnl, 0.0),
            failed=False,
            fail_reason="",
        )

    def assess(self, state: AccountState, profile: PropFirmProfile) -> CycleAssessment:
        ratio = self.consistency_ratio(state)
        consistency_ok = True
        if profile.consistency_pct is not None:
            consistency_ok = ratio is not None and ratio <= profile.consistency_pct

        target_ok = profile.profit_target is None or state.cycle_profit >= profile.profit_target
        days_ok = state.trading_days >= profile.minimum_trading_days
        wins_ok = state.winning_days >= profile.minimum_winning_days
        buffer_ok = state.cycle_profit >= profile.payout_buffer
        survival_ok = not state.failed
        payout = survival_ok and consistency_ok and days_ok and wins_ok and buffer_ok

        if state.failed:
            reason = state.fail_reason
        elif not target_ok:
            reason = "PROFIT_TARGET_NOT_MET"
        elif not consistency_ok:
            reason = "CONSISTENCY_NOT_MET"
        elif not days_ok:
            reason = "MIN_TRADING_DAYS_NOT_MET"
        elif not wins_ok:
            reason = "MIN_WINNING_DAYS_NOT_MET"
        elif not buffer_ok:
            reason = "PAYOUT_BUFFER_NOT_MET"
        else:
            reason = "ELIGIBLE"

        return CycleAssessment(
            passed_profit_target=target_ok and survival_ok,
            payout_eligible=payout,
            consistency_ratio=ratio,
            consistency_ok=consistency_ok,
            survival_ok=survival_ok,
            reason=reason,
        )

    def simulate(self, starting_balance: float, days: Tuple[TradeDay, ...], profile: PropFirmProfile) -> Tuple[AccountState, CycleAssessment]:
        state = self.initial_state(starting_balance, profile)
        for day in days:
            state = self.apply_day(state, day, profile)
            if state.failed:
                break
        return state, self.assess(state, profile)
