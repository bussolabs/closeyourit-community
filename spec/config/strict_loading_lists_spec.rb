# frozen_string_literal: true

require "rails_helper"

# CYRA-747 — la guardia contro le letture a raffica (spec/support/strict_loading.rb).
#
# Una lista che legge un'associazione non precaricata fa una query in più PER OGNI RIGA: sulla
# pagina di prova, con tre righe, non si vede; in produzione, con tremila, è la pagina che non si
# apre più. Prosopite intercetta la ripetizione, quindi ha bisogno che le righe interessate siano
# abbastanza; qui la violazione è la lettura pigra in sé, indipendente da quante volte accade.
#
# Questa prova custodisce il confine della guardia: cosa deve fermare, cosa deve lasciar passare e
# come si sospende quando c'è un motivo. Senza, il confine si sposta da solo — basta che qualcuno
# allarghi la regola per far passare una prova rossa e la difesa smette di difendere in silenzio.
# `type: :request` non per fare richieste — qui non ce ne sono — ma perché è lì che la guardia vive:
# provarla altrove proverebbe una guardia spenta.
RSpec.describe "La guardia contro le letture a raffica", type: :request do
  let(:organization) { create(:organization) }

  it "una lista che legge un'associazione non precaricata fallisce, dicendo quale" do
    create_list(:project, 2, organization:)

    progetti = Projects::Project.where(organization_id: organization.id).to_a

    expect { progetti.first.organization }
      .to raise_error(ActiveRecord::StrictLoadingViolationError, /organization/)
  end

  it "precaricare l'associazione basta a far passare la stessa lista" do
    create_list(:project, 2, organization:)

    progetti = Projects::Project.where(organization_id: organization.id).includes(:organization).to_a

    expect(progetti.map { |p| p.organization.id }).to all(eq(organization.id))
  end

  it "una riga sola non è una raffica: leggere la sua associazione resta lecito" do
    create(:project, organization:)

    progetti = Projects::Project.where(organization_id: organization.id).to_a

    expect(progetti.size).to eq(1)
    expect(progetti.first.organization).to eq(organization)
  end

  it "un record letto da solo (find_by, l'account della sessione) non è una lista" do
    progetto = create(:project, organization:)

    trovato = Projects::Project.find_by(id: progetto.id)

    expect(trovato.organization).to eq(organization)
  end

  it "quando il codice di produzione ha già deciso da sé, la sua decisione vince" do
    create_list(:project, 2, organization:)

    progetti = Projects::Project.where(organization_id: organization.id).strict_loading(false).to_a

    expect(progetti.first.organization).to eq(organization)
  end

  it "si sospende per un tratto motivato, e subito dopo torna a difendere" do
    create_list(:project, 2, organization:)

    allow_lazy_loading do
      # Rileggere i dati appena costruiti non è la pagina che l'utente paga: qui le query non sono
      # quelle di produzione.
      expect(Projects::Project.where(organization_id: organization.id).to_a.first.organization).to eq(organization)
    end

    progetti = Projects::Project.where(organization_id: organization.id).to_a
    expect { progetti.first.organization }.to raise_error(ActiveRecord::StrictLoadingViolationError)
  end
end

# Il confine dichiarato dalla guardia: fuori da una richiesta la stessa lettura non è una raffica da
# correggere (un job che distrugge in cascata DEVE caricare le associazioni dipendenti). Se qualcuno
# accendesse la guardia dappertutto, questa prova lo direbbe subito invece di lasciare che decine di
# prove di servizio diventino rosse senza un difetto sotto.
RSpec.describe "La guardia contro le letture a raffica, fuori da una richiesta", type: :model do
  it "lascia passare la lettura pigra su una lista" do
    organization = create(:organization)
    create_list(:project, 2, organization:)

    progetti = Projects::Project.where(organization_id: organization.id).to_a

    expect(progetti.first.organization).to eq(organization)
  end
end
