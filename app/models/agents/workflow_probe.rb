# frozen_string_literal: true

module Agents
  # CYRA-624 — la prova che il rilascio è DAVVERO in piedi.
  #
  # Il ticket diventava «Fatto» nell'istante in cui la macchina diceva di aver messo l'etichetta
  # della versione. Lì non era ancora stato rilasciato niente: il rilascio parte dopo, e può andare
  # male un minuto dopo. Il ticket restava «Fatto» lo stesso, e nessuno veniva avvisato.
  #
  # `expected` è quello che si andrà a cercare, congelato PRIMA che il rilascio parta: la versione e
  # il codice sigillato. Non si ricava mai da ciò che si osserva — chiedere all'etichetta osservata se
  # è quella giusta è la stessa promessa dichiarata e non mantenuta che si sta togliendo di mezzo.
  class WorkflowProbe < ApplicationRecord
    self.table_name = "agents_workflow_probes"

    # Quanto si insiste prima di chiamare una persona, e ogni quanto si torna a guardare. Un rilascio
    # che non si vede in un'ora non è «non ancora»: è qualcosa che una persona deve guardare.
    RETRY_EVERY = 2.minutes
    GRACE_WINDOW = 60.minutes

    # I tipi di prova che questo passo sa osservare. `merge` è la prova dello staging, non del
    # rilascio, e resta fuori. Una lavorazione il cui piano ha congelato una prova di un altro tipo
    # non aggancia niente e lo dice subito, invece di far aspettare un'ora per una cosa che nessuno
    # andrà mai a guardare.
    OBSERVABLE_KINDS = %w[deploy_smoke publish].freeze

    belongs_to :workflow, class_name: "Agents::Workflow", inverse_of: :probes

    scope :live, -> { where(closed_at: nil) }
    scope :due, ->(now = Time.current) { live.where(next_check_at: ..now) }

    validates :kind, presence: true, inclusion: { in: OBSERVABLE_KINDS }
    validates :bound_at, presence: true

    def live? = closed_at.nil?

    def expired?(now = Time.current) = live? && bound_at + GRACE_WINDOW <= now

    def expected_version = expected["version"]
    def expected_sha = expected["sha"]
    def expected_repo = expected["repo"]
    def expected_environment_id = expected["environment_id"]
    # CYRA-625 — su quale scaffale guardare e con che nome chiedere, congelati all'aggancio.
    def expected_registry = expected["registry"]
    def expected_package = expected["package"]
  end
end
