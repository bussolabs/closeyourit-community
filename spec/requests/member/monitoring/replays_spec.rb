# frozen_string_literal: true

require "rails_helper"

# Galleria session replay (Member): sfoglia le sessioni dei progetti VISIBILI (anti-BOLA), guardane
# una col player standalone. Read = visibilità di scope (nessuna permission key).
RSpec.describe "Member::Monitoring::Replays", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def session!(over = {})
    project.replay_sessions.create!(
      { replay_session_id: "sess-#{SecureRandom.hex(4)}", started_at: 2.minutes.ago,
        ended_at: 1.minute.ago, duration_ms: 60_000, events_count: 10,
        environment: "production", entry_path: "/home", pages: [ "/home", "/checkout" ],
        user_hash: "abcdef0123456789" }.merge(over)
    )
  end

  describe "GET index" do
    it "lista le sessioni dei progetti visibili" do
      s = session!
      sign_in(owner)
      get member_monitoring_replays_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(id="#{ActionView::RecordIdentifier.dom_id(s)}"))
    end

    # F080 — every row was titled "Session": the title now says when it started, so two rows differ.
    it "titles a session with the day and time it started" do
      s = session!(started_at: Time.zone.local(2026, 10, 2, 14, 5))
      sign_in(owner)
      get member_monitoring_replays_path

      title = Capybara.string(response.body).find("[data-test='replay-link-#{s.id}'] [data-test='replay-title']")
      expect(title.text.strip).to eq("Session · 02/10 14:05")
    end

    # D12 — zero errors is a number; a dash is for what was not recorded, and says so on hover.
    it "writes zero errors as 0 and names what a dash stands for" do
      s = session!(user_hash: nil, entry_path: nil)
      sign_in(owner)
      get member_monitoring_replays_path

      row = Capybara.string(response.body).find("##{ActionView::RecordIdentifier.dom_id(s)}")
      expect(row.find("[data-test='replay-errors-none']").text).to eq("0")
      expect(row.find("[data-test='replay-user-unknown']")[:title]).to eq(I18n.t("member.monitoring.replays.user_unknown"))
      expect(row.find("[data-test='replay-entry-unknown']")[:title]).to eq(I18n.t("member.monitoring.replays.entry_unknown"))
    end

    # «circa 4 ore» senza «fa» non dice se è passato o durata; e su due righe si legge male.
    it "l'inizio si legge come «… fa», su una riga" do
      s = session!(started_at: 4.hours.ago)
      sign_in(owner)
      get member_monitoring_replays_path

      cell = Nokogiri::HTML(response.body).at_css("[data-test='replay-started-#{s.id}']")
      expect(cell.text.strip).to eq(I18n.t("member.monitoring.time_ago", time: "about 4 hours"))
      expect(cell["class"]).to include("whitespace-nowrap")
    end

    it "filtra per ambiente" do
      prod = session!(environment: "production")
      stag = session!(environment: "staging")
      sign_in(owner)
      get member_monitoring_replays_path(environment: [ "staging" ])

      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(stag))
      expect(response.body).not_to include(ActionView::RecordIdentifier.dom_id(prod))
    end

    it "filtra 'solo con errori'" do
      with_err = session!(replay_session_id: "with-err")
      _without = session!(replay_session_id: "no-err")
      create(:error_event, project:, group: create(:error_group, project:), replay_session_id: "with-err")

      sign_in(owner)
      get member_monitoring_replays_path(with_errors: "1")
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(with_err))
      expect(response.body).not_to include("no-err")
    end

    it "BOLA: non lista le sessioni di progetti non visibili" do
      other = create(:project, organization: create(:organization))
      hidden = other.replay_sessions.create!(replay_session_id: "hidden", started_at: 1.minute.ago)

      sign_in(owner)
      get member_monitoring_replays_path
      expect(response.body).not_to include(ActionView::RecordIdentifier.dom_id(hidden))
    end
  end

  # CYRA-376 — la pagina esisteva ma non era collegata a niente, e chi la trovava leggeva quando le
  # sessioni compaiono senza sapere come attivarle: nessuna strada verso l'interruttore, nessun
  # elenco dei progetti che lo avevano già acceso.
  describe "la funzione si trova e si attiva" do
    def empty_state
      Nokogiri::HTML(response.body)
    end

    it "la voce del menu porta qui anche quando nessun progetto registra ancora" do
      sign_in(owner)
      get member_monitoring_replays_path

      voce = empty_state.at_css('[data-test="member-nav-replays"]')
      expect(voce).to be_present
      expect(voce["href"]).to eq(member_monitoring_replays_path)
    end

    it "senza sessioni invita ad attivare la registrazione sulle impostazioni del progetto" do
      project.platforms << create(:platform, organization: org, supports_session_replay: true)
      sign_in(owner)
      get member_monitoring_replays_path

      cta = empty_state.at_css('[data-test="replays-empty-activate"]')
      expect(cta).to be_present
      expect(cta["href"]).to eq(member_project_settings_path(project))
    end

    it "senza sessioni rimanda alla guida delle registrazioni" do
      sign_in(owner)
      get member_monitoring_replays_path

      guida = empty_state.at_css('[data-test="replays-empty-guide"]')
      expect(guida).to be_present
      expect(guida["href"]).to eq(member_guides_replays_path)
    end

    it "dice su quali progetti la registrazione è già accesa" do
      acceso = create(:project, organization: org, name: "Sito vetrina", session_replay_enabled: true)
      acceso.platforms << create(:platform, organization: org, supports_session_replay: true)
      sign_in(owner)
      get member_monitoring_replays_path

      elenco = empty_state.at_css('[data-test="replays-empty-active-on"]')
      expect(elenco).to be_present
      expect(elenco.text).to include("Sito vetrina")
    end

    it "senza progetti che possono registrare spiega cosa manca, invece di un invito che non porta a niente" do
      project # nessuna piattaforma web dichiarata
      sign_in(owner)
      get member_monitoring_replays_path

      expect(empty_state.at_css('[data-test="replays-empty-activate"]')).to be_nil
      expect(empty_state.at_css('[data-test="replays-empty-no-web"]')).to be_present
    end

    it "chi non può cambiare le impostazioni del progetto non riceve un invito verso una porta chiusa" do
      project.platforms << create(:platform, organization: org, supports_session_replay: true)
      viewer = create(:account)
      create(:membership, account: viewer, organization: org, role: :member)
      create(:project_membership, account: viewer, project: project)

      sign_in(viewer)
      get member_monitoring_replays_path

      expect(response).to have_http_status(:ok)
      expect(empty_state.at_css('[data-test="replays-empty-activate"]')).to be_nil
    end

    it "con sessioni registrate l'invito sparisce: la pagina mostra l'elenco" do
      session!
      sign_in(owner)
      get member_monitoring_replays_path

      expect(empty_state.at_css('[data-test="replays-empty"]')).to be_nil
      expect(empty_state.at_css('[data-test="replays-table"]')).to be_present
    end
  end

  describe "GET show + player" do
    def attach_chunk(sess, events)
      gz = ActiveSupport::Gzip.compress(JSON.generate(events))
      sess.chunks.attach(io: StringIO.new(gz), filename: "#{sess.replay_session_id}-0.json.gz",
                         content_type: "application/gzip")
    end

    it "rende il player + i dettagli" do
      s = session!(user_hash: "u123", entry_path: "/dashboard")
      sign_in(owner)
      get member_monitoring_replay_path(s)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="replay-player"')
      expect(response.body).to include("/dashboard")
    end

    it "player ritorna gli eventi rrweb uniti (JSON)" do
      s = session!
      attach_chunk(s, [ { "type" => 2 }, { "type" => 3 } ])
      sign_in(owner)
      get player_member_monitoring_replay_path(s)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "events")).to eq([ { "type" => 2 }, { "type" => 3 } ])
    end

    it "BOLA: sessione di altra org → RecordNotFound" do
      other = create(:project, organization: create(:organization))
      hidden = other.replay_sessions.create!(replay_session_id: "hidden", started_at: 1.minute.ago)

      sign_in(owner)
      get member_monitoring_replay_path(hidden)
      expect(response).to have_http_status(:not_found)
    end
  end
end
