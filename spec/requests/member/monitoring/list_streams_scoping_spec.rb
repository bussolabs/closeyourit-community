# frozen_string_literal: true

require "rails_helper"

# CYRA-822 — a quale segnale di aggiornamento si iscrive una lista dell'area di controllo.
#
# Il segnale di aggiornamento è un page-refresh: chi lo riceve ri-chiede la propria pagina con la
# propria sessione. È il meccanismo che tiene fuori i contenuti altrui (CYRA-257/271), ma ha un
# costo: ogni segnale è una richiesta HTTP in più per ogni sessione connessa. Finché lo stream era
# uno solo per organizzazione, una raffica nel progetto B faceva ri-chiedere la lista anche a chi
# stava guardando il solo progetto A — la stessa risposta di prima, ottenuta con lo stesso lavoro.
#
# Qui si verifica il READ-SIDE di quella scelta: a quali stream la pagina si iscrive davvero. Il
# WRITE-SIDE (chi emette il segnale e su quali stream) sta negli spec dei tre Broadcast; la misura
# del lavoro risparmiato in spec/requests/member/monitoring/list_refresh_fanout_spec.rb.
RSpec.describe "Sottoscrizioni delle liste di controllo", type: :request do
  # Le tre liste che ricevono telemetria ad alto volume, ognuna col suo stream org-wide e con quello
  # per progetto. Un solo elenco: le tre pagine devono comportarsi allo stesso modo, e una prova
  # scritta tre volte a mano è il posto dove quella regola si perde.
  def self.liste
    {
      "errori" => {
        path: :member_monitoring_error_groups_path,
        org_stream: ->(org) { Realtime::Streams.errors(org) },
        project_stream: ->(project) { Realtime::Streams.project_errors_list(project) }
      },
      "prestazioni" => {
        path: :member_monitoring_metric_groups_path,
        org_stream: ->(org) { Realtime::Streams.metrics(org) },
        project_stream: ->(project) { Realtime::Streams.project_metrics_list(project) }
      },
      "log" => {
        path: :member_monitoring_log_entries_path,
        org_stream: ->(org) { Realtime::Streams.logs(org) },
        project_stream: ->(project) { Realtime::Streams.project_logs_list(project) }
      }
    }
  end

  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:project_a) { create(:project, organization: org, name: "Alfa") }
  let(:project_b) { create(:project, organization: org, name: "Beta") }

  # I due progetti esistono PRIMA della richiesta: senza, l'assenza di una sottoscrizione non
  # proverebbe niente — non ci sarebbe nemmeno il progetto a cui iscriversi.
  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:membership, account: member, organization: org, role: :member)
    project_a
    project_b
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Gli stream a cui la pagina si è iscritta, decodificati dal nome firmato: la vista non stampa mai
  # il nome in chiaro, quindi confrontare stringhe nel corpo non direbbe niente.
  def subscribed_streams(body)
    body.scan(/signed-stream-name="([^"]+)"/).flatten
        .filter_map { |name| Turbo::StreamsChannel.verified_stream_name(name) }
  end

  liste.each do |nome, lista|
    describe "lista #{nome}" do
      let(:org_stream) { lista[:org_stream].call(org) }
      let(:stream_a) { lista[:project_stream].call(project_a) }
      let(:stream_b) { lista[:project_stream].call(project_b) }
      let(:path) { public_send(lista[:path]) }

      it "senza filtro si iscrive al segnale dell'organizzazione, non a uno per progetto" do
        sign_in(owner)
        get path

        expect(response).to have_http_status(:ok)
        streams = subscribed_streams(response.body)
        expect(streams).to include(org_stream)
        expect(streams).not_to include(stream_a)
        expect(streams).not_to include(stream_b)
      end

      # Scenario 1 del ticket, letto dal lato di chi guarda: iscritti al solo progetto osservato,
      # l'organizzazione non è più fra i mittenti — quindi una raffica in Beta non arriva.
      it "con un progetto selezionato si iscrive SOLO al segnale di quel progetto" do
        sign_in(owner)
        get path, params: { project_id: project_a.id }

        streams = subscribed_streams(response.body)
        expect(streams).to include(stream_a)
        expect(streams).not_to include(org_stream)
        expect(streams).not_to include(stream_b)
      end

      it "con due progetti selezionati si iscrive a entrambi e a nessun altro" do
        sign_in(owner)
        get path, params: { project_id: [ project_a.id, project_b.id ] }

        streams = subscribed_streams(response.body)
        expect(streams).to include(stream_a, stream_b)
        expect(streams).not_to include(org_stream)
      end

      # Molti progetti selezionati insieme: una sottoscrizione per progetto costerebbe più del
      # segnale che evita, quindi sopra il tetto si torna al segnale unico dell'organizzazione.
      it "oltre il tetto di progetti torna al segnale unico dell'organizzazione" do
        stub_const("Monitoring::Constants::LIST_STREAM_PROJECT_CAP", 1)
        sign_in(owner)
        get path, params: { project_id: [ project_a.id, project_b.id ] }

        streams = subscribed_streams(response.body)
        expect(streams).to include(org_stream)
        expect(streams).not_to include(stream_a)
        expect(streams).not_to include(stream_b)
      end

      # Il segnale non porta contenuti, ma dice che in quel progetto è successo qualcosa: chi il
      # progetto non lo vede non deve poterselo iscrivere scrivendone l'identificativo nell'indirizzo.
      it "un progetto non visibile non diventa una sottoscrizione" do
        create(:project_membership, account: member, project: project_a)
        sign_in(member)
        get path, params: { project_id: project_b.id }

        streams = subscribed_streams(response.body)
        expect(streams).not_to include(stream_b)
        expect(streams).to include(org_stream)
      end

      it "un identificativo di progetto inesistente non lascia la pagina senza aggiornamenti" do
        sign_in(owner)
        get path, params: { project_id: SecureRandom.uuid }

        expect(response).to have_http_status(:ok)
        expect(subscribed_streams(response.body)).to include(org_stream)
      end

      # I filtri si ricordano fra una visita e l'altra (CYRA-694): togliere il progetto deve
      # riportare la pagina ad ascoltare tutta l'organizzazione, o resterebbe in ascolto di un
      # progetto solo mentre ne mostra tutti. `ft` è il marker della toolbar: filtri dichiarati,
      # anche vuoti.
      it "togliendo il filtro torna al segnale dell'organizzazione" do
        sign_in(owner)
        get path, params: { project_id: project_a.id }
        get path, params: { ft: 1 }

        streams = subscribed_streams(response.body)
        expect(streams).to include(org_stream)
        expect(streams).not_to include(stream_a)
      end

      # Il permesso può sparire mentre la pagina è aperta. La sottoscrizione resta quella di prima
      # fino al carico successivo, ma porta solo un segnale: al ri-carico è il controller a decidere
      # di nuovo, e da lì la pagina non ascolta più quel progetto.
      it "revocata la visibilità, il carico successivo non ascolta più quel progetto" do
        assegnazione = create(:project_membership, account: member, project: project_a)
        sign_in(member)
        get path, params: { project_id: project_a.id }
        expect(subscribed_streams(response.body)).to include(stream_a)

        assegnazione.destroy!
        get path, params: { project_id: project_a.id }

        streams = subscribed_streams(response.body)
        expect(streams).not_to include(stream_a)
        expect(streams).to include(org_stream)
      end

      it "resta il page-refresh morph: è la GET del viewer a ri-renderizzare, non il mittente" do
        sign_in(owner)
        get path, params: { project_id: project_a.id }

        expect(response.body).to include('name="turbo-refresh-method"', 'content="morph"')
      end
    end
  end

  # Sugli errori il segnale non è l'unica cosa che viaggia: il triage manda anche la riga
  # renderizzata, su uno stream per progetto (CYRA-271). Segue lo stesso confine del segnale — chi
  # guarda un solo progetto non ha in pagina le righe degli altri, quindi non ha ragione di riceverle.
  describe "righe renderizzate degli errori" do
    it "senza filtro resta iscritta alle righe di tutti i progetti visibili" do
      sign_in(owner)
      get member_monitoring_error_groups_path

      streams = subscribed_streams(response.body)
      expect(streams).to include(Realtime::Streams.project_errors(project_a))
      expect(streams).to include(Realtime::Streams.project_errors(project_b))
    end

    it "con un progetto selezionato riceve le righe del solo progetto osservato" do
      sign_in(owner)
      get member_monitoring_error_groups_path, params: { project_id: project_a.id }

      streams = subscribed_streams(response.body)
      expect(streams).to include(Realtime::Streams.project_errors(project_a))
      expect(streams).not_to include(Realtime::Streams.project_errors(project_b))
    end
  end

  # CYRA-1040 — the cron list used to receive every row on the org stream.
  describe "rendered rows of the cron monitors" do
    it "subscribes to the rows of every visible project" do
      sign_in(owner)
      get member_monitoring_cron_monitors_path

      streams = subscribed_streams(response.body)
      expect(streams).to include(Realtime::Streams.project_crons(project_a))
      expect(streams).to include(Realtime::Streams.project_crons(project_b))
    end

    it "a member scoped to one project does not subscribe to the rows of the other" do
      create(:project_membership, account: member, project: project_a)
      sign_in(member)
      get member_monitoring_cron_monitors_path

      streams = subscribed_streams(response.body)
      expect(streams).to include(Realtime::Streams.project_crons(project_a))
      expect(streams).not_to include(Realtime::Streams.project_crons(project_b))
    end
  end
end
