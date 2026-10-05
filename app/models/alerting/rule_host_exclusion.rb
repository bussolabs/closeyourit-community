# frozen_string_literal: true

module Alerting
  # CYRA-519 — «questa regola, su questa macchina, non deve suonare». Nasce dal caso reale di
  # «Contenitore caduto» sui due runner di CI: i container di compilazione nascono e muoiono a ogni
  # lavorazione, e l'unica alternativa era spegnere la regola per tutta la flotta.
  #
  # L'eccezione è una riga, non un campo sulla regola: si aggiunge e si toglie dalla scheda della
  # macchina, dove chi l'ha messa la ritrova — un silenzio che non si vede è un silenzio dimenticato.
  class RuleHostExclusion < ApplicationRecord
    self.table_name = "alerting_rule_host_exclusions"

    belongs_to :rule, class_name: "Alerting::Rule", inverse_of: :host_exclusions
    belongs_to :host, class_name: "Servers::Host", inverse_of: :alerting_rule_exclusions

    validates :host_id, uniqueness: { scope: :rule_id }
    validate :rule_and_host_share_the_organization

    private

    # Anti-BOLA: la regola di un'organizzazione non può essere silenziata su una macchina di un'altra.
    def rule_and_host_share_the_organization
      return if rule.nil? || host.nil? || rule.organization_id == host.organization_id

      errors.add(:host, :invalid)
    end
  end
end
