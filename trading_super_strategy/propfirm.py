from __future__ import annotations

import random
from dataclasses import dataclass, replace
from enum import Enum
from typing import Iterable, Optional, Tuple


class VerificationState(str, Enum):
    VERIFIED = "VERIFIED"
    UNKNOWN = "UNKNOWN"
    STALE = "STALE"


class DrawdownKind(str, Enum):
    STATIC = "STATIC"
    TRAILING = "TRAILING"


class RuleUnit(str, Enum):
    ABSOLUTE = "ABSOLUTE"
    PERCENT = "PERCENT"


class BreachReason(str, Enum):
    POLICY_UNVERIFIED = "POLICY_UNVERIFIED"
    STATIC_DRAWDOWN = "STATIC_DRAWDOWN"
    TRAILING_DRAWDOWN = "TRAILING_DRAWDOWN"
    DAILY_LOSS = "DAILY_LOSS"
    CONTRACT_LIMIT = "CONTRACT_LIMIT"
    CONSISTENCY_CONCENTRATION = "CONSISTENCY_CONCENTRATION"
    NEWS_RESTRICTION = "NEWS_RESTRICTION"
    INVALID_EVENT = "INVALID_EVENT"


@dataclass(frozen=True)
class Limit:
    unit: RuleUnit
    value: float

    def __post_init__(self) -> None:
        if self.value < 0:
            raise ValueError("limit value cannot be negative")

    def amount(self, reference: float) -> float:
        if self.unit is RuleUnit.ABSOLUTE:
            return self.value
        return reference * self.value / 100.0


@dataclass(frozen=True)
class DrawdownRule:
    kind: DrawdownKind
    limit: Limit


@dataclass(frozen=True)
class NewsWindow:
    start_ts: int
    end_ts: int
    assets: Tuple[str, ...]

    def __post_init__(self) -> None:
        if self.end_ts < self.start_ts:
            raise ValueError("news window end must be >= start")

    def blocks(self, ts: int, asset: str) -> bool:
        return self.start_ts <= ts <= self.end_ts and ("*" in self.assets or asset in self.assets)


@dataclass(frozen=True)
class PayoutRule:
    minimum_cycle_profit: float
    payout_rate: float
    retained_buffer: float

    def __post_init__(self) -> None:
        if self.minimum_cycle_profit < 0 or self.retained_buffer < 0:
            raise ValueError("payout values cannot be negative")
        if not 0.0 <= self.payout_rate <= 1.0:
            raise ValueError("payout_rate must be between 0 and 1")


@dataclass(frozen=True)
class PropFirmPolicy:
    policy_id: str
    verification_state: VerificationState
    reverify_required: bool
    drawdown_rules: Tuple[DrawdownRule, ...]
    daily_loss_limit: Optional[Limit]
    max_contracts: Optional[int]
    max_largest_profitable_day_pct: Optional[float]
    consistency_is_breach: bool
    payout_rule: Optional[PayoutRule]
    news_windows: Tuple[NewsWindow, ...] = ()

    def __post_init__(self) -> None:
        if not self.policy_id.strip():
            raise ValueError("policy_id is required")
        if self.max_contracts is not None and self.max_contracts <= 0:
            raise ValueError("max_contracts must be positive")
        if self.max_largest_profitable_day_pct is not None:
            if not 0.0 <= self.max_largest_profitable_day_pct <= 100.0:
                raise ValueError("consistency percentage must be between 0 and 100")

    @property
    def usable(self) -> bool:
        return self.verification_state is VerificationState.VERIFIED and not self.reverify_required


@dataclass(frozen=True)
class AccountState:
    initial_balance: float
    balance: float
    equity: float
    peak_equity: float
    start_of_day_equity: float
    daily_pnl: float = 0.0
    current_day_profit: float = 0.0
    largest_profitable_day: float = 0.0
    cycle_profit: float = 0.0
    open_contracts: int = 0
    payout_eligible: bool = False
    breach: Optional[BreachReason] = None

    @classmethod
    def fresh(cls, initial_balance: float) -> "AccountState":
        if initial_balance <= 0:
            raise ValueError("initial_balance must be positive")
        return cls(
            initial_balance=initial_balance,
            balance=initial_balance,
            equity=initial_balance,
            peak_equity=initial_balance,
            start_of_day_equity=initial_balance,
        )


@dataclass(frozen=True)
class TradeEvent:
    timestamp: int
    asset: str
    realized_pnl: float
    open_contracts_after: int


@dataclass(frozen=True)
class DailyRolloverEvent:
    timestamp: int


@dataclass(frozen=True)
class PayoutEvent:
    timestamp: int
    amount: float


Event = TradeEvent | DailyRolloverEvent | PayoutEvent


def _breach(state: AccountState, reason: BreachReason) -> AccountState:
    return replace(state, breach=reason, payout_eligible=False)


def _consistency_ratio(state: AccountState) -> float:
    if state.cycle_profit <= 0:
        return 0.0
    largest = max(state.largest_profitable_day, state.current_day_profit, 0.0)
    return 100.0 * largest / state.cycle_profit


def payout_eligible(policy: PropFirmPolicy, state: AccountState) -> bool:
    if not policy.usable or state.breach is not None or policy.payout_rule is None:
        return False
    if state.cycle_profit < policy.payout_rule.minimum_cycle_profit:
        return False
    if policy.max_largest_profitable_day_pct is not None:
        if _consistency_ratio(state) > policy.max_largest_profitable_day_pct:
            return False
    return state.equity >= state.initial_balance + policy.payout_rule.retained_buffer


