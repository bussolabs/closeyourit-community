# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectMovesHelper, type: :helper do
  describe "#project_move_creation_text" do
    it "names the environment of a copied organization file" do
      text = helper.project_move_creation_text({ table: "secrets_shared", kind: "file", name: "cert.pem", environment_code: "prod" })
      expect(text).to eq(I18n.t("member.project_moves.creations.secrets_shared.file", name: "cert.pem", environment: "prod"))
    end

    it "leaves out the parentheses for a file valid in every environment" do
      text = helper.project_move_creation_text({ table: "secrets_shared", kind: "file", name: "cert.pem", environment_code: nil })
      expect(text).to include("cert.pem")
      expect(text).not_to include("(")
    end

    it "counts the Knowledge pages that move along" do
      text = helper.project_move_creation_text({ table: "knowledge_pages", count: 3 })
      expect(text).to eq(I18n.t("member.project_moves.creations.knowledge_pages", count: 3))
    end

    it "names a Knowledge collection created in the destination" do
      text = helper.project_move_creation_text({ table: "knowledge_books", title: "Runbooks", outcome: "created", books: 1 })
      expect(text).to eq(I18n.t("member.project_moves.creations.knowledge_books.created", title: "Runbooks"))
    end

    it "says when several source books merge into one destination book" do
      text = helper.project_move_creation_text({ table: "knowledge_books", title: "Runbooks", outcome: "joined", books: 2 })
      expect(text).to eq(I18n.t("member.project_moves.creations.knowledge_books.joined_merged", title: "Runbooks", books: 2))
    end
  end
end
