BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'OrchestratorLogic.psm1') -Force
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'ScopePrefilter.psm1') -Force
}

Describe 'Test-IsAcceptedNoOp' {
    It 'is true when the accepted label is present (no-op required)' {
        Test-IsAcceptedNoOp -Labels @('bug', 'accepted', 'al-compiler-frontend') | Should -BeTrue
    }

    It 'is false when accepted is absent' {
        Test-IsAcceptedNoOp -Labels @('bug', 'requires-triage') | Should -BeFalse
    }

    It 'is false for an empty label set' {
        Test-IsAcceptedNoOp -Labels @() | Should -BeFalse
    }
}

Describe 'Get-PreviousLabelsApplied' {
    It 'parses labelsApplied from a prior structured comment' {
        $commentBody = @'
<!-- public-al-issue-triage:v2:issue-42 -->
## Automated triage report

<details><summary>Structured report (machine-readable)</summary>

```json
{"schemaVersion":2,"issue":42,"labelsApplied":["need-repro","input-needed"]}
```
</details>
'@
        $result = Get-PreviousLabelsApplied -ExistingCommentBody $commentBody
        $result | Should -Contain 'need-repro'
        $result | Should -Contain 'input-needed'
    }

    It 'returns an empty array when there is no prior comment' {
        Get-PreviousLabelsApplied -ExistingCommentBody $null | Should -BeNullOrEmpty
    }

    It 'returns an empty array when the comment has no embedded JSON block' {
        Get-PreviousLabelsApplied -ExistingCommentBody 'just a plain comment, no json' | Should -BeNullOrEmpty
    }
}

Describe 'Get-LabelReconciliationPlan (stale label removal / addition)' {
    BeforeAll { $script:managed = Get-ManagedLabelSet }

    It 'adds a newly desired managed label that is not yet present' {
        $plan = Get-LabelReconciliationPlan -DesiredLabels @('requires-triage') -CurrentLabels @('need-repro') -ManagedLabels $script:managed
        $plan.ToAdd | Should -Contain 'requires-triage'
    }

    It 'removes a stale managed label no longer desired (missing-repro -> complete/in-scope transition)' {
        # Simulates: issue previously classified missing-repro (need-repro applied), reporter then
        # edited the issue to add a code sample, and it is now in_scope/tooling (requires-triage).
        $plan = Get-LabelReconciliationPlan -DesiredLabels @('requires-triage') -CurrentLabels @('need-repro', 'requires-triage') -ManagedLabels $script:managed
        $plan.ToRemove | Should -Contain 'need-repro'
        $plan.ToAdd | Should -Not -Contain 'requires-triage'
    }

    It 'never removes accepted even if somehow present in current labels' {
        $plan = Get-LabelReconciliationPlan -DesiredLabels @('requires-triage') -CurrentLabels @('accepted', 'need-repro') -ManagedLabels $script:managed
        $plan.ToRemove | Should -Not -Contain 'accepted'
    }

    It 'never adds accepted even if somehow present in desired labels' {
        $plan = Get-LabelReconciliationPlan -DesiredLabels @('requires-triage', 'accepted') -CurrentLabels @() -ManagedLabels $script:managed
        $plan.ToAdd | Should -Not -Contain 'accepted'
    }

    It 'preserves unmanaged (component/human) labels untouched - they never appear in ToAdd or ToRemove' {
        $plan = Get-LabelReconciliationPlan -DesiredLabels @('requires-triage') -CurrentLabels @('al-compiler-frontend', 'need-repro') -ManagedLabels $script:managed
        $plan.ToRemove | Should -Not -Contain 'al-compiler-frontend'
        $plan.ToAdd | Should -Not -Contain 'al-compiler-frontend'
    }

    It 'produces empty add/remove plans when current already matches desired exactly' {
        $plan = Get-LabelReconciliationPlan -DesiredLabels @('requires-triage') -CurrentLabels @('requires-triage', 'al-compiler-frontend') -ManagedLabels $script:managed
        $plan.ToAdd.Count | Should -Be 0
        $plan.ToRemove.Count | Should -Be 0
    }
}

Describe 'Test-ExactDuplicateTitle' {
    It 'is true for identical titles differing only by punctuation/case/whitespace' {
        Test-ExactDuplicateTitle -TitleA 'AL compiler crashes on nested with!' -TitleB '  al   compiler crashes on nested with  ' | Should -BeTrue
    }

    It 'is false for merely similar (not identical) titles' {
        Test-ExactDuplicateTitle -TitleA 'AL compiler crashes on nested with statements' -TitleB 'AL compiler crashes on nested with statements (duplicate)' | Should -BeFalse
    }
}

Describe 'Resolve-OverallTier1Status' {
    It 'reports reproduced if any tested version reproduced the symptom' {
        $result = Resolve-OverallTier1Status -RestoredStatuses @('inconclusive', 'reproduced')
        $result.Reproduction | Should -Be 'reproduced'
        $result.Proof | Should -Be 'execution'
        $result.Confidence | Should -Be 'high'
    }

    It 'reports not_reproduced when evidence ruled it out and nothing reproduced' {
        $result = Resolve-OverallTier1Status -RestoredStatuses @('not_reproduced', 'not_reproduced')
        $result.Reproduction | Should -Be 'not_reproduced'
        $result.Confidence | Should -Be 'medium'
    }

    It 'reports inconclusive when all tested versions were inconclusive (compile success but no symptom)' {
        $result = Resolve-OverallTier1Status -RestoredStatuses @('inconclusive', 'inconclusive')
        $result.Reproduction | Should -Be 'inconclusive'
        $result.Confidence | Should -Be 'low'
    }

    It 'reports blocked when nothing could be restored/tested' {
        $result = Resolve-OverallTier1Status -RestoredStatuses @()
        $result.Reproduction | Should -Be 'blocked'
        $result.Proof | Should -Be 'unverified'
    }
}
