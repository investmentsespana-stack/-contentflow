export type RequirementClass =
  | 'external_approval'
  | 'persistence_integration'
  | 'runtime_evidence'
  | 'runtime_test'
  | 'source_contract'
  | 'static_analysis'
  | string;

export type CoverageState =
  | 'ready_to_verify'
  | 'producer_ready'
  | 'verifier_only'
  | 'missing_capability';

export interface EvidenceRequirement {
  id: number;
  requirementClass: RequirementClass;
  prerequisite: string;
  taskKey: string;
}

export interface EvidenceCapability {
  prerequisite: string;
  verifierAvailable: boolean;
  producerAvailable: boolean;
  evidenceAlreadyVerifiable?: boolean;
  provider?: string | null;
  scope?: string | null;
}

export interface EvidenceCoveragePlanItem extends EvidenceRequirement {
  state: CoverageState;
  score: number;
  provider: string | null;
  scope: string | null;
  reason: string;
}

const CLASS_WEIGHT: Record<string, number> = {
  runtime_test: 60,
  persistence_integration: 55,
  runtime_evidence: 50,
  source_contract: 45,
  static_analysis: 40,
  external_approval: 30,
};

const STATE_WEIGHT: Record<CoverageState, number> = {
  ready_to_verify: 40,
  producer_ready: 30,
  verifier_only: 20,
  missing_capability: 10,
};

export function classifyCoverage(capability?: EvidenceCapability): CoverageState {
  if (!capability) return 'missing_capability';
  if (capability.evidenceAlreadyVerifiable) return 'ready_to_verify';
  if (capability.producerAvailable && capability.verifierAvailable) return 'producer_ready';
  if (capability.verifierAvailable) return 'verifier_only';
  return 'missing_capability';
}

export function buildEvidenceCoveragePlan(
  requirements: EvidenceRequirement[],
  capabilities: EvidenceCapability[],
): EvidenceCoveragePlanItem[] {
  const byPrerequisite = new Map(capabilities.map((capability) => [capability.prerequisite, capability]));

  return requirements
    .map((requirement) => {
      const capability = byPrerequisite.get(requirement.prerequisite);
      const state = classifyCoverage(capability);
      const score = (CLASS_WEIGHT[requirement.requirementClass] ?? 25) + STATE_WEIGHT[state];
      const reason = capability
        ? `${state}: verifier=${capability.verifierAvailable}; producer=${capability.producerAvailable}`
        : `missing_capability: no registry entry for prerequisite=${requirement.prerequisite}`;
      return {
        ...requirement,
        state,
        score,
        provider: capability?.provider ?? null,
        scope: capability?.scope ?? null,
        reason,
      };
    })
    .sort((a, b) => b.score - a.score || a.id - b.id);
}
