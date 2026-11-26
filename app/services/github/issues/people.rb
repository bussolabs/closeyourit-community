# frozen_string_literal: true

module Github
  module Issues
    # GitHub names ↔ members of the organization, through the GitHub name each person writes in their
    # profile. A name nobody wrote, or that two people wrote, resolves to nobody. CYRA-1055
    module People
      module_function

      # [account or nil, the login that did not resolve or nil]. Only the first GitHub assignee
      # counts: a ticket has one assignee.
      def resolve(organization, logins)
        login = Array(logins).first.to_s
        return [ nil, nil ] if login.blank?

        matches = organization.accounts.where("lower(accounts.github_login) = ?", login.downcase).limit(2).to_a
        matches.one? ? [ matches.first, nil ] : [ nil, login ]
      end
    end
  end
end
