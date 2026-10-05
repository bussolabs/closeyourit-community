# frozen_string_literal: true

# Identità minima dell'account per la CLI (whoami). MAI password_digest o preferenze sensibili.
class AccountSerializer < ApplicationSerializer
  attributes :id, :name, :email
end
