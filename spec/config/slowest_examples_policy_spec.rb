# frozen_string_literal: true

require "rails_helper"

# CYRA-711 — quali prove tengono in piedi il tabellone.
#
# La suite dura quanto il suo gruppo più lento, e dentro un gruppo il tempo se lo prendono poche
# prove: finché non si sa QUALI, ottimizzare è tirare a indovinare. RSpec sa dirlo (`--profile`),
# ma di suo non lo dice.
#
# Va acceso nei controlli automatici e lasciato spento in locale, per due ragioni distinte. Il
# comando che i controlli eseguono NON è in questo repository — arriva dal template condiviso di
# rilascio — quindi l'unico posto dove questa scelta è nostra è la configurazione di RSpec, che
# vale qualunque comando la esegua. E in locale la classifica è rumore: chi insegue un rosso rilancia
# tre esempi e non vuole dieci righe di tempi in fondo a ogni giro.
#
# La politica è una funzione pura sull'ambiente, come quella della copertura: si può interrogare
# senza riconfigurare l'RSpec del processo in corso, che è anche quello che sta eseguendo queste
# prove.
RSpec.describe SlowestExamplesPolicy do
  describe ".count_for" do
    it "non stampa niente in locale, dove la classifica è solo rumore" do
      expect(described_class.count_for({})).to be_nil
    end

    it "stampa le dieci prove più lente nei controlli automatici" do
      expect(described_class.count_for({ "CI" => "true" })).to eq(10)
    end

    # I controlli automatici dividono la suite in shard: la classifica esce per ogni shard, ed è
    # giusto così — il collo di bottiglia da togliere è quello del gruppo più lento, non una media.
    it "vale anche dentro uno shard" do
      expect(described_class.count_for({ "CI" => "true", "TEST_SHARD" => "3" })).to eq(10)
    end

    # Una variabile lasciata a vuoto o a zero in una shell è un "no". Senza questo, un `CI=`
    # dimenticato in un `.envrc` appiccicherebbe la classifica a ogni run locale.
    it "legge come spenta una variabile vuota, a zero o a false" do
      expect(described_class.count_for({ "CI" => "" })).to be_nil
      expect(described_class.count_for({ "CI" => "0" })).to be_nil
      expect(described_class.count_for({ "CI" => "false" })).to be_nil
    end
  end

  # La politica esiste solo se qualcuno la applica: `spec_helper` è il primo file che rspec carica,
  # quindi vale per qualunque comando esegua la suite — compreso quello del template condiviso, che
  # da qui non si può cambiare.
  it "è applicata alla configurazione di RSpec" do
    expect(Rails.root.join("spec/spec_helper.rb").read)
      .to include("config.profile_examples = SlowestExamplesPolicy.count_for")
  end

  it "è in vigore nel processo in corso" do
    expect(RSpec.configuration.profile_examples).to eq(described_class.count_for)
  end
end
