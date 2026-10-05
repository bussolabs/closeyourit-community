# frozen_string_literal: true

module Agents
  # CYRA-604 — il registro di cosa il sistema ha guardato.
  #
  # Oggi la macchina dice «ho fatto» e il lavoro compare fra le cose da revisionare: nessuno ha
  # guardato niente, il sistema si è fidato di una frase. Questa è una riga per ogni proposta
  # controllata — quale proposta, in quale progetto, con quale codice dentro, con che esito dei
  # controlli e a che ora — e quella riga resta lì.
  #
  # Il modello è inerte finché non arriva chi ci scrive: nessuna pagina lo legge ancora.
  class DeliveryCandidate < ApplicationRecord
    self.table_name = "agents_delivery_candidates"

    # `pending` è la riga appena nata: la consegna è registrata, nessuno è ancora andato a guardare.
    #
    # I tre `verified_*` sono i modi di aver guardato, e vanno tenuti distinti perché portano a
    # decisioni diverse. In particolare `verified_none_configured` — «ho guardato, e di controlli non
    # ce n'è nessuno configurato» — NON è `unreachable`, che vuol dire «non sono riuscito a
    # guardare». La prima passa, con la riga rossa: è una risposta. La seconda no: si aspetta e si
    # riprova, senza chiedere niente a nessuno. Se finissero nella stessa casella, la seconda
    # passerebbe come se fosse la prima, ed è esattamente il guasto che questo registro esiste per
    # togliere.
    #
    # `rejected` è la consegna che nomina un progetto che non è di questa organizzazione: non la si
    # ignora in silenzio, si scrive la riga col motivo e senza agganciare niente.
    enum :state, {
      pending: 0,
      verified_passing: 1,
      verified_none_configured: 2,
      verified_failing: 3,
      checks_running: 4,
      unreachable: 5,
      rejected: 6
    }, prefix: true

    # Gli stati per cui ha senso tornare a guardare. Gemelli dell'indice parziale su `next_check_at`:
    # se qui e là divergessero, il ricontrollo leggerebbe righe che l'indice non copre — o, peggio,
    # smetterebbe di leggere righe che aspettano.
    RETRYABLE_STATES = %w[pending checks_running unreachable].freeze
    # I tre esiti che valgono come «ho guardato». Gemelli del check constraint di forma.
    VERIFIED_STATES = %w[verified_passing verified_none_configured verified_failing].freeze

    belongs_to :workflow, class_name: "Agents::Workflow", inverse_of: :delivery_candidates
    belongs_to :attempt, class_name: "Agents::Attempt"
    # Nullable: una riga `rejected` non aggancia niente, e il nome osservato resta in
    # `repository_full_name` — senza, non direbbe nemmeno di cosa parlava.
    belongs_to :repository, class_name: "Github::Repository", optional: true

    validates :repository_full_name, presence: true
    validates :number, numericality: { only_integer: true, greater_than: 0 }
    validate :repository_belongs_to_the_same_organization

    scope :retryable, -> { where(state: RETRYABLE_STATES) }
    scope :due, ->(now = Time.current) { retryable.where(next_check_at: ..now) }

    before_update :ensure_verdict_is_final

    # Vero quando qualcuno è andato a guardare, anche se non ha trovato nessun controllo configurato.
    # È la domanda che distingue `[]` da NULL, e non si può fare su `checks_payload.present?`: un
    # array vuoto è `blank?`, quindi quella domanda risponderebbe «mai guardato» proprio nel caso che
    # questo registro esiste per distinguere.
    def checked? = !checks_payload.nil?

    private

    # Una volta scritto l'esito, la riga non si tocca più: è la prova di cosa è stato approvato. Se
    # qualcuno potesse riscriverla, fra un mese non ci sarebbe più modo di sapere su quale codice era
    # stato detto di sì.
    #
    # Guardia scrivi-una-volta e NON `attr_readonly`: con `load_defaults 8.1` `attr_readonly` solleva
    # su una riga già salvata, cioè proprio sulla scrittura che segna l'esito — bloccherebbe la
    # scrittura giusta insieme a quelle sbagliate, e il codice esatto non entrerebbe mai.
    def ensure_verdict_is_final
      return if verified_at_was.nil?

      raise ActiveRecord::ReadOnlyRecord,
            "La riga verificata è la prova di cosa è stato approvato: non si riscrive"
    end

    # Nessun vincolo di database può dirlo — è una relazione fra due righe di tabelle diverse — e
    # sbagliarlo qui è la cosa peggiore che possa succedere in questo registro: una consegna che
    # nomina il progetto di qualcun altro non deve MAI produrre una chiave verso quell'organizzazione.
    def repository_belongs_to_the_same_organization
      return if repository_id.blank?
      return if repository&.project&.organization_id == workflow&.organization&.id

      errors.add(:repository_id, "non appartiene all'organizzazione della lavorazione")
    end
  end
end
