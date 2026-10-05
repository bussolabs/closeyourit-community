# frozen_string_literal: true

module Agents
  # Dominio degli agenti automation: definizioni di azioni schedulate (prompt/skill Claude o comando
  # shell/cyi) create in CloseYourIt, assegnate multi-target a progetti/gruppi, eseguite e riportate da
  # closeyourit-automator. CloseYourIt = authoring + osservabilità; l'automator = esecutore che
  # sincronizza gli agenti nel proprio playbook (pull) e posta le run indietro.
  def self.table_name_prefix = "agents_"
end
