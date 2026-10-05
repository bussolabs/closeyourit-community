# frozen_string_literal: true

require "rails_helper"

# CYRA-690 — con più schede aperte le pagine si distinguevano solo dall'icona: il title restava
# «CloseYourIt» sulle viste che non lo impostavano, e l'apostrofo delle traduzioni usciva doppiamente
# escapato (&amp;#39;) perché il layout ricostruiva il titolo per interpolazione.
RSpec.describe "Member — titoli delle schede del browser (CYRA-690)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "una pagina con apostrofo nel titolo lo rende una volta sola, mai come &amp;#39;" do
    owner.update!(locale: "it")

    get member_shared_secrets_path

    expect(response.body).to include("<title>Secret dell&#39;organizzazione · CloseYourIt</title>")
    expect(response.body).not_to include("&amp;#39;")
  end

  it "le pagine dei form impostano il titolo della scheda, una volta sola" do
    get new_member_team_path

    title = I18n.t("member.teams.new_title")
    expect(response.body).to include("<title>#{title} · CloseYourIt</title>")
    expect(response.body).not_to include("<title>#{title}#{title}")
  end

  it "il title della scelta progetto del vault dice quello che dice l'h1" do
    get member_vault_projects_path

    expect(response.body).to include("<title>#{I18n.t('member.vault.levels.project')} · CloseYourIt</title>")
  end
end
