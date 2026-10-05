# frozen_string_literal: true

require "rails_helper"

# CYRA-148 — Lo smistamento (triage) e l'analisi di errori e performance condividono UNA sola
# implementazione: le classi di dominio (Errors::* / Metrics::*) sono sottoclassi sottili di una
# base parametrizzata sotto Observability::*. Questo spec è la garanzia anti-deriva dello Scenario 1
# del ticket ("un cambio nello smistamento errori vale anche per le performance senza copiare il
# codice"): se qualcuno ri-duplica staccando l'ereditarietà, questi test diventano rossi.
RSpec.describe "Observability triage/analisi condivisi (CYRA-148)" do
  describe "base condivisa fra errori e performance" do
    {
      "Triage"          => [ Errors::Triage,          Metrics::Triage,          Observability::Triage ],
      "BulkTriage"      => [ Errors::BulkTriage,      Metrics::BulkTriage,      Observability::BulkTriage ],
      "PromoteToTicket" => [ Errors::PromoteToTicket, Metrics::PromoteToTicket, Observability::PromoteToTicket ],
      "TriageWithAi"    => [ Errors::TriageWithAi,    Metrics::TriageWithAi,    Observability::TriageWithAi ]
    }.each do |name, (error_klass, metric_klass, base_klass)|
      it "#{name}: errori e performance discendono dalla stessa base #{name}" do
        expect(error_klass.ancestors).to include(base_klass)
        expect(metric_klass.ancestors).to include(base_klass)
        expect(base_klass.superclass).to eq(ApplicationService)
      end
    end
  end

  # Single source of truth comportamentale: la mappa delle azioni di triage è LA STESSA costante
  # (identità d'oggetto), non due copie parallele. Cambiarla nella base cambia il comportamento di
  # entrambi i domini in un colpo — è esattamente ciò che chiede lo Scenario 1.
  it "la mappa delle azioni di triage è un'unica fonte per errori e performance" do
    expect(Errors::Triage::ACTIONS).to equal(Metrics::Triage::ACTIONS)
    expect(Observability::Triage::ACTIONS).to eq("resolve" => :resolved, "ignore" => :ignored, "reopen" => :unresolved)
  end
end
