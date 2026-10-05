# frozen_string_literal: true

require "rails_helper"

# CYRA-799 — che cosa vede, di ogni dominio, chi sta guardando: un oggetto che si riceve, non quaranta
# metodi ereditati dalla base dei controller. Qui si prova che ogni elenco discende dai progetti
# visibili (una regola sola, non una per dominio) e che i due elenchi org-level chiedono il verdetto
# al gate dei permessi invece di riscriverne la regola.
RSpec.describe Authorization::VisibleScope do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:visibile) { create(:project, organization: org) }
  let(:nascosto) { create(:project, organization: org) }

  subject(:visible) { described_class.new(account: account, organization: org) }

  # Un member con UN solo progetto collegato: il secondo progetto esiste nella stessa org e non deve
  # comparire in nessun elenco. È la prova che il confine è uno solo e vale per tutti i domini.
  before do
    create(:membership, account: account, organization: org, role: :member)
    create(:project_membership, account: account, project: visibile)
    nascosto
  end

  # Ticket e idee pretendono autore e tipi nella stessa org del progetto (isolamento tenant): la loro
  # factory lo risolve dal transient `organization`, le altre non lo conoscono.
  def crea_su(fabbrica, project)
    attributi = { project: project }
    attributi[:organization] = org if %i[ticket idea].include?(fabbrica)
    create(fabbrica, **attributi)
  end

  # Ogni dominio figlio dei progetti: si crea la stessa risorsa sul progetto visibile e su quello
  # nascosto, e l'elenco deve contenere solo la prima.
  {
    tickets: :ticket,
    ideas: :idea,
    error_groups: :error_group,
    monitors: :uptime_monitor,
    metric_groups: :metric_group,
    cron_monitors: :cron_monitor,
    logs: :log_entry,
    vulnerabilities: :vulnerability_finding,
    runtime_statuses: :vulnerability_runtime_status,
    vulnerability_manifests: :vulnerability_manifest,
    seo_sites: :seo_site,
    datasets: :dataset
  }.each do |dominio, fabbrica|
    it "#{dominio}: solo quelli dei progetti visibili" do
      mio = crea_su(fabbrica, visibile)
      altrui = crea_su(fabbrica, nascosto)
      elenco = visible.public_send(dominio).pluck(:id)

      expect(elenco).to include(mio.id)
      expect(elenco).not_to include(altrui.id)
    end
  end

  it "replay_sessions: solo quelle dei progetti visibili" do
    mia = Replays::Session.create!(project: visibile, replay_session_id: SecureRandom.uuid,
                                   started_at: Time.current)
    Replays::Session.create!(project: nascosto, replay_session_id: SecureRandom.uuid,
                             started_at: Time.current)

    expect(visible.replay_sessions.pluck(:id)).to contain_exactly(mia.id)
  end

  describe "progetti e gruppi" do
    it "projects: solo quelli collegati" do
      expect(visible.projects.pluck(:id)).to contain_exactly(visibile.id)
    end

    it "groups: solo quelli collegati" do
      gruppo = create(:group, organization: org)
      create(:group, organization: org)
      create(:group_membership, account: account, group: gruppo)

      expect(visible.groups.pluck(:id)).to contain_exactly(gruppo.id)
    end
  end

  describe "SEO" do
    it "seo_issues e seo_pages discendono dai siti visibili" do
      sito = create(:seo_site, project: visibile)
      altro = create(:seo_site, project: nascosto)
      mia = create(:seo_issue, site: sito)
      sua = create(:seo_issue, site: altro)
      pagina = create(:seo_page, site: sito)
      altra_pagina = create(:seo_page, site: altro)

      expect(visible.seo_issues.pluck(:id)).to include(mia.id)
      expect(visible.seo_issues.pluck(:id)).not_to include(sua.id)
      expect(visible.seo_pages.pluck(:id)).to include(pagina.id)
      expect(visible.seo_pages.pluck(:id)).not_to include(altra_pagina.id)
    end
  end

  describe "conoscenza" do
    it "pages: le pubblicate visibili; pages_in_review: le stesse, in attesa di decisione" do
      pubblicata = create(:knowledge_page, organization: org, project: visibile, status: :published)
      in_revisione = create(:knowledge_page, organization: org, project: visibile, status: :in_review)
      create(:knowledge_page, organization: org, project: nascosto, status: :published)

      expect(visible.pages.pluck(:id)).to contain_exactly(pubblicata.id)
      expect(visible.pages_in_review.pluck(:id)).to contain_exactly(in_revisione.id)
    end

    it "books: solo quelli con almeno un progetto visibile" do
      mio = create(:knowledge_book, organization: org, project_ids: [ visibile.id ])
      create(:knowledge_book, organization: org, project_ids: [ nascosto.id ])

      expect(visible.books.pluck(:id)).to contain_exactly(mio.id)
    end
  end

  describe "team e carico di lavoro" do
    it "teams: quelli dell'org di cui l'account è membro" do
      team = create(:team, organization: org)
      create(:team, organization: org)
      create(:team_membership, account: account, team: team)

      expect(visible.teams.pluck(:id)).to contain_exactly(team.id)
    end

    it "workload_actions: quelle dei team a cui l'account appartiene" do
      team = create(:team, organization: org)
      create(:team_membership, account: account, team: team)
      mia = create(:workload_action, organization: org, team: team)
      create(:workload_action, organization: org, team: create(:team, organization: org))

      expect(visible.workload_actions.pluck(:id)).to contain_exactly(mia.id)
    end
  end

  # Server e gruppi uptime non sono per-progetto: chi li vede lo decide un permesso, e la regola di
  # quel permesso resta al gate. L'oggetto riceve il verdetto e non lo indovina.
  describe "elenchi org-level (a permesso)" do
    def con_permesso(&permits) = described_class.new(account: account, organization: org, permits_area: permits)

    it "senza verdetto (nessun gate collegato) gli elenchi org-level sono vuoti" do
      create(:server_host, organization: org)
      create(:uptime_group, organization: org)

      expect(visible.servers).to be_empty
      expect(visible.uptime_groups).to be_empty
    end

    it "col verdetto positivo si vedono gli host e i gruppi dell'org" do
      host = create(:server_host, organization: org)
      gruppo = create(:uptime_group, organization: org)
      scope = con_permesso { |_area| true }

      expect(scope.servers.pluck(:id)).to contain_exactly(host.id)
      expect(scope.uptime_groups.pluck(:id)).to contain_exactly(gruppo.id)
    end

    it "il verdetto è chiesto per area: servers aperto non apre i gruppi uptime" do
      create(:server_host, organization: org)
      create(:uptime_group, organization: org)
      scope = con_permesso { |area| area == "servers" }

      expect(scope.servers).not_to be_empty
      expect(scope.uptime_groups).to be_empty
    end

    it "shows the clusters of the organization under the servers verdict (CYAG-22)" do
      cluster = create(:cluster, organization: org)
      create(:cluster)

      expect(visible.clusters).to be_empty
      expect(con_permesso { |area| area == "servers" }.clusters.pluck(:id)).to contain_exactly(cluster.id)
    end

    it "il verdetto si chiede una volta sola per area" do
      chieste = []
      scope = con_permesso { |area| chieste << area; false }
      2.times { scope.servers }

      expect(chieste).to eq([ "servers" ])
    end
  end

  # Il god che sta impersonando qualcun altro: chi guarda davvero è true_account, e lo scope segue lui.
  describe "god via true_account (impersonation)" do
    subject(:visible) do
      described_class.new(account: account, organization: org, true_account: create(:account, god: true))
    end

    it "vede tutti i progetti e tutti i gruppi dell'org, anche senza alcun link" do
      gruppo = create(:group, organization: org)

      expect(visible.projects.pluck(:id)).to contain_exactly(visibile.id, nascosto.id)
      expect(visible.groups.pluck(:id)).to contain_exactly(gruppo.id)
    end

    it "vede tutte le pagine dell'org, filtrate per stato" do
      pubblicata = create(:knowledge_page, organization: org, project: nascosto, status: :published)
      in_revisione = create(:knowledge_page, organization: org, project: nascosto, status: :in_review)

      expect(visible.pages.pluck(:id)).to contain_exactly(pubblicata.id)
      expect(visible.pages_in_review.pluck(:id)).to contain_exactly(in_revisione.id)
    end

    it "vede tutti i book dell'org" do
      book = create(:knowledge_book, organization: org, project_ids: [ nascosto.id ])

      expect(visible.books.pluck(:id)).to contain_exactly(book.id)
    end
  end

  # Senza il ramo god esplicito, un account god resta god: è il comportamento che i service (fuori
  # dalla richiesta web, senza true_account) hanno sempre avuto.
  it "un account god senza true_account vede comunque tutto" do
    account.update!(god: true)

    expect(visible.projects.pluck(:id)).to contain_exactly(visibile.id, nascosto.id)
  end
end
