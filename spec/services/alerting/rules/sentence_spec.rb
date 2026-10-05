# frozen_string_literal: true

require "rails_helper"

# CYRA-490 — la condizione di una regola scritta in una frase, generata dai suoi campi. Il rischio
# dichiarato è che una frase scritta a mano diverga dalla configurazione reale: qui si prova che ogni
# pezzo (evento, gravità, scope, soglia, raggruppamento) esca dai dati e non da testo fisso.
RSpec.describe Alerting::Rules::Sentence, type: :service do
  let(:organization) { create(:organization) }

  def sentence_for(rule) = described_class.call(rule).join(" ")

  it "apre con la descrizione dell'evento presa dal catalogo unico" do
    rule = build(:alerting_rule, organization:, event_type: :error_new)
    expect(sentence_for(rule)).to include(Notifications::Catalog.entry("error_new").description)
  end

  it "nomina la gravità minima quando la regola la usa" do
    rule = build(:alerting_rule, organization:, event_type: :error_new,
                                 min_level: Errors::Group.levels["error"])
    expect(sentence_for(rule)).to include(I18n.t("member.alerting.levels.error"))
  end

  it "non nomina la gravità per un evento che non la prevede (uptime)" do
    rule = build(:alerting_rule, :uptime_down, organization:)
    expect(sentence_for(rule)).not_to include(I18n.t("member.alerting.rules.show.sentence.min_level",
                                                     level: I18n.t("member.alerting.levels.error")))
  end

  it "segnala che vale per i soli errori non gestiti" do
    rule = build(:alerting_rule, organization:, event_type: :error_new, unhandled_only: true)
    expect(sentence_for(rule)).to include(I18n.t("member.alerting.rules.show.sentence.unhandled_only"))
  end

  it "nomina progetto e ambiente dello scope" do
    project = create(:project, organization:, name: "Alpha")
    env = create(:environment, organization:, label: "Produzione")
    rule = build(:alerting_rule, organization:, event_type: :error_new, project:, environment: env)
    frase = sentence_for(rule)
    expect(frase).to include("Alpha")
    expect(frase).to include("Produzione")
  end

  it "dice che copre tutti i progetti quando lo scope è aperto" do
    rule = build(:alerting_rule, organization:, event_type: :error_new)
    expect(sentence_for(rule)).to include(I18n.t("member.alerting.rules.show.sentence.scope_all"))
  end

  it "dichiara la copertura sull'intera organizzazione per un evento org-scoped" do
    rule = build(:alerting_rule, :server_down, organization:)
    expect(sentence_for(rule)).to include(I18n.t("member.alerting.rules.show.sentence.scope_org"))
  end

  it "riporta la soglia di durata per una regola di performance" do
    rule = build(:alerting_rule, organization:, event_type: :metric_threshold, threshold_ms: 750)
    expect(sentence_for(rule)).to include("750")
  end

  it "riporta la soglia numerica con la percentuale per una regola server a soglia" do
    rule = build(:alerting_rule, organization:, event_type: :server_cpu, threshold: 90)
    frase = sentence_for(rule)
    expect(frase).to include("90")
    expect(frase).to include("%")
  end

  it "riporta i gradi per una soglia di temperatura" do
    rule = build(:alerting_rule, organization:, event_type: :server_temp, threshold: 70)
    expect(sentence_for(rule)).to include("°C")
  end

  it "riporta la finestra di raggruppamento in minuti dai secondi salvati" do
    rule = build(:alerting_rule, organization:, event_type: :error_new, throttle_seconds: 600)
    expect(sentence_for(rule)).to include("10")
  end

  it "avverte quando la regola è spenta" do
    rule = build(:alerting_rule, :disabled, organization:, event_type: :error_new)
    expect(sentence_for(rule)).to include(I18n.t("member.alerting.rules.show.sentence.state_off"))
  end

  it "avverte quando la regola è silenziata a tempo" do
    rule = build(:alerting_rule, organization:, event_type: :error_new, muted_until: 2.hours.from_now)
    expect(sentence_for(rule)).to include(I18n.t("member.alerting.rules.show.sentence.state_muted",
                                                 time: I18n.l(rule.muted_until, format: :short)))
  end
end
