# frozen_string_literal: true

# Invito a un'organizzazione per la CLI. L'accept_url (token) viaggia SOLO nella risposta alla create
# (reveal), non qui (l'index non lo espone).
class InvitationSerializer < ApplicationSerializer
  attributes :id, :email, :accepted_at, :created_at

  attribute(:role, &:role)
end
