# frozen_string_literal: true

module Ticketing
  # Una domanda su un ticket (CYRA-779).
  #
  # Prima era un commento, e la risposta era il commento successivo: l'aggancio stava nell'ordine di
  # arrivo, non nell'identità. Qui la domanda è una riga sua, e la risposta le appartiene — un
  # commento scritto nel frattempo non può più chiuderla per sbaglio.
  #
  # `answered_at` è l'AUTORITÀ sul «ha risposto», non `resolved_answer_id`: la chiave esterna cade a
  # NULL se la risposta viene cancellata, e se il fatto vivesse lì cancellare una risposta
  # riaprirebbe una domanda che qualcuno aveva chiuso (è la lezione di CYRA-219, che era costata la
  # stessa toppa sul lato commenti).
  class Question < ApplicationRecord
    include Attachable
    include LengthBudget

    # Una domanda si legge, non si esegue. La regola arriva da Agents::Clarification, dove copriva le
    # sole domande di triage; ora vale anche per quelle poste a mano, che non passavano da nessun
    # controllo. Il motivo non è cambiato: chi legge la domanda è una persona, e una riga che sembra
    # un comando invita a eseguirlo.
    COMMAND_SHAPED = %r{`|https?://|(?:^|\s)(?:/|\.\.?/)|\b(?:bin/rails|bundle|npm|pnpm|yarn|git)\b}i

    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :questions
    belongs_to :author, class_name: "Accounts::Account"
    belongs_to :closed_by, class_name: "Accounts::Account", optional: true
    has_many :answers,
             -> { order(:created_at, :id) },
             class_name: "Ticketing::Answer",
             foreign_key: :question_id,
             inverse_of: :question,
             dependent: :destroy
    # Quale delle risposte ha chiuso la domanda. `inverse_of: false`: la risposta conosce la sua
    # domanda da `question_id`, e dichiarare l'inverso di questa seconda strada la confonderebbe.
    belongs_to :resolved_answer, class_name: "Ticketing::Answer", optional: true, inverse_of: false

    # Chi la vede. Il default è il riservato: una domanda interna che andava condivisa è un click, una
    # domanda che sfugge al cliente per svista è un danno.
    enum :audience, { internal: 0, shared: 1 }, prefix: true
    # Chi l'ha posta, fotografato al momento: un service account riclassificato domani non deve
    # riscrivere la storia di ieri.
    enum :origin, { human: 0, agent: 1 }, prefix: true

    normalizes :body,
               with: ->(value) { Text::ItalianOrthography.correct(LengthBudget.normalize_newlines(value)).strip }

    validates :body, presence: true
    length_budget :body, maximum: Ticketing::Constants::QUESTION_MAX_CHARS
    validates :body, length: { maximum: Ticketing::Constants::AGENT_QUESTION_MAX_CHARS }, if: :origin_agent?
    validate :body_reads_as_a_question
    validate :author_belongs_to_organization

    scope :open, -> { where(answered_at: nil, closed_at: nil) }
    scope :blocking_open, -> { open.where(blocking: true) }
    # Il tie-break su `id` non è pignoleria: a parità di istante l'ordine di due letture identiche
    # cambierebbe, ed è la stessa trappola già documentata sulla cronologia del ticket.
    scope :chronological, -> { order(:created_at, :id) }

    # Chi può leggerle (CYRA-848). L'`audience` veniva scritto e mai applicato in lettura: il cliente
    # vedeva anche le riservate, e quelle poste dagli automi nascono riservate e contengono il piano
    # di lavoro, i file toccati e le scelte tecniche.
    #
    # La regola sta QUI e non nei controller perché i lettori sono più d'uno (scheda Domande, canale
    # CLI, contatori della lista ticket): scritta di là, il prossimo lettore nascerebbe senza filtro.
    #
    # Vale anche per le SCRITTURE che partono da un lookup (rispondi, ritira): una domanda che non si
    # può leggere non si può nemmeno toccare, e il lookup ristretto la fa sparire (404) invece di
    # confermarne l'esistenza con un 403.
    def self.readable_by(account, organization:)
      return all if Connections::Membership.internal_actor?(account: account, organization: organization)

      audience_shared
    end

    def open? = answered_at.nil? && closed_at.nil?

    # CYRA-1033 — the proposed answers of a choice question, in the order they were asked; empty for a
    # plain question. `choice` is 1-based, the number a person reads next to each answer.
    def choice_options
      Array(options).map do |option|
        { "label" => option["label"].to_s, "recommended" => option["recommended"] == true, "reason" => option["reason"].presence }
      end
    end

    def choice_label(choice) = (choice_options[choice - 1]&.fetch("label") if choice.to_i.positive?)

    private

    def body_reads_as_a_question
      return if body.blank?
      return unless body.match?(COMMAND_SHAPED)

      errors.add(:body, :command_shaped)
    end

    # Isolamento tenant (anti-BOLA): specchio di Ticketing::Comment#author_belongs_to_organization.
    # È una copia, e si vede: la stessa regola vive in una decina di modelli con una decina di strade
    # diverse per arrivare all'organizzazione. Unificarla è un lavoro suo, non un effetto collaterale
    # di questo.
    def author_belongs_to_organization
      org_id = ticket&.project&.organization_id
      return if org_id.blank? || author.blank?
      return if Connections::Membership.exists?(account_id: author.id, organization_id: org_id)

      errors.add(:author, :not_member)
    end
  end
end
