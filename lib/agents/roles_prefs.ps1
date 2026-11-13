# Skill groups contributed by the prefs layer. See Get-AgentRoles for how layers compose into roles.
@{
    skillGroups = @{
        writing       = @('kql-techniques', 'drafting-for-others')
        planLifecycle = @('end-plan')
        repoCuration  = @('review-repo-skills')
        workstreams   = @('update-workstream-id')
        monitoring    = @('long-running-monitoring')
    }
    # Skills the always-loaded agent-user_prefs.md tells every session to use.
    everyRoleSkillGroups = @('workstreams')
}
# OmitFromCoverageReport: a unit test would just restate it - static skill-group data
