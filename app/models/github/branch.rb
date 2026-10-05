# frozen_string_literal: true

module Github
  # Branch di un repo agganciato, collegato (opzionalmente) a un ticket. Nasce creato dal ticket
  # (`Ticketing::Github::CreateBranch`) o agganciato dal webhook riconoscendo il prefisso KEY-N nel nome.
  class Branch < ApplicationRecord
    belongs_to :repository, class_name: "Github::Repository", inverse_of: :branches
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true, inverse_of: :github_branches

    validates :name, presence: true, uniqueness: { scope: :repository_id }
  end
end
