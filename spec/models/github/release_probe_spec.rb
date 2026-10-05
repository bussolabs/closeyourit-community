# frozen_string_literal: true

require "rails_helper"

# CYRA-605 — come si capisce che un rilascio è arrivato davvero. Per un progetto vuol dire che il
# programma nuovo gira sui server, per un altro che il pacchetto è comparso nel magazzino pubblico,
# per un altro ancora basta che il codice sia entrato. Oggi lo indovina uno script guardando se
# dentro il progetto esiste un certo file: il sistema non ha mai la risposta in casa.
RSpec.describe Github::Repository, "release_probe" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  # Gli ambienti sono dell'organizzazione e il progetto li abilita: la factory prende l'org, non
  # il progetto.
  let(:production) do
    create(:environment, organization:).tap { |e| project.environments << e unless project.environments.include?(e) }
  end

  def repository(**overrides) = build(:github_repository, project:, **overrides)

  # NULL è il terzo stato e va tenuto distinto dai tre: «non ancora deciso» non è «il codice è
  # unito». Senza questa distinzione la scelta di default sarebbe un indovinello spostato nel
  # database — che è esattamente quello che questo ticket toglie di mezzo.
  it "nasce non dichiarato, e non dichiarato non è una delle tre risposte" do
    riga = create(:github_repository, project:)

    expect(riga.release_probe).to be_nil
    expect(riga).to be_valid
  end

  it "accetta le tre risposte" do
    # CYRA-625 — «il pacchetto è pubblicato» ha bisogno di sapere su quale scaffale e con che nome:
    # senza, il sistema non saprebbe nemmeno dove andare a guardare.
    expect(repository(release_probe: :publish, registry: :npm, package_name: "@closeyourit/cli")).to be_valid
    expect(repository(release_probe: :merge)).to be_valid
    expect(repository(release_probe: :deploy_smoke, production_environment_id: production.id)).to be_valid
  end

  # CYRA-625 — e senza quelle coordinate non si salva: il nome del pacchetto quasi mai è quello del
  # repository, quindi indovinarlo vorrebbe dire guardare lo scaffale sbagliato.
  it "«il pacchetto è pubblicato» senza scaffale e nome non si salva" do
    riga = repository(release_probe: :publish)

    expect(riga).not_to be_valid
    expect(riga.errors[:registry]).to be_present
  end

  # Senza `validate: true` un valore fuori elenco solleva un 500: chi usa la riga di comando
  # riceverebbe un guasto del server al posto di un errore che si legge.
  it "un valore che non esiste è un errore leggibile, non un guasto del server" do
    riga = repository

    expect { riga.release_probe = "teletrasporto" }.not_to raise_error
    expect(riga).not_to be_valid
    expect(riga.errors[:release_probe]).to be_present
  end

  # Dichiarare «il rilascio in produzione è in piedi» senza aver detto quale sia l'ambiente di
  # produzione sarebbe una prova che nessuno potrà mai vedere: la lavorazione resterebbe ferma ad
  # aspettare finché non chiama una persona. Meglio dirlo mentre la scelta si sta facendo.
  describe "«il rilascio è in piedi» ha bisogno dell'ambiente di produzione" do
    it "rifiuta la scelta quando l'ambiente non c'è" do
      riga = repository(release_probe: :deploy_smoke, production_environment_id: nil)

      expect(riga).not_to be_valid
      expect(riga.errors[:release_probe].join).to match(/ambiente di produzione/)
    end

    # L'altro verso, che è la strada per cui l'incoerenza entrerebbe di soppiatto: la scelta è già
    # fatta e qualcuno toglie l'ambiente.
    it "rifiuta di togliere l'ambiente a chi quella scelta l'ha già fatta" do
      riga = create(:github_repository, project:, release_probe: :deploy_smoke,
                                        production_environment_id: production.id)

      riga.production_environment_id = nil

      expect(riga).not_to be_valid
    end

    it "le altre due risposte non chiedono nessun ambiente" do
      expect(repository(release_probe: :publish, production_environment_id: nil,
                        registry: :pypi, package_name: "closeyourit")).to be_valid
      expect(repository(release_probe: :merge, production_environment_id: nil)).to be_valid
    end

    # Il vincolo sta anche nel DATABASE perché qui si scrive con `update_column`, che le validazioni
    # le salta: il canale che sincronizza da GitHub aggiorna colonne senza passare dal modello.
    it "il database rifiuta l'incoerenza anche a chi salta il modello" do
      riga = create(:github_repository, project:, production_environment_id: nil)

      expect { riga.update_column(:release_probe, 0) }
        .to raise_error(ActiveRecord::StatementInvalid, /deploy_smoke_needs_production/)
    end
  end
end
