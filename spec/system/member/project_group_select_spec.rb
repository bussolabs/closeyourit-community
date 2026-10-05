# frozen_string_literal: true

require "rails_helper"

# Regressione CYRA-89: il select nativo ha sempre avuto l'opzione vuota, ma il widget Stimulus
# la scartava e rendeva impossibile rimuovere un gruppo già assegnato.
RSpec.describe "Progetto — rimozione del gruppo dal select", :js, type: :system do
  let(:organization) { create(:organization, name: "Demo") }
  let(:group) { create(:group, organization:, name: "Suite") }
  let(:project) { create(:project, organization:, group:) }
  let(:owner) do
    account = create(:account)
    create(:membership, account:, organization:, role: :owner)
    account
  end

  it "permette di scegliere Nessun gruppo e salva il progetto senza gruppo" do
    sign_in_as(owner)
    visit edit_member_project_path(project)

    native = find("select[data-test='project-group']", visible: :all)
    combo = native.find(:xpath, "..")
    combo.find("button[aria-haspopup='listbox']").click
    combo.find("[role='option']", text: I18n.t("member.projects.form.group_none")).click

    expect(native.value).to eq("")
    click_on_test "project-submit"

    expect_test "flash-notice"
    expect(project.reload.group).to be_nil
  end
end
