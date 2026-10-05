# frozen_string_literal: true

require "rails_helper"

# CYRA-79 — il valore su misura arriva a chi lo riceve passando dal canale che usa davvero: `cyi run`
# e `cyi secrets download`/`get` leggono tutti lo stesso bundle. Due persone, stesso progetto, stesso
# ambiente, stesso comando: valori diversi.
RSpec.describe "Cli::V1::Projects::Secrets valori su misura", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:, code: "production").tap { |e| project.environments << e } }
  let(:admin) { create(:account) }
  let(:destinatario) { create(:account) }
  let(:altro) { create(:account) }

  # Un'organizzazione ha un solo owner: chi riceve il valore su misura è un lettore vero — membro,
  # collegato al progetto, con secrets.read concesso.
  def make_reader(account, **membership_attrs)
    create(:membership, account:, organization:, role: :member, **membership_attrs)
    create(:project_membership, account:, project:)
    create(:account_permission, account:, organization:, permission_key: "secrets.read", effect: :allow)
  end

  before do
    create(:membership, account: admin, organization:, role: :owner)
    make_reader(destinatario)
    make_reader(altro)
    Secrets::Variables::Set.call(project:, environment:, name: "DATABASE_URL", value: "standard")
    Secrets::Overrides::Set.call(project:, environment:, account: destinatario,
                                 name: "DATABASE_URL", value: "solo-suo", actor: admin)
  end

  def headers_for(account)
    { "Authorization" => "Bearer #{Accounts::ApiTokens::Issue.call(account:, organization:, name: 'CLI').value[:secret]}" }
  end

  def bundle_for(account)
    get "/cli/v1/projects/#{project.id}/secrets/bundle", params: { environment: "production" },
                                                         headers: headers_for(account)
    response.parsed_body["data"]
  end

  it "chi ha il valore su misura riceve il suo, gli altri quello standard" do
    expect(bundle_for(destinatario)).to eq({ "DATABASE_URL" => "solo-suo" })
    expect(bundle_for(altro)).to eq({ "DATABASE_URL" => "standard" })
  end

  it "aggiunge anche una variabile che nel progetto non esiste" do
    Secrets::Overrides::Set.call(project:, environment:, account: destinatario,
                                 name: "SOLO_PER_ME", value: "extra", actor: admin)

    expect(bundle_for(destinatario)).to include("SOLO_PER_ME" => "extra")
    expect(bundle_for(altro)).not_to have_key("SOLO_PER_ME")
  end

  # Il valore su misura NON è una scorciatoia per leggere un ambiente vietato: il confine ambienti
  # (CYRA-78) blocca la richiesta prima ancora che il bundle venga risolto.
  it "non aggira il confine ambienti" do
    create(:environment, organization:, code: "staging").tap { |e| project.environments << e }
    confinato = create(:account)
    make_reader(confinato, secret_environment_codes: [ "staging" ])
    Secrets::Overrides::Set.call(project:, environment:, account: confinato,
                                 name: "DATABASE_URL", value: "non-deve-uscire", actor: admin)

    get "/cli/v1/projects/#{project.id}/secrets/bundle", params: { environment: "production" },
                                                         headers: headers_for(confinato)

    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("non-deve-uscire")
  end
end
