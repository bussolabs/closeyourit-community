# frozen_string_literal: true

require "rails_helper"

# CYRA-813 — «Avvisi scattati qui» apriva la casella generale (o tutti gli avvisi dei progetti
# collegati): chi indaga un guasto perdeva il riferimento alla macchina scelta. Gli avvisi di una
# macchina si riconoscono dal SOGGETTO della notifica (Servers::Host + id), non dal progetto: i
# server_* nascono org-scoped con project nil, e due macchine possono condividere un progetto.
RSpec.describe "Member::AlertingNotifications — filtro macchina (CYRA-813)", type: :request do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let(:host) { create(:server_host, organization: organization, name: "sentinel") }
  let(:other_host) { create(:server_host, organization: organization, name: "apps") }

  before do
    create(:membership, account: account, organization: organization, role: :owner)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def server_notification(server, **attrs)
    create(:alerting_notification, { organization: organization, account: account, via: :in_app,
                                     subject: server, event_type: :server_down,
                                     title: "Server giù · #{server.name}" }.merge(attrs))
  end

  describe "il collegamento dalla scheda della macchina" do
    it "porta il filtro della macchina, non i suoi progetti" do
      get member_monitoring_server_path(host)

      href = Nokogiri::HTML(response.body).at_css("[data-test='server-see-alerts']")["href"]
      expect(href).to include(member_alerting_notifications_path)
      expect(href).to include("host_id=#{host.id}")
      expect(href).not_to include("project_id")
    end

    it "resta la macchina anche quando ha progetti collegati (scenario 2)" do
      allow_n_plus_one do
        environment = create(:project_environment, project: create(:project, organization: organization))
        create(:environment_host, host: host, project: environment.project, environment: environment.environment)
      end

      get member_monitoring_server_path(host)

      href = Nokogiri::HTML(response.body).at_css("[data-test='server-see-alerts']")["href"]
      expect(href).to include("host_id=#{host.id}")
      expect(href).not_to include("project_id")
    end
  end

  describe "GET index con host_id" do
    it "mostra soltanto gli avvisi della macchina scelta (scenario 1)" do
      server_notification(host, title: "Server giù · sentinel", dedup_key: "cyra813-a")
      server_notification(other_host, title: "Server giù · apps", dedup_key: "cyra813-b")

      get member_alerting_notifications_path(host_id: host.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Server giù · sentinel")
      expect(response.body).not_to include("Server giù · apps")
    end

    it "tiene fuori gli avvisi di un'altra macchina che condivide il progetto (scenario 2)" do
      project = create(:project, organization: organization)
      server_notification(host, project: project, title: "Disco pieno · sentinel", dedup_key: "cyra813-c")
      server_notification(other_host, project: project, title: "Disco pieno · apps", dedup_key: "cyra813-d")

      get member_alerting_notifications_path(host_id: host.id)

      expect(response.body).to include("Disco pieno · sentinel")
      expect(response.body).not_to include("Disco pieno · apps")
    end

    it "tiene fuori gli avvisi che non riguardano macchine" do
      server_notification(host, dedup_key: "cyra813-e")
      create(:alerting_notification, organization: organization, account: account, via: :in_app,
                                     title: "New error · Boom", dedup_key: "cyra813-f")

      get member_alerting_notifications_path(host_id: host.id)

      expect(response.body).not_to include("New error · Boom")
    end

    it "dice quale macchina sta guardando, con un modo per togliere il filtro" do
      server_notification(host, dedup_key: "cyra813-g")

      get member_alerting_notifications_path(host_id: host.id)

      chip = Nokogiri::HTML(response.body).at_css("[data-test='notifications-filter-host']")
      expect(chip).to be_present
      expect(chip.text).to include("sentinel")
      expect(chip.at_css("a")["href"]).to eq(member_alerting_notifications_path)
    end

    it "senza avvisi di quella macchina, lo dice col suo nome invece di mostrare la casella generale" do
      server_notification(other_host, title: "Server giù · apps", dedup_key: "cyra813-h")

      get member_alerting_notifications_path(host_id: host.id)

      expect(response.body).not_to include("Server giù · apps")
      empty = Nokogiri::HTML(response.body).at_css("[data-test='notifications-empty']")
      expect(empty).to be_present
      expect(empty.text).to include("sentinel")
    end

    it "conta le non lette della sola macchina scelta" do
      server_notification(host, read_at: nil, dedup_key: "cyra813-i")
      server_notification(other_host, read_at: nil, dedup_key: "cyra813-j")
      server_notification(other_host, read_at: nil, dedup_key: "cyra813-k")

      get member_alerting_notifications_path(host_id: host.id)

      count = Nokogiri::HTML(response.body).at_css("[data-test='notifications-unread-count']")
      expect(count.text.strip).to eq("1")
    end

    it "offre di togliere i filtri anche quando l'unico filtro è la macchina" do
      server_notification(host, dedup_key: "cyra813-l")

      get member_alerting_notifications_path(host_id: host.id)

      expect(Nokogiri::HTML(response.body).at_css("[data-test='notifications-filter-clear']")).to be_present
    end

    it "il filtro sopravvive quando si applicano gli altri filtri" do
      server_notification(host, dedup_key: "cyra813-m")

      get member_alerting_notifications_path(host_id: host.id)

      form = Nokogiri::HTML(response.body).at_css("[data-test='notifications-filters'] form")
      hidden = form.at_css("input[name='host_id'][type='hidden']")
      expect(hidden).to be_present
      expect(hidden["value"]).to eq(host.id)
    end

    it "le schede per natura conservano la macchina" do
      server_notification(host, dedup_key: "cyra813-n")

      get member_alerting_notifications_path(host_id: host.id)

      href = Nokogiri::HTML(response.body).at_css("[data-test='notifications-nature-systems']")["href"]
      expect(href).to include("host_id=#{host.id}")
    end
  end

  describe "confini" do
    it "non allarga la casella: le notifiche di un altro account restano fuori" do
      other_account = create(:account)
      create(:membership, account: other_account, organization: organization, role: :member)
      create(:alerting_notification, organization: organization, account: other_account, via: :in_app,
                                     subject: host, event_type: :server_down, title: "Altrui · sentinel",
                                     dedup_key: "cyra813-o")

      get member_alerting_notifications_path(host_id: host.id)

      expect(response.body).not_to include("Altrui · sentinel")
    end

    # CYRA-813 (revisione) — il NOME della macchina è un dato della flotta: mostrarlo a chi non ha
    # servers.view direbbe, a un id tirato a indovinare, che quella macchina esiste e come si chiama —
    # anche a casella vuota, dove nessun avviso lo avrebbe mai scritto. Il taglio resta, l'etichetta no.
    it "a chi non può vedere la flotta il filtro resta ma il nome della macchina no" do
      server_notification(host, title: "Server giù · sentinel", dedup_key: "cyra813-r")
      create(:alerting_notification, organization: organization, account: account, via: :in_app,
                                     title: "New error · Boom", dedup_key: "cyra813-s")
      plain = create(:account)
      create(:membership, account: plain, organization: organization, role: :member)
      create(:alerting_notification, organization: organization, account: plain, via: :in_app,
                                     subject: host, event_type: :server_down, title: "Server giù · mio",
                                     dedup_key: "cyra813-t")
      create(:alerting_notification, organization: organization, account: plain, via: :in_app,
                                     title: "New error · mio", dedup_key: "cyra813-u")
      post login_path, params: { email: plain.email, password: "Secret123!" }

      get member_alerting_notifications_path(host_id: host.id)

      expect(response.body).to include("Server giù · mio")
      expect(response.body).not_to include("New error · mio")
      expect(response.body).not_to include("sentinel")
      expect(Nokogiri::HTML(response.body).at_css("[data-test='notifications-filter-host']")).to be_present
    end

    it "con servers.view il nome della macchina compare" do
      role = create(:role, organization: organization, name: "Ops viewer")
      create(:role_permission, role: role, permission_key: "servers.view")
      viewer = create(:account)
      create(:membership, account: viewer, organization: organization, role: :member)
      create(:account_role, account: viewer, organization: organization, role: role)
      create(:alerting_notification, organization: organization, account: viewer, via: :in_app,
                                     subject: host, event_type: :server_down, title: "Server giù · viewer",
                                     dedup_key: "cyra813-v")
      post login_path, params: { email: viewer.email, password: "Secret123!" }

      get member_alerting_notifications_path(host_id: host.id)

      chip = Nokogiri::HTML(response.body).at_css("[data-test='notifications-filter-host']")
      expect(chip.text).to include("sentinel")
    end

    it "una macchina di un'altra organizzazione non mostra il suo nome e non porta a vedere nulla" do
      foreign_host = create(:server_host, organization: create(:organization), name: "estranea")
      server_notification(host, title: "Server giù · sentinel", dedup_key: "cyra813-p")

      get member_alerting_notifications_path(host_id: foreign_host.id)

      expect(response.body).not_to include("estranea")
      expect(response.body).not_to include("Server giù · sentinel")
      expect(Nokogiri::HTML(response.body).at_css("[data-test='notifications-empty']")).to be_present
    end

    it "un identificativo inventato vale come nessun filtro" do
      server_notification(host, title: "Server giù · sentinel", dedup_key: "cyra813-q")

      get member_alerting_notifications_path(host_id: "non-un-uuid")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Server giù · sentinel")
      expect(Nokogiri::HTML(response.body).at_css("[data-test='notifications-filter-host']")).to be_nil
    end
  end
end
