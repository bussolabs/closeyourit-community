# frozen_string_literal: true

module Vulnerabilities
  # Stato di supporto di un runtime dichiarato dal progetto (Ruby, Node, Flutter…), confrontato con
  # endoflife.date. Non è una vulnerabilità: è la causa a monte: una versione fuori supporto non
  # riceve più le patch di sicurezza, quindi i suoi problemi non compariranno mai come advisory
  # risolvibili con un aggiornamento.
  #
  # Una riga per prodotto per progetto: la versione corrente sostituisce la precedente. Uno storico
  # non servirebbe a nessuno — ciò che conta è cosa gira adesso.
  class RuntimeStatus < ApplicationRecord
    self.table_name = "vulnerabilities_runtime_statuses"

    belongs_to :project, class_name: "Projects::Project", inverse_of: :vulnerability_runtime_statuses

    enum :state, { supported: 0, ending_soon: 1, eol: 2 }, prefix: :state

    validates :name, presence: true, uniqueness: { scope: :project_id }
    validates :version, presence: true

    scope :ordered, -> { order(:name) }
    scope :attention, -> { where(state: %i[ending_soon eol]) }

    # Fine supporto già passata → `eol`. Entro la finestra di preavviso → `ending_soon`: serve a
    # muoversi prima della scadenza, non il giorno dopo. Data ignota → `supported`, perché dichiarare
    # un allarme su un dato che non abbiamo sarebbe un falso positivo garantito.
    def self.state_for(eol_on, now = Time.zone.today)
      return :supported if eol_on.blank?
      return :eol if eol_on <= now

      eol_on <= now + Vulnerabilities::Constants::RUNTIME_EOL_WARNING_DAYS.days ? :ending_soon : :supported
    end

    def days_to_eol = eol_on.present? ? (eol_on - Time.zone.today).to_i : nil

    def outdated? = latest.present? && latest != version
  end
end
