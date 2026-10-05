# frozen_string_literal: true

require "rails_helper"

# CYRA-822 — il confronto misurato: quanto lavoro evita, a chi sta guardando un solo progetto, non
# ricevere più i segnali di aggiornamento nati negli altri.
#
# COME È FATTA LA MISURA, ed è il punto: le due situazioni — «prima» e «dopo» — si osservano nello
# STESSO giro, senza ripristinare il codice vecchio. Il mittente emette su due livelli, quello
# dell'organizzazione e quello del progetto dell'evento; la lista filtrata prima ascoltava il primo
# e adesso ascolta il secondo. Contare i segnali arrivati su entrambi durante la stessa raffica dà
# quindi, con la stessa aritmetica, il traffico di ieri e quello di oggi.
#
# I DUE NUMERI RESTANO DUE: i segnali consegnati sono misurati sul canale; le richieste al minuto
# sono il prodotto per il numero di sessioni, che il confronto DICHIARA (aprire venticinque browser
# non cambierebbe il conto — ogni sessione ri-chiede la propria pagina una volta per segnale — e
# renderebbe la prova lenta e fragile). Il registro scrive le sessioni accanto al risultato.
#
# DOVE SI RILEGGE: `tmp/performance/aggiornamenti-lista-per-progetto.json`, con ambiente, revisione,
# volume e numerosità dei campioni.
RSpec.describe "Aggiornamenti di lista per progetto", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project_a) { create(:project, organization: org, name: "Alfa") }
  let(:project_b) { create(:project, organization: org, name: "Beta") }
  let(:group_b) { create(:error_group, project: project_b) }
  let(:group_a) { create(:error_group, project: project_a) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    # In prova la cache è null_store: ogni scrittura «riesce», quindi il throttle non esisterebbe e
    # ogni evento diventerebbe un segnale. MemoryStore riproduce la semantica reale di `unless_exist`
    # ed è l'unica condizione in cui i conteggi qui sotto vogliono dire qualcosa.
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    # L'orologio parte su un secondo tondo. `travel` tronca i microsecondi: partendo da 10,5 un
    # avanzamento di un secondo porta a 11,0 e una finestra aperta a 10,5 NON risulterebbe scaduta —
    # la prima finestra della misura si comporterebbe diversamente da tutte le altre.
    travel_to(Time.current.change(usec: 0))
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  after(:context) { BroadcastFanout.write!("aggiornamenti-lista-per-progetto") }

  # Le sessioni del confronto: quante persone stanno guardando, e cosa. Numeri dichiarati, non
  # simulati — è la scala su cui si legge il risparmio, e sta nel registro perché si veda.
  def sessioni_filtrate = 25
  def sessioni_organizzazione = 5

  # La raffica: un minuto a dieci eventi al secondo. Il ritmo è dell'ordine di quello misurato nella
  # raffica vera del 2026-07-29 (7,7 occorrenze al secondo), e un minuto è la finestra in cui si
  # legge il risultato — «richieste al minuto».
  def durata_secondi = 60
  def eventi_al_secondo = 10
  def volume_eventi = durata_secondi * eventi_al_secondo

  def impostazione_confronto
    { finestra_di_throttle_secondi: Monitoring::Constants::BROADCAST_THROTTLE.to_i,
      tetto_progetti_sottoscritti: Monitoring::Constants::LIST_STREAM_PROJECT_CAP,
      durata_secondi: durata_secondi, eventi_al_secondo: eventi_al_secondo,
      sessioni_filtrate: sessioni_filtrate, sessioni_organizzazione: sessioni_organizzazione }
  end

  def registro = BroadcastFanout.ledger("aggiornamenti-lista-per-progetto", setup: impostazione_confronto)

  def subscribed_streams(body)
    body.scan(/signed-stream-name="([^"]+)"/).flatten
        .filter_map { |name| Turbo::StreamsChannel.verified_stream_name(name) }
  end

  # Gli stream a cui si iscrive davvero una lista errori aperta con questi parametri: si prendono
  # dalla pagina renderizzata, non dai nomi dell'implementazione — è ciò che riceve chi guarda.
  def streams_della_lista(**params)
    get member_monitoring_error_groups_path, params: params
    expect(response).to have_http_status(:ok)
    subscribed_streams(response.body).tap do |streams|
      expect(streams).not_to be_empty, "la lista non si iscrive a nulla: la misura sarebbe cieca"
    end
  end

  # Gli stream che una raffica di errori tocca davvero: la lista dell'organizzazione, la lista del
  # progetto dell'evento (il livello aggiunto) e la scheda del gruppo.
  def streams_del_mittente
    [ Realtime::Streams.errors(org), Realtime::Streams.project_errors_list(project_b),
      Realtime::Streams.error_group(group_b) ]
  end

  # Un minuto di raffica sul gruppo indicato, al ritmo dichiarato. Il tempo avanza davvero (le
  # finestre di throttle scadono) e le lavorazioni differite girano a fine finestra, come farebbe il
  # worker: contarne solo il ramo immediato direbbe metà di ciò che arriva a chi guarda.
  def raffica(group)
    lavorazioni = 0
    durata_secondi.times do
      eventi_al_secondo.times { Errors::Broadcast.refresh(group) }
      travel 1.second
      lavorazioni += run_pending_refresh_jobs
    end
    lavorazioni
  end

  # Scenario 1 del ticket: sto guardando Alfa, la raffica è in Beta. Il DoD chiede che gli eventi
  # estranei non causino nuove richieste della lista filtrata — qui si conta che non ne causino
  # NESSUNA, e nello stesso giro quante ne causavano prima (il livello dell'organizzazione, che la
  # lista filtrata ascoltava e adesso non ascolta più).
  it "una raffica in un altro progetto non fa ri-chiedere la lista filtrata" do
    filtrata = streams_della_lista(project_id: project_a.id)
    # `ft` è il marker della toolbar: «questo indirizzo dichiara i filtri, anche vuoti». Senza, la
    # lista ripristinerebbe il filtro appena usato (CYRA-694) e questa sarebbe la stessa sessione
    # di prima, non quella di chi guarda tutta l'organizzazione.
    organizzazione = streams_della_lista(ft: 1)
    group_b # creato prima della misura: la sua scrittura non è traffico da contare
    clear_signals

    lavorazioni = raffica(group_b)
    segnali_filtrata = signals_on(filtrata)
    segnali_organizzazione = signals_on(organizzazione)
    # Il conto del mittente: tutti gli stream che la raffica tocca davvero — l'organizzazione, il
    # progetto dell'evento, la scheda del gruppo — più le lavorazioni messe in coda. È il prezzo del
    # livello in più, e va nel registro insieme al risparmio, non al posto suo.
    messaggi_emessi = signals_on(streams_del_mittente)
    livello_nuovo = signals_on(Realtime::Streams.project_errors_list(project_b))

    registro.record(observer: "lista_filtrata", operation: "raffica_estranea", events: volume_eventi,
                    sessions: sessioni_filtrate, signals: segnali_filtrata)
    registro.record(observer: "lista_organizzazione", operation: "raffica_estranea",
                    events: volume_eventi, sessions: sessioni_organizzazione,
                    signals: segnali_organizzazione)
    registro.record(observer: "mittente", operation: "raffica_estranea", events: volume_eventi,
                    sessions: 0, signals: 0, broadcasts: messaggi_emessi, jobs: lavorazioni)

    expect(segnali_filtrata).to eq(0)
    expect(segnali_organizzazione).to be_positive
    # Il costo del livello nuovo è quello di UN livello: cresce col numero di livelli, non col
    # numero di sessioni connesse né col numero di progetti dell'organizzazione — che è la ragione
    # per cui questo scambio conviene.
    expect(livello_nuovo).to eq(segnali_organizzazione)
  end

  # Scenario 2: la raffica è nel progetto che sto guardando. Gli aggiornamenti si raggruppano — un
  # segnale per finestra, non uno per evento — ma l'ultimo stato deve arrivare comunque.
  it "una raffica pertinente si raggruppa e l'ultimo stato arriva lo stesso" do
    filtrata = streams_della_lista(project_id: project_a.id)
    group_a
    clear_signals

    lavorazioni = raffica(group_a)
    segnali = signals_on(filtrata)

    registro.record(observer: "lista_filtrata", operation: "raffica_pertinente", events: volume_eventi,
                    sessions: sessioni_filtrate, signals: segnali, jobs: lavorazioni)

    expect(segnali).to be_positive
    # Raggruppati: molto meno di un segnale per evento. Il tetto è il doppio delle finestre trascorse
    # — un segnale immediato più uno di chiusura per finestra — e resta lontanissimo dal volume.
    expect(segnali).to be <= durata_secondi * 2
    expect(segnali).to be < volume_eventi
  end

  # «L'ultimo stato è visibile senza perdere l'evento finale»: dopo che la raffica si è fermata deve
  # arrivare ancora un segnale, quello che chiude la finestra. Senza, la pagina resterebbe ferma
  # all'istante in cui la raffica è cominciata.
  it "dopo l'ultimo evento arriva il segnale di chiusura" do
    filtrata = streams_della_lista(project_id: project_a.id)
    group_a
    clear_signals

    3.times { Errors::Broadcast.refresh(group_a) }
    prima_della_chiusura = signals_on(filtrata)
    travel 1.second
    run_pending_refresh_jobs

    expect(prima_della_chiusura).to eq(1)
    expect(signals_on(filtrata)).to eq(2)
  end

  # Riconnessione: la pagina ricaricata ascolta lo STESSO stream (il nome è derivato dal progetto,
  # non da qualcosa di volatile) e i segnali successivi continuano ad arrivare. Un nome che cambiasse
  # a ogni carico lascerebbe la lista in ascolto di un canale su cui non parla più nessuno.
  it "dopo una riconnessione la lista filtrata continua a ricevere gli aggiornamenti" do
    prima = streams_della_lista(project_id: project_a.id)
    group_a
    Errors::Broadcast.refresh(group_a)
    travel 1.second
    run_pending_refresh_jobs

    dopo = streams_della_lista(project_id: project_a.id)
    expect(dopo).to match_array(prima)

    clear_signals
    Errors::Broadcast.refresh(group_a)
    segnali = signals_on(dopo)

    registro.record(observer: "lista_filtrata", operation: "riconnessione", events: 1,
                    sessions: sessioni_filtrate, signals: segnali)

    expect(segnali).to be_positive
  end

  it "il registro del confronto si scrive con sessioni, volume e lavoro del mittente" do
    registro.record(observer: "lista_filtrata", operation: "raffica_estranea", events: 1,
                    sessions: sessioni_filtrate, signals: 0)
    percorso = registro.write!

    documento = JSON.parse(percorso.read)
    expect(documento["impostazione"]).to include("sessioni_filtrate" => sessioni_filtrate,
                                                 "eventi_al_secondo" => eventi_al_secondo)
    expect(documento["campioni"].first).to include("segnali_ricevuti", "richieste_al_minuto",
                                                   "sessioni", "eventi")
  end

  it "nel registro non può entrare un osservatore fuori elenco (niente contenuti)" do
    expect { registro.record(observer: "titolo dell'errore", operation: "raffica_estranea",
                             events: 1, sessions: 1, signals: 0) }
      .to raise_error(ArgumentError, /osservatore sconosciuto/)
  end
end
