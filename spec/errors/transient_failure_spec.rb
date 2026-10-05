# frozen_string_literal: true

require "rails_helper"

# CYRA-713 — il criterio che separa i guasti che possono guarire da soli da quelli che ripetuti
# danno lo stesso esito. È il filtro che ApplicationJob passa a `retry_on`, quindi ogni riga qui
# decide se un lavoro in background viene ripetuto o segnato fallito subito.
RSpec.describe TransientFailure do
  def matches?(error) = described_class === error # rubocop:disable Style/CaseEquality

  describe "guasti dell'infrastruttura" do
    it "riconosce i timeout di rete" do
      expect(matches?(Net::ReadTimeout.new)).to be(true)
      expect(matches?(Net::OpenTimeout.new)).to be(true)
      expect(matches?(Timeout::Error.new)).to be(true)
    end

    it "riconosce la connessione caduta e l'host irraggiungibile" do
      expect(matches?(Errno::ECONNRESET.new)).to be(true)
      expect(matches?(Errno::ECONNREFUSED.new)).to be(true)
      expect(matches?(Errno::EHOSTUNREACH.new)).to be(true)
      expect(matches?(SocketError.new)).to be(true)
    end

    # Solo il «riprova più tardi» del server di posta: gli altri errori SMTP dicono che la
    # credenziale o l'indirizzo non vanno bene.
    it "riconosce il server di posta occupato ma non la credenziale sbagliata" do
      expect(matches?(Net::SMTPServerBusy.new("421 too many connections"))).to be(true)
      expect(matches?(Net::SMTPAuthenticationError.new("535 bad credentials"))).to be(false)
    end

    it "riconosce la contesa sul database" do
      expect(matches?(ActiveRecord::Deadlocked.new)).to be(true)
      expect(matches?(ActiveRecord::LockWaitTimeout.new)).to be(true)
    end

    # `ConnectionFailed` sta sotto `StatementInvalid`, non sotto `ConnectionNotEstablished`: chi
    # elencasse la seconda prenderebbe la configurazione mancante e lascerebbe fuori la connessione
    # caduta, cioè esattamente il contrario di quello che serve.
    it "riconosce il database venuto a mancare per un momento, non la configurazione che manca" do
      expect(matches?(ActiveRecord::ConnectionFailed.new)).to be(true)
      expect(matches?(ActiveRecord::ConnectionTimeoutError.new)).to be(true)
      expect(matches?(ActiveRecord::ConnectionNotDefined.new)).to be(false)
    end

    # L'elenco è chiuso proprio per questo: `SystemCallError` intero comprenderebbe anche il file che
    # il programma cerca dove non c'è, e riprovare non lo fa comparire.
    it "non scambia per rete un file che manca" do
      expect(matches?(Errno::ENOENT.new)).to be(false)
    end
  end

  describe "difetti del programma" do
    it "non riconosce gli errori che ripetuti danno lo stesso esito" do
      expect(matches?(NoMethodError.new("undefined method"))).to be(false)
      expect(matches?(ArgumentError.new("manca un argomento"))).to be(false)
      expect(matches?(TypeError.new("no implicit conversion"))).to be(false)
      expect(matches?(KeyError.new("chiave assente"))).to be(false)
      expect(matches?(JSON::ParserError.new("unexpected token"))).to be(false)
    end

    it "non riconosce un record che non passa le validazioni" do
      expect(matches?(ActiveRecord::RecordInvalid.new(Ticketing::Ticket.new))).to be(false)
    end
  end

  describe "errori di dominio" do
    def app_error(code, **options) = AppError.new("boom", code: code, **options)

    it "riconosce il fornitore caduto o lento" do
      expect(matches?(app_error("R502-AI-001", status: :bad_gateway))).to be(true)
      expect(matches?(app_error("R503-LLM-001"))).to be(true)
      expect(matches?(app_error("R504-LLM-001", status: :gateway_timeout))).to be(true)
      expect(matches?(app_error("R500-APPROVAL-006"))).to be(true)
    end

    # Il rate limit è il caso in cui riprovare serve di più: la finestra del fornitore si riapre.
    it "riconosce il rate limit del fornitore" do
      expect(matches?(app_error("R429-LLM-001"))).to be(true)
    end

    it "non riconosce un dato che non andrà mai bene" do
      expect(matches?(app_error("R422-AI-002"))).to be(false)
      expect(matches?(app_error("R422-ANALYSIS-001"))).to be(false)
      expect(matches?(app_error("R409-SHARED-001"))).to be(false)
      expect(matches?(app_error("R404-IDEA-001"))).to be(false)
    end

    # Lo status si legge dal codice perché è l'unica delle due fonti sempre valorizzata: `AppError`
    # ha 422 come default, indistinguibile da un 422 scritto apposta. Metà del codice di dominio
    # omette `status:` quando il codice lo dice già.
    it "legge lo status dal codice anche quando non è stato passato" do
      expect(app_error("R429-LLM-001").status).to eq(:unprocessable_content)
      expect(matches?(app_error("R429-LLM-001"))).to be(true)
    end

    # CYRA-599 — `R502-GITHUB-001` copre sia «GitHub non risponde» sia «quella proposta non esiste».
    # Il secondo è un fatto osservato: nessun tentativo lo cambia, e lo status lo dice.
    it "uno status definitivo smentisce un codice che sembra transitorio" do
      expect(matches?(app_error("R502-GITHUB-001", status: :not_found))).to be(false)
      expect(matches?(app_error("R502-GITHUB-001", status: :unauthorized))).to be(false)
      expect(matches?(app_error("R502-GITHUB-001", status: :bad_gateway))).to be(true)
    end

    # I client rappresentano la credenziale rifiutata e la richiesta malformata come 502 perché è lo
    # status che deve vedere chi chiama l'API. Il fatto però è stato osservato: ripeterlo non cambia.
    it "non riprova la credenziale rifiutata né la richiesta malformata travestite da 502" do
      expect(matches?(app_error("R502-LLM-002"))).to be(false)
      expect(matches?(app_error("R502-LLM-003"))).to be(false)
      expect(matches?(app_error("R502-AI-002"))).to be(false)
      expect(matches?(app_error("R502-AI-001"))).to be(true)
    end

    it "regge un errore senza codice riconoscibile senza esplodere" do
      expect(matches?(StandardError.new("nudo"))).to be(false)
      expect(matches?(app_error("codice storto"))).to be(false)
    end
  end
end
