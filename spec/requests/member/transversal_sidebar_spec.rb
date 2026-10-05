# frozen_string_literal: true

require "rails_helper"

# CYRA-328 aveva un problema che CYRA-521 ha reso impossibile: la sidebar ereditava dalla sessione
# l'ultima verticale scelta, e le pagine trasversali (Home, Todos, Chat, Notifiche) mostravano il menu
# di un'altra area. Senza aree da scegliere e senza uno space in sessione, non c'è più niente da
# ereditare — la forma del menu la copre `spec/system/member/sidebar_sections_spec.rb`.
#
# Qui resta ciò che vale ancora: l'indirizzo esplicito della dashboard, i nomi accessibili delle icone
# in alto (CYRA-327) e la voce accesa che dice dove sei (CYRA-373).
RSpec.describe "Member — pagine trasversali e barra in alto", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  describe "l'indirizzo esplicito dell'area iniziale" do
    it "risponde invece di restituire pagina non trovata" do
      get "/member/home"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="member-nav-home"')
    end
  end

  # CYRA-327 — le icone della barra in alto non avevano tutte un nome: un lettore di schermo leggeva
  # la chiave interna. Ognuna deve avere un nome in italiano, visibile anche passandoci sopra.
  describe "icone della barra in alto" do
    it "ogni icona ha nome accessibile e title, e nessuna espone una chiave interna" do
      get root_path

      html = Nokogiri::HTML(response.body)
      %w[member-nav-quick-add member-nav-todos member-nav-chat notification-bell].each do |test_id|
        icon = html.at_css("[data-test='#{test_id}']")
        expect(icon).to be_present, "manca l'icona #{test_id}"
        expect(icon["aria-label"]).to be_present
        expect(icon["title"]).to eq(icon["aria-label"])
        expect(icon["aria-label"]).not_to include("translation missing")
      end
      expect(html.at_css("[data-test='member-nav-toggle']")["aria-label"]).to be_present
    end

    it "l'icona dentro un pulsante è nascosta al lettore di schermo" do
      get root_path

      icon = Nokogiri::HTML(response.body).at_css("[data-test='member-nav-chat'] svg")
      expect(icon["aria-hidden"]).to eq("true")
    end
  end

  # CYRA-373 — `aria-current` oltre al colore: la voce accesa dev'essere accesa anche per un lettore
  # di schermo, ed è ciò che dice «sei qui». Vale anche per una foglia dentro un gruppo.
  describe "la voce accesa dice dove sei" do
    it "sui progetti accende Progetti" do
      get member_projects_path

      active = Nokogiri::HTML(response.body).css('#member-sidebar [aria-current="page"]')
      expect(active).to be_present
      expect(active.text).to include(I18n.t("member.nav.projects"))
    end

    it "dentro una verticale accende la foglia, non il gruppo che la contiene" do
      get member_monitoring_error_groups_path

      active = Nokogiri::HTML(response.body).css('#member-sidebar [aria-current="page"]')
      expect(active.text).to include(I18n.t("member.nav.errors"))
      expect(active.text).not_to include(I18n.t("member.nav.group_observability"))
    end
  end
end
