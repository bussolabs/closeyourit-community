# frozen_string_literal: true

module Github
  # Installazione della GitHub App "CloseYourIt" per una organizzazione (1:1). Nel DB si persiste solo
  # `installation_id` (numerico GitHub): gli installation-token, validi 1h, si coniano a richiesta con
  # la private key dell'App (mai persistiti). Da qui pendono i repo agganciati ai progetti dell'org.
  class Installation < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :github_installation

    has_many :repositories,
             class_name: "Github::Repository",
             inverse_of: :installation,
             dependent: :destroy

    validates :organization_id, uniqueness: true
    validates :installation_id, presence: true, uniqueness: true
    validates :account_login, presence: true
  end
end
