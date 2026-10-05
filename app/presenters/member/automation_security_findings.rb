# frozen_string_literal: true

module Member
  # Le segnalazioni di sicurezza che la lavorazione automatica ha trovato (CYRA-384), lette dal campo
  # apposta del risultato consegnato. Su un ticket vero l'anomalia — uno script che sondava le
  # credenziali git, un token dentro l'indirizzo di download — era testo corrente in mezzo a 250
  # parole, dentro una scheda secondaria: non la vedeva nessuno.
  #
  # DECISIONE (cliente, 2026-08-17): la scrive la macchina in `result["security_findings"]`. NON si
  # cerca nel testo libero. Cercarla nel testo vuol dire indovinare, e qui indovinare male costa in
  # tutte e due le direzioni: un allarme inventato sopra a ogni ticket smette di essere letto, e uno
  # mancato è esattamente il guasto che questo ticket chiude.
  #
  # Il campo passa il contratto agent-result/v1 così com'è, senza toccarne lo schema: ogni result ha
  # `additionalProperties` aperto. Il contratto è vendorizzato e bloccato a checksum (LOCK.json), e un
  # campo nuovo non ha bisogno di romperlo.
  #
  # La lettura è difensiva per costruzione: il payload è dato esterno, e la pagina del ticket non deve
  # mai esplodere per una consegna malfatta — vale la stessa regola di Member::AutomationHelper.
  class AutomationSecurityFindings
    Finding = Struct.new(:title, :detail, :severity, :phase, :at, keyword_init: true)

    # Gravità ammesse: fuori da queste il valore sparisce invece di diventare un colore inventato.
    # Un'etichetta che non sappiamo tradurre è peggio di nessuna etichetta su un avviso di sicurezza.
    SEVERITIES = %w[low medium high critical].freeze

    def self.call(ticket:) = new(ticket:).call

    # CYRA-603 — «nessuna segnalazione» sono due cose diverse, e finora la pagina non poteva
    # distinguerle: «ho guardato e non ho trovato niente» e «non ho guardato». Un silenzio che vuol
    # dire due cose non è una risposta, e chi approva non ha modo di sapere quale delle due sta
    # leggendo.
    #
    # `declared?` guarda se una consegna PORTA il campo, non se il campo ha dentro qualcosa: la query
    # qui sotto vede già l'elenco vuoto, perché `-> 'security_findings' IS NOT NULL` distingue il
    # JSON `[]` (presente) dalla chiave assente. È l'unico punto in cui la differenza esiste.
    def self.declared?(ticket:) = new(ticket:).declared?

    def initialize(ticket:)
      @ticket = ticket
    end

    # Ordine: la segnalazione più recente per prima. Un tentativo ripetuto diciannove volte ripete la
    # stessa segnalazione diciannove volte, e un avviso con diciannove righe uguali è di nuovo il
    # registro di macchina che questo ticket toglie di mezzo — quindi si deduplica su titolo+dettaglio.
    def call
      workflow = @ticket.agent_workflow
      return [] if workflow.nil?

      rows(workflow).flat_map { |attempt| findings_of(attempt) }
                    .uniq { |finding| [ finding.title, finding.detail ] }
    end

    # Vero quando almeno una consegna ha dichiarato il campo, anche vuoto.
    def declared?
      workflow = @ticket.agent_workflow
      return false if workflow.nil?

      rows(workflow).exists?
    end

    private

    # Solo i tentativi che portano davvero il campo: su una lavorazione lunga sono pochissimi, e il
    # filtro sta nel database invece di caricare decine di payload per scartarli in Ruby.
    #
    # Vale anche un tentativo RESPINTO dalla revisione: quella ha bocciato il lavoro consegnato, non
    # ha smentito l'allarme — e un allarme di sicurezza non si perde perché il lavoro attorno non
    # andava bene.
    def rows(workflow)
      workflow.attempts
              .where("agents_attempts.result -> 'security_findings' IS NOT NULL")
              .order(started_at: :desc, created_at: :desc)
    end

    def findings_of(attempt)
      entries = attempt.result["security_findings"]
      return [] unless entries.is_a?(Array)

      entries.filter_map { |entry| finding_from(entry, attempt) }
    end

    def finding_from(entry, attempt)
      return nil unless entry.is_a?(Hash)

      title = entry["title"].presence
      return nil if title.blank?

      severity = entry["severity"].to_s.downcase.presence
      Finding.new(title: title.to_s, detail: entry["detail"].presence&.to_s,
                  severity: (severity if SEVERITIES.include?(severity)),
                  phase: attempt.phase, at: attempt.finished_at || attempt.started_at)
    end
  end
end
