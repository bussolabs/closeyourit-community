# frozen_string_literal: true

module Assistant
  # Messaggio di una conversazione con l'assistente. Il ruolo distingue chi parla (l'utente o
  # l'assistente) — nessun author_id, la conversazione è già posseduta dall'account. Lo status vale
  # per la risposta dell'assistente: nasce `streaming` (content vuoto), il job che consuma lo stream
  # del server AI la finalizza a `complete` (content pieno) o `failed` (content vuoto, error_code
  # valorizzato).
  # `transcribing` (CYRA-908): a spoken user message waiting for Whisper; its audio is attached only meanwhile.
  # organization_id è denormalizzato dalla conversazione per lo scoping tenant (come chat_messages).
  class Message < ApplicationRecord
    belongs_to :conversation, class_name: "Assistant::Conversation", inverse_of: :messages
    belongs_to :organization, class_name: "Organizations::Organization"
    has_many :proposals, -> { chronological }, class_name: "Assistant::Proposal",
                                               inverse_of: :message, dependent: :destroy
    has_one_attached :audio

    enum :role,   { user: 0, assistant: 1 }, prefix: :role
    enum :status, { streaming: 0, complete: 1, failed: 2, transcribing: 3 }, prefix: :status

    # Codici errore che indicano "il servizio ha risposto ma non ha prodotto testo per questa domanda"
    # (CYRA-436): la domanda non è stata capita/coperta, l'utente deve riformularla. Ogni altro
    # fallimento è un problema momentaneo del servizio a monte (timeout, rete, auth, rate-limit,
    # sovraccarico): lì l'utente deve solo riprovare più tardi. Il default prudente è "momentaneo".
    NO_ANSWER_ERROR_CODES = %w[R502-LLM-004].freeze

    # «Non collegato» non è nessuno dei due (CYRA-547): non serve riformulare né riprovare fra poco,
    # perché niente cambierà finché qualcuno non collega il servizio. Confonderlo con un guasto
    # momentaneo manderebbe l'utente a ritentare all'infinito una cosa che non può riuscire.
    NOT_CONNECTED_ERROR_CODES = [ Integrations::Providers::NOT_CONNECTED_CODE ].freeze

    # A spoken message Whisper found empty: the user should speak again, not wait. CYRA-908
    NOT_HEARD_ERROR_CODES = [ Assistant::Constants::NOT_HEARD_CODE ].freeze

    # Un messaggio completo (l'utente ha scritto, o l'assistente ha finito) DEVE avere del testo. Mentre
    # l'assistente sta scrivendo (streaming) o se ha fallito (failed) il content resta legittimamente
    # vuoto — il testo si accumula durante lo stream, l'errore si rende da error_code/i18n.
    validates :content, presence: true, if: :status_complete?
    validate :organization_matches_conversation

    scope :chronological, -> { order(:created_at, :id) }

    # Categoria dell'errore per scegliere il messaggio mostrato all'utente (CYRA-436): distingue una
    # risposta non prodotta (:no_answer → riformula la domanda) da un problema momentaneo del servizio
    # (:unavailable → riprova tra poco). nil se il messaggio non è fallito.
    def error_kind
      return unless status_failed?
      return :not_connected if NOT_CONNECTED_ERROR_CODES.include?(error_code)
      return :not_heard if NOT_HEARD_ERROR_CODES.include?(error_code)

      NO_ANSWER_ERROR_CODES.include?(error_code) ? :no_answer : :unavailable
    end

    private

    # Integrità tenant: l'org denormalizzata dev'essere quella della conversazione.
    def organization_matches_conversation
      return if conversation.blank? || organization_id.blank?

      errors.add(:organization, :mismatch) if organization_id != conversation.organization_id
    end
  end
end
