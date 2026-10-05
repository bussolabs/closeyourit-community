# frozen_string_literal: true

# Criterio di ritentabilità dei lavori in background (CYRA-713). NON è un errore da sollevare: è il
# filtro che `ApplicationJob` passa a `retry_on`.
#
# Esiste come modulo con `===` proprio perché `retry_on` ragiona per CLASSE, mentre la domanda vera
# non è di che tipo è l'errore ma se il fatto è già stato osservato: lo stesso `AppError` può essere
# il fornitore caduto (si riprova) o un dato che non andrà mai bene (non si riprova).
# `ActiveSupport::Rescuable` sceglie l'handler con `klass === exception`, quindi un modulo che
# risponde a `===` è un filtro valido quanto una classe — e se un domani Rails cambiasse quel
# meccanismo, `spec/jobs/application_job_spec.rb` diventerebbe rosso, non silenzioso.
module TransientFailure
  # Il canale si è rotto prima che il fatto accadesse. Elenco CHIUSO e di classi concrete:
  # `SystemCallError` intero comprenderebbe anche `Errno::ENOENT`, cioè un file che il programma
  # cerca dove non c'è, e riprovare non lo fa comparire.
  INFRASTRUCTURE = [
    Timeout::Error,       # comprende Net::OpenTimeout e Net::ReadTimeout
    IO::TimeoutError,
    SocketError,
    OpenSSL::SSL::SSLError,
    Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ECONNABORTED,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EPIPE,
    # Solo il «riprova più tardi» del server di posta (4xx SMTP): gli altri errori SMTP dicono che
    # la credenziale o l'indirizzo non vanno bene, e ripeterli dà lo stesso no.
    Net::SMTPServerBusy,
    ActiveRecord::Deadlocked,
    ActiveRecord::LockWaitTimeout,
    # I due modi in cui il database viene a mancare per un momento: il pool esaurito e la
    # connessione caduta a metà. NON `ConnectionNotEstablished`, che sembrerebbe il posto giusto e
    # non lo è: `ConnectionFailed` — la connessione persa durante una query, cioè il caso da
    # riprovare — sta sotto `StatementInvalid`, mentre là sotto ci finisce `ConnectionNotDefined`,
    # che è una configurazione mancante e riprovarla dà lo stesso esito.
    ActiveRecord::ConnectionTimeoutError,
    ActiveRecord::ConnectionFailed
  ].freeze

  # Status che dicono «riprova più tardi»: il fornitore non ha risposto, o ha chiesto lui di aspettare.
  RETRYABLE_STATUSES = [ 408, 425, 429, 500, 502, 503, 504, 507, 509 ].freeze

  # Status che dicono il contrario, e valgono ANCHE contro un codice che sembra transitorio: il fatto
  # è stato osservato e la risposta è definitiva. CYRA-599 — `R502-GITHUB-001` copre sia «GitHub non
  # risponde» sia «quella proposta non esiste», e solo lo status distingue i due.
  DEFINITIVE_STATUSES = [ 401, 403, 404, 410 ].freeze

  # Codici che dicono «la porta è chiusa», non «il fornitore è caduto». Il 502 nel nome è lo status
  # che vede chi chiama l'API — cambiarlo vorrebbe dire cambiare la risposta HTTP di funzioni già in
  # uso — ma la credenziale rifiutata e la richiesta malformata sono fatti osservati: ripeterli
  # ottiene lo stesso no, e su un fornitore a pagamento lo ottiene tre o sei volte.
  DEFINITIVE_CODES = %w[
    R502-LLM-002
    R502-LLM-003
    R502-AI-002
  ].freeze

  class << self
    def ===(error) = infrastructure?(error) || transient_domain_error?(error)

    private

    def infrastructure?(error) = INFRASTRUCTURE.any? { |klass| error.is_a?(klass) }

    def transient_domain_error?(error)
      return false unless error.respond_to?(:code)
      return false if DEFINITIVE_CODES.include?(error.code)
      return false if DEFINITIVE_STATUSES.include?(http_status(error))

      RETRYABLE_STATUSES.include?(status_in_code(error.code))
    end

    # `R{STATUS}-{DOMINIO}-{SEQ}` (app/errors/README.md). Lo status si legge di qui e non da
    # `#status` perché è l'unica delle due fonti sempre valorizzata: `AppError#status` ha 422 come
    # default, indistinguibile da un 422 scritto apposta, e metà del codice di dominio lo omette
    # quando il codice lo dice già — `R429-LLM-001` senza `status:` è un rate limit, non un 422.
    def status_in_code(code) = code.to_s[/\AR(\d{3})-/, 1].to_i

    def http_status(error)
      return nil unless error.respond_to?(:status)

      Rack::Utils.status_code(error.status)
    rescue ArgumentError # status che non è né un intero né un simbolo noto
      nil
    end
  end
end
