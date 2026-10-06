# frozen_string_literal: true

require "rails_helper"

# Ordinamento per colonna (?sort=chiave / -chiave, contratto Sortable) sulle index member.
# Un blocco per pagina: asc/desc su una colonna testo + (dove esiste) una colonna COUNT via
# subquery. Il fallback whitelist/default è pinnato una volta sola sui ticket (pagina di
# riferimento, spec/requests/member/tickets_spec.rb).
RSpec.describe "Member sorting (index tabellari)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def ordered?(body, first, second)
    expect(body.index(first)).to be < body.index(second)
  end

  describe "GET /member/projects" do
    let!(:zulu)  { create(:project, organization: org, name: "Zulu Suite") }
    let!(:alpha) { create(:project, organization: org, name: "alpha Kit") }

    it "sort=name asc case-insensitive e -name desc" do
      sign_in(owner)
      get member_projects_path, params: { sort: "name" }
      ordered?(response.body, "alpha Kit", "Zulu Suite")

      get member_projects_path, params: { sort: "-name" }
      ordered?(response.body, "Zulu Suite", "alpha Kit")
    end

    it "sort=-tickets: subquery COUNT, il progetto con più ticket viene prima" do
      # Fixture bulk: ogni ticket fa i suoi tenant-check di setup (stesso pattern di tickets_spec).
      allow_n_plus_one { create_list(:ticket, 2, organization: org, project: zulu) }
      sign_in(owner)
      get member_projects_path, params: { sort: "-tickets" }
      ordered?(response.body, "Zulu Suite", "alpha Kit")
    end

    it "sort convive col filtro piattaforma (subselect, niente DISTINCT)" do
      platform = create(:platform, organization: org)
      zulu.platforms << platform
      alpha.platforms << platform
      sign_in(owner)
      get member_projects_path, params: { sort: "name", platform_id: [ platform.id ] }
      expect(response).to have_http_status(:ok)
      ordered?(response.body, "alpha Kit", "Zulu Suite")
    end
  end

  describe "GET /member/groups" do
    let!(:zeta)  { create(:group, organization: org, name: "Zeta band") }
    let!(:acme)  { create(:group, organization: org, name: "acme crew") }

    it "sort=group asc e desc" do
      sign_in(owner)
      get member_groups_path, params: { sort: "group" }
      ordered?(response.body, "acme crew", "Zeta band")

      get member_groups_path, params: { sort: "-group" }
      ordered?(response.body, "Zeta band", "acme crew")
    end

    it "sort=-projects: subquery COUNT sui progetti del gruppo" do
      create(:project, organization: org, group: zeta)
      sign_in(owner)
      get member_groups_path, params: { sort: "-projects" }
      ordered?(response.body, "Zeta band", "acme crew")
    end
  end

  describe "GET /member/members (due tabelle, param indipendenti)" do
    let!(:aaa) { create(:account, name: "Anna", email: "aaa@sort.test") }
    let!(:zzz) { create(:account, name: "Zoe", email: "zzz@sort.test") }

    before do
      create(:membership, account: aaa, organization: org, role: :member)
      create(:membership, account: zzz, organization: org, role: :member)
    end

    it "sort=email ordina i membri via join accounts" do
      sign_in(owner)
      get member_members_path, params: { sort: "email" }
      ordered?(response.body, "aaa@sort.test", "zzz@sort.test")

      get member_members_path, params: { sort: "-email" }
      ordered?(response.body, "zzz@sort.test", "aaa@sort.test")
    end

    it "invitations_sort ordina SOLO la tabella inviti (i membri restano sul loro sort)" do
      create(:invitation, organization: org, email: "beta@invite.test")
      create(:invitation, organization: org, email: "alfa@invite.test")
      sign_in(owner)
      get member_members_path, params: { sort: "email", invitations_sort: "-email" }
      ordered?(response.body, "aaa@sort.test", "zzz@sort.test")          # membri asc
      ordered?(response.body, "beta@invite.test", "alfa@invite.test")   # inviti desc
    end
  end

  describe "GET /member/roles" do
    let!(:zulu_role) { create(:role, organization: org, name: "Zulu ops") }
    let!(:audit)     { create(:role, organization: org, name: "audit basic") }

    it "sort=role asc e desc" do
      sign_in(owner)
      get member_roles_path, params: { sort: "role" }
      ordered?(response.body, "audit basic", "Zulu ops")

      get member_roles_path, params: { sort: "-role" }
      ordered?(response.body, "Zulu ops", "audit basic")
    end

    it "sort=-permissions: subquery COUNT sulle chiavi del ruolo" do
      create(:role_permission, role: audit, permission_key: "tickets.edit")
      sign_in(owner)
      get member_roles_path, params: { sort: "-permissions" }
      ordered?(response.body, "audit basic", "Zulu ops")
    end
  end

  describe "GET /member/teams" do
    let!(:zebra) { create(:team, organization: org, name: "Zebra squad") }
    let!(:alpha) { create(:team, organization: org, name: "alpha unit") }

    it "sort=team asc, sort=-members via subquery COUNT" do
      create(:team_membership, team: alpha, account: owner)
      sign_in(owner)
      get member_teams_path, params: { sort: "team" }
      ordered?(response.body, "alpha unit", "Zebra squad")

      get member_teams_path, params: { sort: "-members" }
      ordered?(response.body, "alpha unit", "Zebra squad")
    end
  end

  describe "GET /member/platforms" do
    let!(:zweb) { create(:platform, organization: org, label: "zWeb", code: "zzz") }
    let!(:droid) { create(:platform, organization: org, label: "Android", code: "aaa") }

    it "sort=platform (LOWER label) e sort=code asc/desc" do
      sign_in(owner)
      get member_platforms_path, params: { sort: "platform" }
      ordered?(response.body, "Android", "zWeb")

      get member_platforms_path, params: { sort: "-code" }
      ordered?(response.body, "zWeb", "Android")
    end
  end

  describe "GET /member/alerting/rules" do
    let!(:zulu)  { create(:alerting_rule, organization: org, name: "Zulu alert") }
    let!(:early) { create(:alerting_rule, organization: org, name: "early warning") }

    it "sort=rule asc/desc e sort=-last_fired (MAX subquery, mai-scattate in fondo)" do
      create(:alerting_notification, organization: org, account: owner, rule: early)
      sign_in(owner)
      get member_alerting_rules_path, params: { sort: "rule" }
      ordered?(response.body, "early warning", "Zulu alert")

      get member_alerting_rules_path, params: { sort: "-last_fired" }
      ordered?(response.body, "early warning", "Zulu alert") # early ha scattato, zulu mai → in fondo
    end
  end

  describe "GET /member/alerting/channels (senza paginazione)" do
    # Il guard anti-SSRF valida la URL webhook via DNS (`.test` non risolve): stub deterministico,
    # qui interessa solo l'ordinamento — la validazione URL è coperta altrove.
    before { allow(NetworkGuard).to receive(:safe_url?).and_return(true) }

    let!(:zapier) { create(:alerting_channel, organization: org, name: "Zapier hook") }
    let!(:alarm)  { create(:alerting_channel, organization: org, name: "alarm bot") }

    it "sort=name asc e sort=-rules via subquery COUNT" do
      create(:alerting_rule_channel, channel: alarm, rule: create(:alerting_rule, organization: org))
      sign_in(owner)
      get member_alerting_channels_path, params: { sort: "name" }
      ordered?(response.body, "alarm bot", "Zapier hook")

      get member_alerting_channels_path, params: { sort: "-rules" }
      ordered?(response.body, "alarm bot", "Zapier hook")
    end
  end

  describe "GET /member/projects/:project_id/milestones" do
    let(:project) { create(:project, organization: org) }
    let!(:zeta) { create(:milestone, project: project, label: "Zeta launch", code: "m_zeta") }
    let!(:alfa) { create(:milestone, project: project, label: "alfa sprint", code: "m_alfa") }

    it "sort=milestone asc/desc (URL nested: il toggle usa request.path)" do
      sign_in(owner)
      get member_project_milestones_path(project), params: { sort: "milestone" }
      ordered?(response.body, "alfa sprint", "Zeta launch")

      get member_project_milestones_path(project), params: { sort: "-milestone" }
      ordered?(response.body, "Zeta launch", "alfa sprint")
    end

    it "sort=-tickets: subquery COUNT sui ticket del milestone" do
      create(:ticket, organization: org, project: project, milestone: zeta)
      sign_in(owner)
      get member_project_milestones_path(project), params: { sort: "-tickets" }
      ordered?(response.body, "Zeta launch", "alfa sprint")
    end
  end

  describe "GET /member/projects/:project_id/settings (tokens section)" do
    let(:project) { create(:project, organization: org) }
    let!(:zkey) { create(:project_token, project: project, name: "Zkey prod") }
    let!(:beta) { create(:project_token, project: project, name: "beta ci") }

    it "sort=name asc/desc via LOWER" do
      sign_in(owner)
      get member_project_settings_path(project), params: { sort: "name" }
      ordered?(response.body, "beta ci", "Zkey prod")

      get member_project_settings_path(project), params: { sort: "-name" }
      ordered?(response.body, "Zkey prod", "beta ci")
    end
  end

  describe "GET /member/environments" do
    let!(:zprod) { create(:environment, organization: org, label: "zProd", code: "zzz") }
    let!(:beta)  { create(:environment, organization: org, label: "Beta", code: "aaa") }

    it "sort=environment (LOWER label) e sort=code asc/desc" do
      sign_in(owner)
      get member_environments_path, params: { sort: "environment" }
      ordered?(response.body, "Beta", "zProd")

      get member_environments_path, params: { sort: "-code" }
      ordered?(response.body, "zProd", "Beta")
    end
  end

  describe "GET /member/monitoring/error (tabella raw)" do
    let(:project) { create(:project, organization: org) }
    let!(:zoom) { create(:error_group, project: project, title: "ZeroDivision boom", events_count: 3) }
    let!(:auth) { create(:error_group, project: project, title: "auth failure", events_count: 50) }

    it "sort=issue (LOWER title) e sort=-events (contatore)" do
      sign_in(owner)
      get member_monitoring_error_groups_path, params: { sort: "issue" }
      ordered?(response.body, "auth failure", "ZeroDivision boom")

      get member_monitoring_error_groups_path, params: { sort: "-events" }
      ordered?(response.body, "auth failure", "ZeroDivision boom")
    end
  end

  describe "GET /member/monitoring/logs" do
    let(:project) { create(:project, organization: org) }
    let!(:older) { create(:log_entry, project: project, message: "Aaa first", occurred_at: 2.hours.ago) }
    let!(:newer) { create(:log_entry, project: project, message: "Zzz last", occurred_at: 1.minute.ago) }

    it "sort=when desc (default) e sort=message asc" do
      sign_in(owner)
      get member_monitoring_log_entries_path, params: { sort: "-when" }
      ordered?(response.body, "Zzz last", "Aaa first")

      get member_monitoring_log_entries_path, params: { sort: "message" }
      ordered?(response.body, "Aaa first", "Zzz last")
    end
  end

  describe "GET /member/monitoring/performance" do
    let(:project) { create(:project, organization: org) }
    let!(:slow) { create(:metric_group, project: project, title: "Zoo query", samples_count: 2, duration_total_ms: 1000.0) }
    let!(:fast) { create(:metric_group, project: project, title: "abc query", samples_count: 10, duration_total_ms: 500.0) }

    it "sort=signature (LOWER title) e sort=-avg (espressione total/samples)" do
      sign_in(owner)
      get member_monitoring_metric_groups_path, params: { sort: "signature" }
      ordered?(response.body, "abc query", "Zoo query")

      # avg slow = 500, avg fast = 50 → slow prima in desc
      get member_monitoring_metric_groups_path, params: { sort: "-avg" }
      ordered?(response.body, "Zoo query", "abc query")
    end
  end

  describe "GET /member/monitoring/monitors" do
    let(:project) { create(:project, organization: org) }
    let!(:recent) { create(:uptime_monitor, project: project, last_checked_at: 1.minute.ago) }
    let!(:stale)  { create(:uptime_monitor, project: create(:project, organization: org), last_checked_at: 3.hours.ago) }

    it "sort=-last_check ordina per ultimo controllo (name è auto-derivato)" do
      sign_in(owner)
      get member_monitoring_monitors_path, params: { sort: "-last_check" }
      # dom_id della riga: univoco e presente SOLO nella tabella (il nome progetto compare
      # anche nel dropdown filtro, ordinato a parte).
      ordered?(response.body, "uptime_monitor_#{recent.id}", "uptime_monitor_#{stale.id}")
    end
  end

  describe "GET /member/monitoring/cron" do
    let(:project) { create(:project, organization: org) }
    let!(:zjob) { create(:cron_monitor, project: project, name: "Zulu job", slug: "zjob") }
    let!(:ajob) { create(:cron_monitor, project: project, name: "alpha job", slug: "ajob") }

    it "sort=name asc/desc" do
      sign_in(owner)
      get member_monitoring_cron_monitors_path, params: { sort: "name" }
      ordered?(response.body, "alpha job", "Zulu job")

      get member_monitoring_cron_monitors_path, params: { sort: "-name" }
      ordered?(response.body, "Zulu job", "alpha job")
    end
  end

  describe "GET /member/monitoring/servers" do
    let!(:zbox) { create(:server_host, organization: org, name: "zBox", cpu_pct: 10) }
    let!(:abox) { create(:server_host, organization: org, name: "aBox", cpu_pct: 90) }

    it "sort=host (LOWER name) e sort=-cpu (snapshot)" do
      sign_in(owner)
      get member_monitoring_servers_path, params: { sort: "host" }
      ordered?(response.body, "aBox", "zBox")

      get member_monitoring_servers_path, params: { sort: "-cpu" }
      ordered?(response.body, "aBox", "zBox")
    end
  end

  describe "GET /member/monitoring/tokens" do
    let!(:zt) { create(:server_enrollment_token, organization: org, name: "Zeta fleet") }
    let!(:at) { create(:server_enrollment_token, organization: org, name: "alfa fleet") }

    it "sort=name asc/desc" do
      sign_in(owner)
      get member_monitoring_server_tokens_path, params: { sort: "name" }
      ordered?(response.body, "alfa fleet", "Zeta fleet")

      get member_monitoring_server_tokens_path, params: { sort: "-name" }
      ordered?(response.body, "Zeta fleet", "alfa fleet")
    end
  end

  # CYRA-924 — every column sorts except multi-valued ones (projects) and actions (C9).
  describe "GET /member/knowledge/books" do
    let!(:zeta) { create(:knowledge_book, organization: org, title: "Zeta handbook", created_by: owner) }
    let!(:alpha) { create(:knowledge_book, organization: org, title: "alpha notes", created_by: owner) }

    it "sorts by title both ways" do
      sign_in(owner)
      get member_knowledge_books_path, params: { sort: "title" }
      ordered?(response.body, "alpha notes", "Zeta handbook")

      get member_knowledge_books_path, params: { sort: "-title" }
      ordered?(response.body, "Zeta handbook", "alpha notes")
    end

    it "sorts by page count" do
      allow_n_plus_one { create_list(:knowledge_page, 2, organization: org, book: zeta, created_by: owner) }
      sign_in(owner)
      get member_knowledge_books_path, params: { sort: "-pages" }
      ordered?(response.body, "Zeta handbook", "alpha notes")
    end

    it "renders sortable headers for title, pages, author and updated" do
      sign_in(owner)
      get member_knowledge_books_path
      %w[title pages author updated].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end
  end

  describe "GET /member/knowledge/pages" do
    let!(:zeta) { create(:knowledge_page, organization: org, title: "Zeta runbook", created_by: owner) }
    let!(:alpha) { create(:knowledge_page, organization: org, title: "alpha decision", created_by: owner) }

    it "sorts by title both ways" do
      sign_in(owner)
      get member_knowledge_pages_path, params: { sort: "title" }
      ordered?(response.body, "alpha decision", "Zeta runbook")

      get member_knowledge_pages_path, params: { sort: "-title" }
      ordered?(response.body, "Zeta runbook", "alpha decision")
    end

    it "renders sortable headers for title, kind, author and updated" do
      sign_in(owner)
      get member_knowledge_pages_path
      %w[title kind author updated].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end
  end

  describe "GET /member/monitoring/incidents" do
    let!(:zulu) { create(:uptime_incident, monitor: create(:uptime_monitor, project: create(:project, organization: org, name: "Zulu API")), started_at: 2.hours.ago) }
    let!(:alpha) { create(:uptime_incident, monitor: create(:uptime_monitor, project: create(:project, organization: org, name: "alpha site")), started_at: 1.hour.ago) }

    it "sorts by monitor both ways" do
      sign_in(owner)
      get member_monitoring_incidents_path, params: { sort: "monitor" }
      ordered?(response.body, "alpha site", "Zulu API")

      get member_monitoring_incidents_path, params: { sort: "-monitor" }
      ordered?(response.body, "Zulu API", "alpha site")
    end

    it "sorts by start" do
      sign_in(owner)
      get member_monitoring_incidents_path, params: { sort: "started" }
      ordered?(response.body, "Zulu API", "alpha site")
    end

    it "renders sortable headers for every column" do
      sign_in(owner)
      get member_monitoring_incidents_path
      %w[monitor started resolved duration status].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end
  end

  describe "GET /member/agents" do
    let!(:zulu) { create(:agent_host, organization: org, hostname: "zulu-mac", last_heartbeat_at: 1.minute.ago, slots: 4) }
    let!(:alpha) { create(:agent_host, organization: org, hostname: "Alpha-mini", last_heartbeat_at: 2.hours.ago, slots: 1) }

    it "sorts by host both ways" do
      sign_in(owner)
      get member_agents_path, params: { sort: "host" }
      ordered?(response.body, "Alpha-mini", "zulu-mac")

      get member_agents_path, params: { sort: "-host" }
      ordered?(response.body, "zulu-mac", "Alpha-mini")
    end

    it "sorts by last heartbeat" do
      sign_in(owner)
      get member_agents_path, params: { sort: "heartbeat" }
      ordered?(response.body, "Alpha-mini", "zulu-mac")
    end

    it "renders sortable headers for every column" do
      sign_in(owner)
      get member_agents_path
      %w[host status activity slots heartbeat].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end
  end

  describe "GET /member/projects/:id (tickets list)" do
    let(:project) { create(:project, organization: org) }
    let!(:zulu) { create(:ticket, organization: org, project:, title: "Zulu checkout bug") }
    let!(:alpha) { create(:ticket, organization: org, project:, title: "alpha login story") }

    it "sorts by title both ways" do
      sign_in(owner)
      get member_project_path(project), params: { sort: "title" }
      ordered?(response.body, "alpha login story", "Zulu checkout bug")

      get member_project_path(project), params: { sort: "-title" }
      ordered?(response.body, "Zulu checkout bug", "alpha login story")
    end

    it "renders sortable headers for every column" do
      sign_in(owner)
      get member_project_path(project)
      %w[code title priority status assignee].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end
  end

  describe "GET /member/agents/:id (runtimes)" do
    let!(:host) do
      create(:agent_host, organization: org, runtimes: [ { "name" => "ruby", "version" => "4.0.6" }, { "name" => "Node", "version" => "22.1.0" } ])
    end

    it "sorts runtimes by name both ways" do
      sign_in(owner)
      get member_agent_path(host), params: { tab: "details", runtimes_sort: "name" }
      ordered?(response.body, "Node", "ruby")

      get member_agent_path(host), params: { tab: "details", runtimes_sort: "-name" }
      ordered?(response.body, "ruby", "Node")
    end
  end

  describe "GET /member/datasets" do
    let(:project) { create(:project, organization: org) }
    let!(:zeta) { create(:dataset, project:, name: "Zeta receipts") }
    let!(:alpha) { create(:dataset, project:, name: "alpha invoices") }

    it "sorts by name both ways" do
      sign_in(owner)
      get member_datasets_path, params: { sort: "name" }
      ordered?(response.body, "alpha invoices", "Zeta receipts")

      get member_datasets_path, params: { sort: "-name" }
      ordered?(response.body, "Zeta receipts", "alpha invoices")
    end

    it "renders sortable headers for every column" do
      sign_in(owner)
      get member_datasets_path
      %w[name project columns status created].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end
  end

  describe "GET /member/knowledge/reviews" do
    it "sorts the pages to re-read and the rejected ones by title" do
      create(:knowledge_page, organization: org, title: "Zeta stale", created_by: owner, review_after: 2.days.ago)
      create(:knowledge_page, organization: org, title: "alpha stale", created_by: owner, review_after: 1.day.ago)
      create(:knowledge_page, :rejected, organization: org, title: "Zeta refused", created_by: owner)
      create(:knowledge_page, :rejected, organization: org, title: "alpha refused", created_by: owner)
      sign_in(owner)

      get member_knowledge_reviews_path, params: { needs_review_sort: "page", rejected_sort: "page" }
      ordered?(response.body, "alpha stale", "Zeta stale")
      ordered?(response.body, "alpha refused", "Zeta refused")

      get member_knowledge_reviews_path, params: { needs_review_sort: "-page", rejected_sort: "-page" }
      ordered?(response.body, "Zeta stale", "alpha stale")
      ordered?(response.body, "Zeta refused", "alpha refused")
    end
  end
end
