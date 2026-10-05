# frozen_string_literal: true

require "rails_helper"

# CYRA-381 — il fingerprint include il punto del codice, quindi lo stesso errore lanciato da quattro
# posti diventa quattro gruppi: chi guarda vede quattro cose da smaltire invece di un problema solo.
# La funzione che glielo direbbe esisteva, ma era un bottone sotto la piega.
RSpec.describe "Member::Monitoring::ErrorGroups — stesso messaggio (CYRA-381)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:message) { "RuntimeError: Undeclared attribute type for enum" }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "il dettaglio mostra gli altri errori con lo stesso messaggio, senza premere niente" do
    main = create(:error_group, project: project, title: message, culprit: "auth/authenticate_account.rb")
    allow_n_plus_one do
      create(:error_group, project: project, title: message, culprit: "concerns/discardable.rb")
      create(:error_group, project: project, title: message, culprit: "jobs/birthday_reminders_job.rb")
    end

    get member_monitoring_error_group_path(main)

    doc = Nokogiri::HTML(response.body)
    section = doc.at_css("[data-test='error-similar-same-message']")
    expect(section).to be_present
    expect(section.text).to include(I18n.t("member.monitoring.similar_same_message.basis"))
    expect(doc.css("[data-test='error-similar-row']").size).to eq(2)
  end

  it "un errore senza fratelli non mostra la sezione" do
    solo = create(:error_group, project: project, title: "Errore unico")

    get member_monitoring_error_group_path(solo)

    expect(Nokogiri::HTML(response.body).at_css("[data-test='error-similar-same-message']")).to be_nil
  end

  it "nell'elenco le righe con lo stesso messaggio lo dichiarano" do
    allow_n_plus_one do
      2.times { |i| create(:error_group, project: project, title: message, culprit: "file_#{i}.rb") }
    end

    get member_monitoring_error_groups_path

    badge = Nokogiri::HTML(response.body).at_css("[data-test^='error-group-same-message-']")
    expect(badge).to be_present
    expect(badge.text).to include("2")
  end
end
