# frozen_string_literal: true

require "rails_helper"

# CYRA-357 — quattro posti dove annotare una cosa da fare e nessuna pagina che dicesse quando si
# sceglie l'uno invece dell'altro: chi si fermava a chiederselo non scriveva niente (0 azioni, 0 todo,
# 42 idee ferme contro 1163 ticket). Qui si verifica il punto d'ingresso unico e la riga fissa che
# ogni sezione mostra sotto il titolo.
RSpec.describe "Member::QuickAdd (CYRA-357)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  describe "il punto d'ingresso unico" do
    it "propone le quattro possibilità, ognuna con la riga che dice quando si usa" do
      get member_quick_add_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      %w[ticket idea todo action].each do |key|
        card = doc.at_css("[data-test='quick-add-#{key}']")
        expect(card).to be_present, "manca la scelta #{key}"
        expect(card.text).to include(I18n.t("member.quick_add.#{key}.when"))
        expect(card.text).to include(I18n.t("member.quick_add.#{key}.not_here"))
      end
    end

    it "ogni scelta porta al form che esiste già, non a un doppione" do
      get member_quick_add_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='quick-add-ticket']")["href"]).to eq(new_member_ticket_path)
      expect(doc.at_css("[data-test='quick-add-idea']")["href"]).to eq(new_member_idea_path)
      expect(doc.at_css("[data-test='quick-add-todo']")["href"]).to eq(new_member_todo_list_path)
      expect(doc.at_css("[data-test='quick-add-action']")["href"]).to eq(new_member_workload_action_path)
    end

    it "si raggiunge da qualunque pagina, dalla barra in alto" do
      get root_path

      button = Nokogiri::HTML(response.body).at_css("[data-test='member-nav-quick-add']")
      expect(button).to be_present
      expect(button["href"]).to eq(member_quick_add_path)
    end
  end

  describe "la riga fissa sotto il titolo delle sezioni" do
    it "le attività di team dicono per chi sono e cosa non ci va" do
      get member_workload_actions_path

      body = response.body
      expect(body).to include(I18n.t("member.quick_add.action.when"))
    end

    it "chi sa già dove andare crea ancora direttamente dalla sezione" do
      get member_tickets_path

      expect(response.body).to include(new_member_ticket_path)
    end
  end
end
