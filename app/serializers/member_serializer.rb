# frozen_string_literal: true

# Membro dell'organizzazione per la CLI (da Connections::Membership). Serve a risolvere email→account_id
# nei comandi (es. aggiungere una persona a un team). MAI dati sensibili oltre nome/email.
class MemberSerializer < ApplicationSerializer
  attribute(:account_id, &:account_id)
  attribute(:name) { |membership| membership.account.name }
  attribute(:email) { |membership| membership.account.email }
  attribute(:membership_role) { |membership| membership.role.to_s }
end
