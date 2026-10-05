# frozen_string_literal: true

module Github
  # Pull request di un repo agganciato, collegata (opzionalmente) a un ticket. Nasce aperta dal ticket
  # (`Ticketing::Github::OpenPullRequest`) o agganciata dal webhook riconoscendo il prefisso KEY-N in
  # head_ref/titolo/body. `state` riflette lo stato su GitHub (open/closed/merged), aggiornato dal webhook.
  class PullRequest < ApplicationRecord
    belongs_to :repository, class_name: "Github::Repository", inverse_of: :pull_requests
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true, inverse_of: :github_pull_requests

    enum :state, { open: 0, closed: 1, merged: 2 }, prefix: :state

    validates :number, presence: true, uniqueness: { scope: :repository_id }
    validates :title, presence: true
    validates :html_url, presence: true
  end
end
