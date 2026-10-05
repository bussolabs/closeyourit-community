# frozen_string_literal: true

require "rails_helper"

# Agganciare un repository a un progetto è 1:1 nei due sensi, e i tre rifiuti hanno tre codici diversi
# apposta: chi chiama dal terminale deve poter distinguere «manca l'installazione» (vai a installarla)
# da «è già preso» (non c'è niente da fare qui). Il service è condiviso da web e CLI.
RSpec.describe Github::Repositories::Connect do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:installation) { create(:github_installation, organization:) }

  def connect(target: project, repo_id: 42, full_name: "bussolabs/app", **rest)
    described_class.call(project: target, repo_id:, full_name:, **rest)
  end

  it "aggancia il repository al progetto passando dall'installazione dell'organizzazione" do
    result = connect

    expect(result).to be_ok
    repository = result.value
    expect(repository).to be_persisted
    expect(repository.project).to eq(project)
    expect(repository.installation).to eq(installation)
    expect(repository.full_name).to eq("bussolabs/app")
    expect(repository.repo_id).to eq(42)
  end

  it "senza ramo indicato usa main, non una stringa vuota" do
    expect(connect(default_branch: "  ").value.default_branch).to eq("main")
    expect(connect(target: create(:project, organization:), repo_id: 43,
                   default_branch: "develop").value.default_branch).to eq("develop")
  end

  it "un'organizzazione che non ha installato l'app non aggancia niente" do
    altra = create(:project, organization: create(:organization))

    result = connect(target: altra)

    expect(result).to be_err
    expect(result.error.code).to eq("R404-GITHUB-004")
    expect(result.error.status).to eq(:not_found)
    expect(result.error.message).to eq(I18n.t("github.errors.no_installation"))
  end

  it "un progetto che ha già un repository non ne prende un secondo" do
    connect

    result = connect(repo_id: 99, full_name: "bussolabs/altro")

    expect(result).to be_err
    expect(result.error.code).to eq("R409-GITHUB-003")
    expect(result.error.message).to eq(I18n.t("github.errors.project_taken"))
    expect(project.reload.github_repository.repo_id).to eq(42)
  end

  it "un repository già agganciato altrove non si sposta di nascosto" do
    connect

    result = connect(target: create(:project, organization:), repo_id: 42)

    expect(result).to be_err
    expect(result.error.code).to eq("R409-GITHUB-003")
    expect(result.error.message).to eq(I18n.t("github.errors.repo_taken"))
    expect(result.error.status).to eq(:conflict)
  end

  # Due organizzazioni hanno due installazioni distinte: lo stesso repository su GitHub visto da due
  # installazioni diverse non è lo stesso aggancio, e il conflitto è per installazione.
  it "lo stesso numero di repository sotto un'altra installazione non è un conflitto" do
    connect

    altra_org = create(:organization)
    create(:github_installation, organization: altra_org)

    expect(connect(target: create(:project, organization: altra_org), repo_id: 42)).to be_ok
  end

  it "un repository senza nome è un errore di validazione, non un aggancio a metà" do
    result = connect(full_name: "   ")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-001")
    expect(result.error.details).to have_key(:full_name)
    expect(project.reload.github_repository).to be_nil
  end
end
