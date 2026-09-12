from dataclasses import dataclass
from typing import Dict


@dataclass(frozen=True)
class ConfirmationResult:
    approved_blocks: int
    total_blocks: int
    candidate: bool
    vetoed: bool
    reason: str


class ConfirmationEngine:
    """Fail-closed 4-of-5 confirmation gate.

    The five blocks are independent evidence families and are not tied to a
    fixed clock window. Time/session is contextual evidence, not a mandatory
    trading schedule. Macro/fundamental remains a confidence modifier and can
    veto the trade without becoming an extra confirmation vote.
    """

    BLOCKS = (
        "context_regime",
        "structure_liquidity",
        "flow_volume",
        "cross_market",
        "strategy_synergy",
    )

    def __init__(self, required: int = 4):
        if required < 1 or required > len(self.BLOCKS):
            raise ValueError("required must be between 1 and 5")
        self.required = required

    def evaluate(
        self,
        confirmations: Dict[str, bool],
        *,
        macro_veto: bool = False,
        data_healthy: bool = True,
    ) -> ConfirmationResult:
        if not data_healthy:
            return ConfirmationResult(0, len(self.BLOCKS), False, True, "DATA_UNSAFE")
        if macro_veto:
            return ConfirmationResult(0, len(self.BLOCKS), False, True, "MACRO_VETO")

        missing = [b for b in self.BLOCKS if b not in confirmations]
        if missing:
            return ConfirmationResult(0, len(self.BLOCKS), False, True, f"MISSING:{','.join(missing)}")

        count = sum(bool(confirmations[b]) for b in self.BLOCKS)
        return ConfirmationResult(
            approved_blocks=count,
            total_blocks=len(self.BLOCKS),
            candidate=count >= self.required,
            vetoed=False,
            reason="CONFIRMATIONS_OK" if count >= self.required else "INSUFFICIENT_CONFIRMATIONS",
        )
