# frozen_string_literal: true

require "rails_helper"

# Regressione CYRA-173: cercare (q) mentre l'elenco Progetti è ordinato per gruppo
# (sort=group) aggiunge un LEFT OUTER JOIN su projects_groups; la clausola di ricerca
# usava colonne NON qualificate (name/key) e projects_groups ha anch'essa `name` →
# PG::AmbiguousColumn: column reference "name" is ambiguous → 500. Le colonne ora sono
# qualificate (projects.name / projects.key).
RSpec.describe "Member projects index — search + sort", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    group = create(:group, organization: org, name: "Gruppo A")
    create(:project, organization: org, group: group, name: "Presentazioni")
    create(:project, organization: org, name: "Altro progetto")
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "non va in errore cercando con ordinamento per gruppo (asc)" do
    get member_projects_path, params: { q: "prese", sort: "group" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Presentazioni")
  end

  it "non va in errore cercando con ordinamento per gruppo (desc)" do
    get member_projects_path, params: { q: "prese", sort: "-group" }

    expect(response).to have_http_status(:ok)
  end

  it "la ricerca senza ordinamento resta ok" do
    get member_projects_path, params: { q: "prese" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Presentazioni")
  end
end
