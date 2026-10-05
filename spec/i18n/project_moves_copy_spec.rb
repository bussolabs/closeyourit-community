# frozen_string_literal: true

require "rails_helper"

# CYRA-879 — the move preview composes its keys at runtime from what Plan returns: a code or a
# table without a translation would print the i18n placeholder. The lists come from the code itself.
RSpec.describe "Project move copy", type: :model do
  let(:scope) { "member.project_moves" }

  # Blocker codes are literals in Plan: read them from its source, so a new one cannot be missed.
  let(:blocker_codes) do
    Rails.root.join("app/services/projects/moves/plan.rb").read.scan(/code: "([a-z_]+)"/).flatten.uniq
  end

  let(:detachment_tables) do
    Projects::Moves::Registry::DETACH.keys + Projects::Moves::Github.dependent_counts([]).keys +
      %w[github_repositories projects_groups knowledge_books]
  end

  let(:creation_keys) do
    Projects::Moves::LookupMap::MODELS.keys + %w[secrets_shared.variable secrets_shared.file secrets_shared.file_any_environment
                                                 knowledge_pages.one knowledge_pages.other
                                                 knowledge_books.moves knowledge_books.created knowledge_books.created_merged
                                                 knowledge_books.joined knowledge_books.joined_merged]
  end

  %i[it en].each do |locale|
    it "translates every blocker code in #{locale}" do
      expect(blocker_codes).to include("key_taken", "shared_conflict")
      missing = blocker_codes.reject { I18n.exists?("#{scope}.blockers.#{_1}", locale) }
      expect(missing).to be_empty
    end

    it "translates every detachment, singular and plural, in #{locale}" do
      missing = detachment_tables.product(%w[one other]).reject do |table, form|
        I18n.exists?("#{scope}.detachments.#{table}.#{form}", locale)
      end
      expect(missing).to be_empty
    end

    it "translates every creation in #{locale}" do
      missing = creation_keys.reject { I18n.exists?("#{scope}.creations.#{_1}", locale) }
      expect(missing).to be_empty
    end

    it "translates every move status in #{locale}" do
      missing = Projects::Move.statuses.keys.reject { I18n.exists?("#{scope}.show.status.#{_1}", locale) }
      expect(missing).to be_empty
    end
  end
end
