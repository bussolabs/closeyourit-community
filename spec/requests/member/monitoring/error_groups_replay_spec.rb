# frozen_string_literal: true

require "rails_helper"

# Player session replay nella show errori: l'azione GET replay serve gli eventi rrweb uniti (JSON)
# della sessione dell'occorrenza, risolta SOLO entro il progetto del gruppo visibile (anti-BOLA).
RSpec.describe "Member::Monitoring::ErrorGroups replay", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:group) { create(:error_group, project:) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    Types::InstallDefaults.call(organization: org)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def attach_chunk(session, seq, events)
    gz = ActiveSupport::Gzip.compress(JSON.generate(events))
    session.chunks.attach(io: StringIO.new(gz), filename: "#{session.replay_session_id}-#{seq}.json.gz",
                          content_type: "application/gzip")
  end

  it "serve gli eventi rrweb uniti, ordinati per seq" do
    session = project.replay_sessions.create!(replay_session_id: "sess-x", started_at: Time.current)
    attach_chunk(session, 1, [ { "type" => 4 } ])   # attaccato per primo ma seq successivo
    attach_chunk(session, 0, [ { "type" => 2 }, { "type" => 3 } ])

    sign_in(owner)
    get replay_member_monitoring_error_group_path(group, rid: "sess-x")

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "events")).to eq(
      [ { "type" => 2 }, { "type" => 3 }, { "type" => 4 } ]
    )
  end

  it "404 quando non esiste una sessione per quel rid nel progetto" do
    sign_in(owner)
    get replay_member_monitoring_error_group_path(group, rid: "assente")
    expect(response).to have_http_status(:not_found)
  end

  it "404 quando rid è vuoto" do
    sign_in(owner)
    get replay_member_monitoring_error_group_path(group, rid: "")
    expect(response).to have_http_status(:not_found)
  end

  it "BOLA: un rid che esiste in un ALTRO progetto non è raggiungibile via questo gruppo" do
    other_project = create(:project, organization: org)
    other_session = other_project.replay_sessions.create!(replay_session_id: "sess-other", started_at: Time.current)
    attach_chunk(other_session, 0, [ { "type" => 2 } ])

    sign_in(owner)
    get replay_member_monitoring_error_group_path(group, rid: "sess-other")
    expect(response).to have_http_status(:not_found)
  end

  it "gruppo di un'altra org → RecordNotFound (set_group anti-BOLA)" do
    other_org = create(:organization)
    other_group = create(:error_group, project: create(:project, organization: other_org))

    sign_in(owner)
    get replay_member_monitoring_error_group_path(other_group, rid: "sess-x")
    expect(response).to have_http_status(:not_found)
  end

  describe "rendering della show" do
    it "mostra il player quando l'occorrenza ha un replay registrato" do
      create(:error_event, group:, project:, replay_session_id: "sess-x")
      session = project.replay_sessions.create!(replay_session_id: "sess-x", started_at: Time.current)
      attach_chunk(session, 0, [ { "type" => 2 } ])

      sign_in(owner)
      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="error-replay-player"')
    end

    it "NON mostra il player quando l'occorrenza non ha replay" do
      create(:error_event, group:, project:)

      sign_in(owner)
      get member_monitoring_error_group_path(group)

      expect(response.body).not_to include('data-test="error-replay-player"')
    end
  end

  # CYRA-52: un indicatore (icona play) sulla riga occorrenza segnala subito quali hanno un replay,
  # senza dover aprire ogni occorrenza per scrutare la colonna Session replay.
  describe "indicatore replay nella riga occorrenza" do
    it "mostra l'indicatore SOLO sulle occorrenze con un replay effettivamente registrato" do
      create(:error_event, group:, project:, replay_session_id: "sess-x")
      create(:error_event, group:, project:)                              # nessun replay_session_id
      create(:error_event, group:, project:, replay_session_id: "sess-orphan") # id ma nessuna sessione
      project.replay_sessions.create!(replay_session_id: "sess-x", started_at: Time.current)

      sign_in(owner)
      get member_monitoring_error_group_path(group)

      expect(response).to have_http_status(:ok)
      # una sola delle tre righe (quella con la Replays::Session) porta l'indicatore
      expect(response.body.scan('data-test="occurrence-replay-indicator"').size).to eq(1)
    end

    it "l'indicatore espone un aria-label accessibile" do
      create(:error_event, group:, project:, replay_session_id: "sess-x")
      project.replay_sessions.create!(replay_session_id: "sess-x", started_at: Time.current)

      sign_in(owner)
      get member_monitoring_error_group_path(group)

      expect(response.body).to include("aria-label=\"#{I18n.t('member.monitoring.replay.available')}\"")
    end

    it "nessun indicatore quando nessuna occorrenza ha un replay registrato" do
      create(:error_event, group:, project:, replay_session_id: "sess-orphan") # id senza sessione
      create(:error_event, group:, project:)                                   # senza id

      sign_in(owner)
      get member_monitoring_error_group_path(group)

      expect(response.body).not_to include('data-test="occurrence-replay-indicator"')
    end
  end

  # CYRA-376 — il legame errore ↔ sessione registrata compariva SOLO dove una registrazione c'era
  # già: chi non ne aveva nemmeno sospettava che quel legame esistesse. Il blocco ora resta e dice
  # «nessuna», come fa quello dei log della stessa richiesta.
  describe "blocco delle sessioni collegate all'errore" do
    def pagina
      Nokogiri::HTML(response.body)
    end

    it "senza registrazione collegata il blocco resta e lo dice" do
      create(:error_event, group:, project:)
      sign_in(owner)
      get member_monitoring_error_group_path(group)

      expect(pagina.at_css('[data-test="error-replay-none"]')).to be_present
    end

    it "senza nemmeno un'occorrenza il blocco c'è lo stesso" do
      sign_in(owner)
      get member_monitoring_error_group_path(group)

      expect(pagina.at_css('[data-test="error-replay-none"]')).to be_present
    end

    it "sui progetti che possono registrare il blocco vuoto porta all'interruttore" do
      project.platforms << create(:platform, organization: org, supports_session_replay: true)
      create(:error_event, group:, project:)
      sign_in(owner)
      get member_monitoring_error_group_path(group)

      cta = pagina.at_css('[data-test="error-replay-activate"]')
      expect(cta).to be_present
      expect(cta["href"]).to eq(member_project_settings_path(project))
    end

    it "su un progetto senza piattaforma web non promette un interruttore che non c'è" do
      create(:error_event, group:, project:)
      sign_in(owner)
      get member_monitoring_error_group_path(group)

      expect(pagina.at_css('[data-test="error-replay-activate"]')).to be_nil
    end

    it "con la registrazione mostra il player, non la dicitura «nessuna»" do
      create(:error_event, group:, project:, replay_session_id: "sess-x")
      project.replay_sessions.create!(replay_session_id: "sess-x", started_at: Time.current)

      sign_in(owner)
      get member_monitoring_error_group_path(group)

      expect(pagina.at_css('[data-test="error-replay-player"]')).to be_present
      expect(pagina.at_css('[data-test="error-replay-none"]')).to be_nil
    end
  end
end