def apply_event(policy: PropFirmPolicy, state: AccountState, event: Event) -> AccountState:
    if state.breach is not None:
        return state
    if not policy.usable:
        return _breach(state, BreachReason.POLICY_UNVERIFIED)

    if isinstance(event, TradeEvent):
        if not event.asset or event.open_contracts_after < 0:
            return _breach(state, BreachReason.INVALID_EVENT)
        for window in policy.news_windows:
            if window.blocks(event.timestamp, event.asset):
                return _breach(state, BreachReason.NEWS_RESTRICTION)
        if policy.max_contracts is not None and event.open_contracts_after > policy.max_contracts:
            return _breach(state, BreachReason.CONTRACT_LIMIT)

        new_balance = state.balance + event.realized_pnl
        new_equity = state.equity + event.realized_pnl
        new_peak = max(state.peak_equity, new_equity)
        new_daily = state.daily_pnl + event.realized_pnl
        new_day_profit = state.current_day_profit + event.realized_pnl
        new_cycle_profit = state.cycle_profit + event.realized_pnl
        next_state = replace(
            state,
            balance=new_balance,
            equity=new_equity,
            peak_equity=new_peak,
            daily_pnl=new_daily,
            current_day_profit=new_day_profit,
            cycle_profit=new_cycle_profit,
            open_contracts=event.open_contracts_after,
        )

        if policy.daily_loss_limit is not None:
            allowed = policy.daily_loss_limit.amount(state.start_of_day_equity)
            if -next_state.daily_pnl > allowed:
                return _breach(next_state, BreachReason.DAILY_LOSS)

        for rule in policy.drawdown_rules:
            if rule.kind is DrawdownKind.STATIC:
                allowed = rule.limit.amount(state.initial_balance)
                if next_state.equity < state.initial_balance - allowed:
                    return _breach(next_state, BreachReason.STATIC_DRAWDOWN)
            else:
                allowed = rule.limit.amount(next_state.peak_equity)
                if next_state.equity < next_state.peak_equity - allowed:
                    return _breach(next_state, BreachReason.TRAILING_DRAWDOWN)

        if (
            policy.consistency_is_breach
            and policy.max_largest_profitable_day_pct is not None
            and next_state.cycle_profit > 0
            and _consistency_ratio(next_state) > policy.max_largest_profitable_day_pct
        ):
            return _breach(next_state, BreachReason.CONSISTENCY_CONCENTRATION)

        return replace(next_state, payout_eligible=payout_eligible(policy, next_state))

    if isinstance(event, DailyRolloverEvent):
        largest = max(state.largest_profitable_day, state.current_day_profit, 0.0)
        next_state = replace(
            state,
            largest_profitable_day=largest,
            start_of_day_equity=state.equity,
            daily_pnl=0.0,
            current_day_profit=0.0,
        )
        return replace(next_state, payout_eligible=payout_eligible(policy, next_state))

    if isinstance(event, PayoutEvent):
        if event.amount <= 0 or not payout_eligible(policy, state) or policy.payout_rule is None:
            return _breach(state, BreachReason.INVALID_EVENT)
        max_payout = max(0.0, state.cycle_profit * policy.payout_rule.payout_rate)
        amount = min(event.amount, max_payout)
        post_equity = state.equity - amount
        floor = state.initial_balance + policy.payout_rule.retained_buffer
        if post_equity < floor:
            return _breach(state, BreachReason.INVALID_EVENT)
        return replace(
            state,
            balance=state.balance - amount,
            equity=post_equity,
            peak_equity=max(post_equity, state.initial_balance),
            start_of_day_equity=post_equity,
            daily_pnl=0.0,
            current_day_profit=0.0,
            largest_profitable_day=0.0,
            cycle_profit=max(0.0, state.cycle_profit - amount),
            payout_eligible=False,
        )

    return _breach(state, BreachReason.INVALID_EVENT)


@dataclass(frozen=True)
class CandidateEvaluation:
    net_oos_ev_r: float
    survival_probability: float
    payout_probability: float
    accepted: bool


def evaluate_candidate(
    policy: PropFirmPolicy,
    r_multiples: Iterable[float],
    *,
    initial_balance: float,
    risk_per_trade: float,
    cost_r: float,
    samples: int = 500,
    seed: int = 7,
    minimum_survival: float = 0.80,
    minimum_payout_probability: float = 0.10,
) -> CandidateEvaluation:
    observations = tuple(float(x) for x in r_multiples)
    if not policy.usable or not observations or samples <= 0 or risk_per_trade <= 0:
        return CandidateEvaluation(float("-inf"), 0.0, 0.0, False)

    net_ev = sum(observations) / len(observations) - cost_r
    if net_ev <= 0:
        return CandidateEvaluation(net_ev, 0.0, 0.0, False)

    rng = random.Random(seed)
    survived = 0
    payout_ready = 0
    for sample_no in range(samples):
        state = AccountState.fresh(initial_balance)
        for i in range(len(observations)):
            r = observations[rng.randrange(len(observations))]
            state = apply_event(
                policy,
                state,
                TradeEvent(
                    timestamp=sample_no * 1_000_000 + i,
                    asset="NQ",
                    realized_pnl=(r - cost_r) * risk_per_trade,
                    open_contracts_after=0,
                ),
            )
            if state.breach is not None:
                break
        if state.breach is None:
            survived += 1
            if payout_eligible(policy, state):
                payout_ready += 1

    survival_probability = survived / samples
    payout_probability = payout_ready / samples
    accepted = (
        net_ev > 0
        and survival_probability >= minimum_survival
        and payout_probability >= minimum_payout_probability
    )
    return CandidateEvaluation(net_ev, survival_probability, payout_probability, accepted)
