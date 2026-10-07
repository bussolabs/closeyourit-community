module Coworkers
  # The visible scope of a run, frozen when it is queued and narrowed to today's access on every
  # tool call: revocations apply, later grants never widen it (CYRA-1009, CYRA-812).
  module Scope
    # A team Puck sees only its project (CYRA-1023); a handed-off run never more than its parent (CYRA-1024).
    def self.capture(account:, organization:, puck: nil, parent: nil)
      snapshot = Authorization::ScopeSnapshot.capture(account: account, organization: organization)
      snapshot = snapshot.only_project(puck.project_id) if puck&.team?
      stored = { "project_ids" => snapshot.project_ids, "group_ids" => snapshot.group_ids,
                 "full_access" => snapshot.full_access, "listed" => true }
      parent ? within(stored, parent.scope) : stored
    end

    def self.within(stored, ceiling)
      stored.merge("project_ids" => stored["project_ids"] & Array(ceiling["project_ids"]),
                   "group_ids" => stored["group_ids"] & Array(ceiling["group_ids"]),
                   "full_access" => stored["full_access"] && ceiling["full_access"].present?)
    end

    def self.snapshot(run)
      stored = run.scope
      snapshot = Authorization::ScopeSnapshot.frozen(project_ids: stored["project_ids"], group_ids: stored["group_ids"],
                                                     full_access: stored["full_access"], listed: stored["listed"])
                                             .narrow(account: run.requester, organization: run.puck.organization)
      run.puck.team? ? snapshot.only_project(run.puck.project_id) : snapshot
    end

    def self.context_for(run)
      Assistant::Tools::Context.from_snapshot(snapshot(run), account: run.requester,
                                              organization: run.puck.organization, coworkers_run_id: run.id)
    end
  end
end
