# frozen_string_literal: true

require "rails_helper"

# CYRA-730 — la vista raggruppata dei log (CYRA-348/CYRA-578): una riga per messaggio invece di una
# per occorrenza, con quante volte è comparso e quando. È la pagina che dice quanti problemi diversi
# ci sono davvero: un raggruppamento sbagliato qui non dà errore, dà un numero falso.
RSpec.describe Logs::GroupedMessages, type: :service do
  let(:project) { create(:project) }
  let(:scope) { Logs::Entry.where(project: project) }

  def entry(fingerprint:, message: "qualcosa", level: :info, occurred_at: Time.current)
    create(:log_entry, project: project, fingerprint: fingerprint, message: message,
                       level: level, occurred_at: occurred_at)
  end

  describe "raggruppamento" do
    it "una riga per impronta, con quante volte è comparsa" do
      2.times { |i| entry(fingerprint: "aaa", occurred_at: i.minutes.ago) }
      entry(fingerprint: "bbb")

      righe = described_class.call(scope: scope).records

      expect(righe.map(&:fingerprint)).to contain_exactly("aaa", "bbb")
      expect(righe.find { |r| r.fingerprint == "aaa" }.count).to eq(2)
    end

    it "dice la prima e l'ultima volta che il messaggio è comparso" do
      primo = 3.hours.ago
      ultimo = 10.minutes.ago
      entry(fingerprint: "aaa", occurred_at: primo)
      entry(fingerprint: "aaa", occurred_at: ultimo)

      riga = described_class.call(scope: scope).records.sole

      expect(riga.first_seen_at).to be_within(1.second).of(primo)
      expect(riga.last_seen_at).to be_within(1.second).of(ultimo)
    end

    # Il messaggio d'esempio è l'occorrenza più recente: è lo stato attuale del guasto, non il primo
    # sintomo di ore fa.
    it "mostra il messaggio e il livello dell'occorrenza più recente" do
      entry(fingerprint: "aaa", message: "vecchio", level: :info, occurred_at: 2.hours.ago)
      entry(fingerprint: "aaa", message: "recente", level: :error, occurred_at: 1.minute.ago)

      riga = described_class.call(scope: scope).records.sole

      expect(riga.message).to eq("recente")
      expect(riga.level).to eq("error")
    end

    # Le righe più vecchie dell'impronta non ce l'hanno: restano fuori invece di finire tutte in un
    # gruppo unico che non vuol dire niente.
    it "lascia fuori le righe senza impronta" do
      entry(fingerprint: nil, message: "riga di prima del raggruppamento")
      entry(fingerprint: "aaa")

      righe = described_class.call(scope: scope).records

      expect(righe.map(&:fingerprint)).to eq([ "aaa" ])
    end

    it "rispetta i filtri già applicati: guarda solo le righe dello scope ricevuto" do
      entry(fingerprint: "aaa", level: :error)
      entry(fingerprint: "bbb", level: :info)

      righe = described_class.call(scope: scope.where(level: :error)).records

      expect(righe.map(&:fingerprint)).to eq([ "aaa" ])
    end

    it "nessuna riga → nessun gruppo, nessuna eccezione" do
      risultato = described_class.call(scope: scope)

      expect(risultato.records).to be_empty
      expect(risultato.total).to eq(0)
    end
  end

  describe "ordine" do
    it "prima i messaggi comparsi più volte" do
      3.times { |i| entry(fingerprint: "tanti", occurred_at: i.minutes.ago) }
      entry(fingerprint: "pochi")

      expect(described_class.call(scope: scope).records.map(&:fingerprint)).to eq(%w[tanti pochi])
    end

    # Senza un secondo criterio l'ordine non è deciso: sfogliando si rivedrebbe un gruppo due volte
    # perdendone un altro.
    it "a parità di occorrenze decide l'impronta, così l'ordine è sempre lo stesso" do
      entry(fingerprint: "bbb")
      entry(fingerprint: "aaa")

      due_letture = 2.times.map { described_class.call(scope: scope).records.map(&:fingerprint) }

      expect(due_letture.first).to eq(%w[aaa bbb])
      expect(due_letture.last).to eq(due_letture.first)
    end
  end

  describe "sfogliare i gruppi (CYRA-578)" do
    before { %w[aaa bbb ccc].each { |fp| entry(fingerprint: fp) } }

    it "il piede dichiara quanti messaggi diversi ci sono, non quante occorrenze" do
      risultato = described_class.call(scope: scope, per: 2)

      expect(risultato.total).to eq(3)
      expect(risultato.total_pages).to eq(2)
    end

    it "la prima pagina porta solo le righe che le competono" do
      expect(described_class.call(scope: scope, per: 2).records.size).to eq(2)
    end

    it "l'ultima pagina porta il resto" do
      risultato = described_class.call(scope: scope, page: 2, per: 2)

      expect(risultato.records.size).to eq(1)
      expect(risultato.page).to eq(2)
    end

    it "una pagina oltre l'ultima ricade sull'ultima invece di tornare vuota" do
      expect(described_class.call(scope: scope, page: 99, per: 2).page).to eq(2)
    end

    # Gli esempi si leggono SOLO per la pagina mostrata: sono la parte cara della vista, e le altre
    # pagine non si vedono. Una lettura per gruppo sarebbe una query per riga.
    it "legge gli esempi con una sola query, non una per gruppo" do
      query = captured_sql { described_class.call(scope: scope, per: 2) }

      expect(query.grep(/DISTINCT ON \(fingerprint\)/i).size).to eq(1)
    end
  end

  # CYRA-794 — quello che costa non è la pagina che si vede, è tutto quello che c'è dietro: prima
  # ogni apertura portava in Rails un aggregato per OGNI messaggio distinto del filtro e li ordinava
  # in memoria, per mostrarne dieci. Adesso ordina e taglia il database.
  describe "costo della pagina (CYRA-794)" do
    it "porta a Rails solo le righe della pagina, non un aggregato per ogni messaggio distinto" do
      10.times { |i| entry(fingerprint: format("fp%02d", i)) }

      query = captured_queries { described_class.call(scope: scope, per: 2) }

      expect(query.map(&:rows).max).to eq(2)
    end

    # Il totale dei messaggi diversi è il piede della pagina: si chiede al database, non contando in
    # memoria le righe che si è appena evitato di portare.
    it "il totale costa una riga sola, qualunque sia lo storico" do
      10.times { |i| entry(fingerprint: format("fp%02d", i)) }

      query = captured_queries { described_class.call(scope: scope, per: 2) }
      conteggio = query.find { |q| q.sql.match?(/COUNT\(DISTINCT/i) }

      expect(conteggio).not_to be_nil
      expect(conteggio.rows).to eq(1)
    end

    it "non conta fra i messaggi diversi le righe senza impronta" do
      entry(fingerprint: nil)
      entry(fingerprint: "aaa")

      expect(described_class.call(scope: scope).total).to eq(1)
    end

    # Nessuna riga: nemmeno la query per sfogliarle. Il conteggio ha già detto che non c'è niente.
    it "storico vuoto: nessun aggregato chiesto al database" do
      risultato = nil
      query = captured_queries { risultato = described_class.call(scope: scope) }

      expect(query.map(&:sql).grep(/GROUP BY/i)).to be_empty
      expect(risultato.records).to be_empty
    end

    it "una pagina sola: ci sono tutti" do
      3.times { |i| entry(fingerprint: format("fp%02d", i)) }

      risultato = described_class.call(scope: scope, per: 10)

      expect(risultato.records.size).to eq(3)
      expect(risultato.total_pages).to eq(1)
    end

    # Il criterio di spareggio serve proprio qui: a parità di occorrenze, senza un ordine deciso
    # sfogliando si rivedrebbe un gruppo due volte perdendone un altro.
    it "sfogliando tutte le pagine ogni messaggio compare una volta sola" do
      12.times { |i| entry(fingerprint: format("fp%02d", i)) }

      viste = (1..3).flat_map { |p| described_class.call(scope: scope, page: p, per: 5).records.map(&:fingerprint) }

      expect(viste.size).to eq(12)
      expect(viste.uniq.size).to eq(12)
    end

    it "i messaggi comparsi più volte restano in cima, e la coda finisce nelle pagine dopo" do
      3.times { |i| entry(fingerprint: "tanti", occurred_at: i.minutes.ago) }
      2.times { |i| entry(fingerprint: "medi", occurred_at: i.minutes.ago) }
      entry(fingerprint: "pochi")

      prima = described_class.call(scope: scope, page: 1, per: 2).records.map(&:fingerprint)
      seconda = described_class.call(scope: scope, page: 2, per: 2).records.map(&:fingerprint)

      expect(prima).to eq(%w[tanti medi])
      expect(seconda).to eq(%w[pochi])
    end
  end
end
